# Terraform 이관 — 문제 해결 기록

> eksctl + CloudFormation 으로 만들던 AWS 인프라를 **Terraform 으로 옮기면서 겪은 15건**
> 2026-09-19 · 약 9시간 · 리소스 146개

대부분은 **"eksctl 이 알아서 해주던 것을 직접 해야 했다"** 로 요약된다.

---

## 0. 한눈에

| 분류 | 건수 | 내용 |
|---|:--:|---|
| **Terraform 의 구조적 제약** | 3 | 프로바이더 순환 · 리소스 주소 변경 · import 불가 |
| **eksctl 과의 차이** | 4 | CNI 순서 · 보안그룹 분리 · 애드온 충돌 · 기존 리소스 |
| **설정 누락** | 4 | `apply_method` · `storage_encrypted` · ALB xff · SonarQube edition |
| **운영 중 발견** | 4 | ALB 그룹 충돌 · helm upgrade · DNS 캐시 · 커널 파라미터 |

### 가장 오래 걸린 3건

| # | 문제 | 왜 어려웠나 |
|:--:|---|---|
| **15** | 복제본이 여섯 번 지워짐 | **증상이 원인을 가림** (백업 중이라 실패한 줄 알았다) |
| **6** | DB 연결 타임아웃 | **두 보안그룹이 같은 이름으로 불림** |
| **2** | 노드 39분 NotReady | 애드온이 **하나도 안 만들어진** 걸 늦게 알아챔 |

> **14·15번은 같은 함정**이다.
> 설정에 안 적으면 Terraform 이 **"해제하라"로 읽는다.**
> 그것 때문에 RDS 가 매 apply 마다 흔들렸고, 1시간 넘게 갇혔다.

---

## 1. 🔴 첫 apply 가 통째로 막힘

### 증상

```
Error: Invalid count argument
  The "count" value depends on resource attributes that cannot be
  determined until apply
```

IRSA 모듈 7개에서 동시에 났다.

### 원인

```
kubernetes 프로바이더 ← module.eks.cluster_endpoint (아직 없음)
        ↓
프로바이더를 설정할 수 없다
        ↓
그 프로바이더를 쓰는 리소스의 count 도 못 센다
```

클러스터가 생기기 전에는 그 주소를 알 수 없다.
EKS 와 kubernetes 프로바이더를 **한 설정에 두면** 생기는 알려진 제약이다.

### 해결

```bash
terraform apply -target=module.vpc -target=module.eks   # ①
terraform apply                                          # ②
```

`-target` 은 그 리소스와 의존성만 평가한다. kubernetes 프로바이더를 안 건드려 통과한다.

### 배운 것

- **첫 구축에서만** 그렇다. 두 번째부터는 한 번에 된다
- `import` 도 전체 설정을 평가하므로 **같은 벽에 막힌다** (5번 참조)

---

## 2. 🔴 노드가 39분간 NotReady

### 증상

```
NAME              STATUS     AGE
ip-10-0-11-145    NotReady   39m
... 7대 전부
```

```bash
$ kubectl get pods -n kube-system
No resources found

$ aws eks list-addons --cluster-name reverdi
{ "addons": [] }
```

**애드온이 하나도 없었다.**

### 원인 — 교착

```
EKS 모듈은 노드그룹을 만든 뒤 애드온을 설치한다
        ↓
노드는 CNI 가 있어야 Ready 가 된다
        ↓
노드그룹이 Ready 를 기다리며 멈춤 → 애드온 차례가 안 옴
```

CNI(`vpc-cni`)는 파드에 IP 를 주는 역할이라 **없으면 노드가 준비되지 않는다.**

### 해결

**임시** — 손으로 설치하자 2분 만에 살아났다.

```bash
aws eks create-addon --cluster-name reverdi --addon-name vpc-cni \
  --region ap-northeast-2 --resolve-conflicts OVERWRITE
```

**근본** — `eks.tf` 에 명시했다.

```hcl
vpc-cni = {
  most_recent    = true
  before_compute = true      # 🔴 노드보다 먼저 설치
}
```

### 배운 것

- **eksctl 은 이 순서를 알아서 처리**했다. Terraform 은 명시해야 한다
- `kubectl get pods -n kube-system` 이 비어 있으면 애드온 문제다
- 노드 `NotReady` 가 5분 넘으면 **CNI 부터** 의심한다

---

## 3. 🔴 `before_compute` 가 리소스 주소를 바꾼다

### 증상

```
$ terraform import 'module.eks.aws_eks_addon.this["vpc-cni"]' reverdi:vpc-cni
Error: Configuration for import target does not exist
```

### 원인

```bash
$ grep 'resource "aws_eks_addon"' .terraform/modules/eks/main.tf
768:resource "aws_eks_addon" "this" {
813:resource "aws_eks_addon" "before_compute" {
```

모듈이 리소스를 **둘로 나눠** 뒀다.

| | |
|---|---|
| `this` | 노드그룹 **뒤**에 만든다 |
| `before_compute` | 노드그룹 **앞**에 만든다 |

같은 리소스에 `depends_on` 을 두 가지로 줄 수 없어서다.

`before_compute = true` 를 넣는 순간 `this["vpc-cni"]` 는 설정에서 사라지고
`before_compute["vpc-cni"]` 가 생긴다.

### 해결

```bash
terraform import 'module.eks.aws_eks_addon.before_compute["vpc-cni"]' reverdi:vpc-cni
```

### 배운 것

- 모듈 설정을 바꾸면 **리소스 주소가 바뀔 수 있다**
- `import` 전에 모듈 소스를 확인한다
  ```bash
  grep 'resource "..."' .terraform/modules/.../main.tf
  ```

---

## 4. 🔴 애드온 충돌 — ConfigurationConflict

### 증상

```
Error: waiting for EKS Add-On (reverdi:vpc-cni) create:
  unexpected state 'CREATE_FAILED'
  ConfigurationConflict: Conflicts found when trying to apply.
  ServiceAccount aws-node - .metadata.labels.app.kubernetes.io/version
  ConfigMap amazon-vpc-cni - .metadata.labels.helm.sh/chart
```

### 원인

손으로 먼저 설치한 뒤 Terraform 에 넘기려 했다.
쿠버네티스 리소스에 **다른 라벨이 붙어 있어** 거부됐다.

손으로 쓴 `--resolve-conflicts OVERWRITE` 와 같은 옵션이 **설정에는 없었다.**

### 해결

```hcl
vpc-cni = {
  most_recent                 = true
  before_compute              = true
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
```

### 배운 것

- CLI 로 쓴 옵션은 **설정에도 넣어야** 한다
- `aws eks delete-addon --preserve` 는 **AWS 등록만 지우고 파드는 남긴다**
  → 노드가 계속 살아 있어 안전하게 재시도할 수 있다

---

## 5. 🔴 eksctl 이 남긴 리소스와 충돌

### 증상

```
RepositoryAlreadyExistsException: 'reverdi-backend' already exists
BucketAlreadyOwnedByYou: reverdi-uploads-611669940814
ResourceAlreadyExistsException: log group /aws/eks/reverdi/cluster
```

### 원인

클러스터를 지울 때 **ECR 과 S3 를 일부러 남겼다.** 이미지 빌드 30분을 아끼려고.

남긴 판단은 맞았는데 **Terraform 에 알려주는 단계가 빠졌다.**

### 시도 — import (실패)

```bash
terraform import aws_ecr_repository.backend reverdi-backend
Import prepared!
...
Error: Invalid count argument      ← 롤백
```

`import` 도 전체 설정을 평가한다. 1번과 같은 벽에 막혔다.
**IRSA 모듈의 `count` 는 `apply` 때만 결정**되므로 `import` 로는 영원히 안 된다.

### 해결 — 지우고 새로

```bash
aws ecr delete-repository --repository-name reverdi-backend --force ...
aws s3 rb s3://reverdi-uploads-611669940814 --force
aws logs delete-log-group --log-group-name /aws/eks/reverdi/cluster ...
```

`build_images = true` 라 **어차피 새로 빌드**한다. S3 는 비어 있었다.

### 배운 것

- **import 로 30분을 썼는데 처음부터 지우는 게 빨랐다**
- 잃을 게 없으면 재생성이 낫다. **판단을 미루지 말 것**

---

## 6. 🔴 DB 연결 타임아웃 — 보안그룹이 달랐다

### 증상

마이그레이션 Job 이 죽었다.

```
File ".../asyncpg/connection.py", line 2442, in connect
    async with compat.timeout(timeout):
TimeoutError
```

```
Error: installation failed
  job reverdi-migrate-1 failed: BackoffLimitExceeded
```

### 원인

```bash
# RDS 가 허용하는 보안그룹
sg-069621cbc22630429

# 노드에 실제로 붙어 있는 보안그룹
$ aws ec2 describe-instances ... --query '...SecurityGroups'
sg-02b285dbfe2ddda22   eks-cluster-sg-reverdi-1099845909
```

**서로 다르다.**

| | |
|---|---|
| `node_security_group` | EKS **모듈**이 만드는 것 — 노드 간 통신용 |
| `cluster_primary_security_group` | **EKS 가 자동 생성** — 노드에 실제로 붙음 |

`rds.tf` 는 전자만 허용했는데, 파드 트래픽은 후자로 나간다.

### 해결

```hcl
security_groups = [
  module.eks.node_security_group_id,
  module.eks.cluster_primary_security_group_id,   # 🔴 추가
]
```

### 확인 방법

```bash
kubectl run -n default dbcheck --rm -it --image=busybox --restart=Never -- \
  sh -c "nc -zv -w5 reverdi-db.xxx.rds.amazonaws.com 5432"
```

`open` 이 나오면 연결된다. **파드에서 직접 재보는 게 가장 확실했다.**

### 배운 것

- `eksctl` 때는 한 덩어리로 관리돼 이 구분이 없었다
- **Terraform 모듈에서 처음 드러난 차이**다
- 앱 오류를 보기 전에 **네트워크부터 확인**한다

---

## 7. 🔴 읽기 복제본이 반복 실패

### 증상

```
Error: creating RDS DB Instance (read replica) (reverdi-db-ro):
  InvalidDBInstanceState: DB instance is not in the available state
```

**여섯 번 반복**됐다.

### 원인 (표면)

```
apply → 복제본 교체 판단 → 삭제
     → 재생성 시도 → 주 DB 가 백업 중(modifying) → 거부
     → 실패 → 롤백 → 다음 apply 에서 반복
```

`describe-events` 가 단서를 줬다.

```
Backing up DB instance
Finished DB Instance backup
```

**복제본을 만들려면 주 DB 백업이 먼저** 필요하고, 그 백업 중에는 복제본을 못 만든다.

### 진짜 원인은 15번이었다

"왜 매번 교체하려 하는가" 를 늦게 물었다.
`forces replacement` 를 일찍 봤으면 한 시간을 아꼈다.

### 임시 대응 — `count` 로 끄기

순환 중에는 복제본을 빼고 나머지를 먼저 끝냈다.

```hcl
variable "enable_read_replica" {
  type    = bool
  default = true
}

resource "aws_db_instance" "reader" {
  count = var.enable_read_replica ? 1 : 0
}
```

참조하는 쪽도 함께 고쳤다.

```hcl
DATABASE_RO_URL = length(aws_db_instance.reader) > 0
  ? aws_db_instance.reader[0].address
  : aws_db_instance.writer.address
```

**복제본이 없으면 주 DB 로 조회**하므로 앱이 안 죽는다.

### 배운 것

- **증상이 원인을 가렸다.** "백업 중이라 실패" 는 결과지 원인이 아니었다
- `count` 로 껐다 켤 수 있게 해두면 **막혔을 때 우회**할 수 있다

---

## 8. 🔴 SonarQube — 차트가 바뀌었다

### 증상

```
Error: installation failed
  execution error at (sonarqube/templates/validation.yaml:25:12):
  ** The values.yaml file is not valid. **
  You must choose an 'edition' to install: 'developer' or 'enterprise'.
  If you want to use SonarQube Community Build, unset 'edition' and
  set 'community.enabled=true' instead.
```

### 원인

차트 10.7 부터 `edition` 대신 `community.enabled` 로 바뀌었다.

### 해결

```hcl
values = [yamlencode({
  community = { enabled = true }
})]
```

### 배운 것

- **차트 버전을 고정하지 않으면** 이런 변경을 만난다
- 6개 차트가 아직 버전 미고정이다 (`infra/terraform/README.md` 에 고정 절차 기록)

---

## 9. Elasticsearch 커널 파라미터 (예방됨)

### 증상 (다른 팀에서 겪을 수 있는 것)

SonarQube 는 내장 Elasticsearch 를 쓴다. 기본 설정이면 이렇게 죽는다.

```
max virtual memory areas vm.max_map_count [65530] is too low,
increase to at least [262144]
```

### 해결 — 미리 넣어뒀다

```hcl
initSysctl = {
  enabled       = true
  vmMaxMapCount = 524288
}
```

실제 기동 로그에서 확인됐다.

```
Init:0/2 → Init:1/2 → PodInitializing → Running
```

`Init:1/2` 가 이 작업이었다.

### 배운 것

- EKS 의 AL2023 노드는 `vm.max_map_count` 기본값이 낮다
- **미리 넣어둔 덕에 한 번에 떴다**

---

## 10. 🔴 ALB 컨트롤러가 빈 값을 보낸다

### 증상

```
Warning  FailedDeployModel  ingress
  ValidationError: 'routing.http.xff_header_processing.mode'
  must be set as 'preserve', 'append', or 'remove'
```

ALB 는 `active` 인데 **Ingress 에 주소가 안 붙고 리스너도 0개**였다.

```bash
$ aws elbv2 describe-listeners --load-balancer-arn ... --query 'Listeners[].[Port,Protocol]'
(빈 결과)
```

values 자체는 정상이었다.

```
certificateArn  ✅   listen-ports  ✅ 443 포함   host  ✅
```

### 원인

컨트롤러 v3.5.0 이 이 속성을 **빈 값으로 보낸다.**
AWS 가 거부하면서 ALB 속성 적용에서 멈추고, 그래서 리스너도 Ingress 상태도 못 만든다.

### 해결 — 값을 명시

```yaml
alb.ingress.kubernetes.io/load-balancer-attributes: routing.http.xff_header_processing.mode=append
```

### 배운 것

- **컨트롤러 버전을 고정**해야 한다. 최신이 항상 안전하지 않다
- `kubectl describe ingress` 의 **Events** 가 답을 준다

---

## 11. 🔴 ALB 를 공유하면 속성도 공유한다

### 증상

앱 Ingress 만 주소가 안 붙었다.

```
Warning  FailedBuildModel
  conflicting load balancer attributes
  routing.http.xff_header_processing.mode: replace | append
```

### 원인

```
group.name: reverdi   ← 앱과 Grafana 가 같은 ALB 를 쓴다
        ↓
Grafana  append
앱       replace      ← 충돌
```

ALB 가 하나니 **속성도 하나**다. 두 Ingress 가 같은 값을 줘야 한다.

### 해결

전부 `append` 로 통일했다.

```bash
grep -rl "mode=replace" charts/ helm-values/ infra/ | xargs sed -i 's/mode=replace/mode=append/'
```

### 배운 것

- **ALB 그룹 공유의 대가**다. 월 $16 을 아낀 대신 이런 제약이 생긴다
- 한쪽만 고치면 안 된다. **모든 Ingress 가 같아야** 한다

---

## 12. 🔴 helm upgrade 는 지워진 리소스를 안 되살린다

### 증상

`kubectl delete ingress` 로 지운 뒤 `terraform apply` 를 돌렸는데 Ingress 가 안 돌아왔다.

```bash
$ helm get manifest reverdi -n reverdi | grep -c "kind: Ingress"
1                          # 매니페스트에는 있다

$ kubectl get ingress -n reverdi
No resources found         # 클러스터에는 없다
```

### 원인

`helm upgrade` 는 **변경분만 적용**한다.
매니페스트가 그대로면 "바뀐 게 없다"고 보고 아무것도 안 한다.

### 해결 — 매니페스트에서 직접 꺼내 적용

```bash
helm get manifest reverdi -n reverdi | python3 -c "
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get('kind')=='Ingress']
print(yaml.safe_dump_all(docs), end='')
" > /tmp/ing.yaml

kubectl apply -f /tmp/ing.yaml -n reverdi
```

🔴 **`-n reverdi` 를 빼먹으면** `default` 에 만들어진다. 한 번 겪었다.

> `awk '/kind: Ingress/,0'` 로 자르면 `apiVersion` 줄이 날아간다.
> YAML 문서 단위로 뽑아야 한다.

### 배운 것

- Helm 은 **자기가 만든 것이 지워졌는지 확인하지 않는다**
- 확실히 되살리려면 `helm uninstall` 후 재설치거나, 매니페스트를 직접 적용한다

---

## 13. DNS 부정 캐시

### 증상

`grafana.re-verdi.com` 은 바로 열렸는데 `re-verdi.com` 이 안 됐다.

```bash
$ nslookup re-verdi.com
*** Can't find re-verdi.com: No answer

$ nslookup re-verdi.com 8.8.8.8
Address: 43.202.10.48          # 공개 DNS 로는 된다
```

### 원인

Route 53 에는 레코드가 있었다.
**도메인을 사기 전에 조회한 "없음" 이 로컬 리졸버에 캐시**돼 있었다.

### 해결

```bash
curl -I --resolve re-verdi.com:443:43.202.10.48 https://re-verdi.com
HTTP/2 200                     # DNS 를 우회하면 된다
```

임시로 `/etc/hosts` 에 넣어 확인했다. 다른 PC 에서는 바로 열렸다.

### 배운 것

- **없는 도메인을 미리 조회하면** 그 결과가 캐시된다
- 인프라 문제로 보이는 게 **클라이언트 문제**일 수 있다
- 다른 리졸버(`8.8.8.8`)로 물어보면 금방 가린다

---

## 14. 🔴 파라미터 그룹이 매 apply 마다 바뀐다

### 증상

`terraform plan` 을 돌릴 때마다 나왔다.

```
# aws_db_parameter_group.rds will be updated in-place
  - apply_method = "pending-reboot" -> null
  + apply_method = "immediate"
```

그리고 그때마다 **읽기 복제본이 교체 대상**이 됐다.

### 원인

```hcl
parameter {
  name  = "rds.force_ssl"
  value = "1"
  # apply_method 없음 → Terraform 기본값 immediate
}
```

`rds.force_ssl` 은 **정적 파라미터**다.
AWS 는 `immediate` 를 무시하고 `pending-reboot` 으로 저장한다.
Terraform 은 매번 "다르다"고 보고 고치려 든다.

### 해결

```hcl
apply_method = "pending-reboot"
```

### 배운 것

- 정적 파라미터는 **`pending-reboot` 을 명시**한다
- 이 한 줄이 **복제본 교체 순환의 방아쇠**였다

---

## 15. 🔴 복제본이 매번 교체된다 — 진짜 원인

### 증상

7번의 반복이 끝나지 않았다. `plan` 을 자세히 보니:

```
# aws_db_instance.reader[0] must be replaced
```

### 원인 찾기

```bash
$ terraform show tf.plan | grep -B3 -A3 "forces replacement"
      - storage_encrypted = true -> null # forces replacement
```

복제본 리소스에 이 속성이 없어서 Terraform 이 **"해제하라"** 로 읽었다.
암호화 변경은 **교체가 필요한 변경**이다.

복제본은 주 DB 의 암호화를 물려받는데, **설정에 안 적혀 있었다.**

### 해결

```hcl
resource "aws_db_instance" "reader" {
  replicate_source_db = aws_db_instance.writer.identifier
  storage_encrypted   = true      # 🔴 주 DB 에서 물려받는 값을 명시
}
```

14번과 함께 고친 뒤:

```
No changes. Your infrastructure matches the configuration.
```

### 배운 것

- 🔴 **`forces replacement` 를 보면 그 줄부터 찾는다**
  ```bash
  terraform show tf.plan | grep -B3 -A3 "forces replacement"
  ```
- 14번과 같은 함정이다 — **안 적으면 "해제하라"로 읽힌다**
- 두 개를 고치자 순환이 끝났다

---

## eksctl 과 비교

| | eksctl | Terraform |
|---|---|---|
| 애드온 순서 | **자동** | `before_compute` 명시 |
| 보안그룹 | 한 덩어리 | 노드 SG ≠ 클러스터 SG |
| 서브넷 분할 | **자동** | 직접 지정 |
| 첫 구축 | 한 번에 | **2단계** (`-target`) |
| 변경 미리보기 | 없음 | **`plan`** |
| 삭제 | 순서를 손으로 | 의존성 그래프 |

**직접 지정하는 만큼 실수할 여지가 늘었다.**
대신 `plan` 으로 미리 볼 수 있고, 상태 파일이 있어 재현이 된다.

---

## 🔴 가장 값어치 있는 습관

```bash
terraform plan -out=tf.plan
terraform show tf.plan | grep -E "will be|must be"
terraform apply tf.plan
```

**계획을 파일로 고정**하고 내용을 본 뒤 적용한다.
`terraform apply` 를 그냥 돌렸다가 복제본이 지워지는 일이 반복됐다.

특히 이 두 단어를 본다.

| | |
|---|---|
| `will be updated in-place` | 안전 |
| **`must be replaced`** | 🔴 삭제 후 재생성 |

---

## 다음에 같은 일을 하면

### 순서

```bash
# ① IAM 정책 먼저 (IRSA 모듈이 기다린다)
terraform apply -target=aws_iam_policy.web_s3 -target=aws_iam_policy.batch_s3 \
                -target=aws_iam_policy.loki_s3 -target=aws_iam_policy.external_dns

# ② VPC · EKS (애드온 포함)
terraform apply -target=module.vpc -target=module.eks
kubectl get nodes            # 🔴 Ready 확인

# ③ 나머지
terraform apply
```

### 미리 확인할 것

```bash
docker version                                    # 이미지 빌드에 필요
aws sts get-caller-identity                       # 자격증명
aws route53 list-hosted-zones-by-name --dns-name <도메인>
ls <app_source_path>/dockerfile.backend           # 경로
```

`infra/terraform/checks.tf` 가 마지막 것을 `plan` 단계에서 잡는다.

### 기존 리소스가 있으면

**import 하지 말고 지운다.** 잃을 게 없으면 그게 빠르다.

### 로그를 남긴다

```bash
terraform apply 2>&1 | tee ~/apply-$(date +%m%d-%H%M).log
```

---

## 결과

| | |
|---|---|
| 리소스 | **146개** |
| 노드 | web 3 · batch 2 · infra 2 = 7대 |
| RDS | Multi-AZ + 읽기 복제본 |
| Helm 릴리스 | 10개 |
| 최종 | `terraform plan` → **No changes** |

```
https://re-verdi.com           HTTP/2 200
https://grafana.re-verdi.com   HTTP/2 302
```

---

## 삭제할 때

🔴 **`terraform destroy` 만으로는 안 지워진다.**

컨트롤러가 만든 ALB·보안그룹이 VPC 삭제를 막는다.
eksctl 클러스터를 지울 때 **세 번 실패**했던 것과 같다.

```bash
cat infra/terraform/DESTROY.md
```

핵심은 두 가지다.

- **컨트롤러가 살아 있을 때** Service·Ingress 를 먼저 지운다
- 클래식 LB(`aws elb`)와 ALB(`aws elbv2`)는 **API 가 다르다**. 둘 다 확인한다
