# AWS 배포 가이드

> 🔴 **로컬에서 검증한 파일을 그대로 씁니다.** 새로 만드는 건 두 개뿐입니다.

## 무엇을 재사용하나

| 기존 파일 | AWS 에서 |
|---|---|
| `charts/reverdi/templates/` 12개 | **한 줄도 안 바뀜** |
| `charts/reverdi/values-aws.yaml` | 이미 있음 — `<>` 자리만 채움 |
| `helm-values/argocd.yaml` | 그대로 + 오버레이 |
| `helm-values/kube-prometheus-stack.yaml` | 그대로 + 오버레이 |
| `helm-values/jenkins.yaml` | 그대로 + 오버레이 |
| `argocd/application.yaml` | `valueFiles` 만 교체 |

**오버레이가 바꾸는 것은 두 가지뿐입니다.**

```yaml
NodePort   → ClusterIP     노드에 공인 IP 가 없다
local-path → gp3           k3s 내장 프로비저너는 EKS 에 없다
```

```bash
helm ... -f helm-values/argocd.yaml -f helm-values/aws/argocd.yaml
#          로컬에서 검증한 것         다른 부분만
```

Helm 은 `-f` 를 여러 번 받으면 뒤에 온 것이 이깁니다.
**toleration · nodeSelector · 자원 요청은 로컬에서 쓰던 그대로** 유지됩니다.

## 새로 필요한 것 — 두 개

`kubectl` 과 Helm 은 **클러스터 안**만 다룹니다. VPC 나 EKS 클러스터 자체는 못 만듭니다.

| 파일 | 역할 | Vagrant 대응 |
|---|---|---|
| `aws/cluster.yaml` | VPC · EKS · 노드그룹 · IRSA | **`Vagrantfile`** |
| `aws/rds.yaml` | RDS Multi-AZ + 읽기 복제본 | `infra/postgres-cluster.yaml` |

둘 다 YAML 이라 **git 의 YAML 을 쓴다**는 방식이 그대로 이어집니다.

## 로컬 전용 — AWS 에서는 안 씁니다

| 파일 | AWS 대체 |
|---|---|
| `infra/postgres-cluster.yaml` | RDS |
| `infra/registry.yaml` | ECR |
| `infra/registries.yaml` | 불필요 (ECR 은 HTTPS) |
| `infra/minio.yaml` | S3 |

**매니페스트는 버려지지만, 그것으로 검증한 앱 설정은 남습니다.**

---

## 0. 🔴 먼저 알아둘 것

### 비용

**3주 기준 약 $280** 입니다. 팀 예산 $700 안에 들어갑니다.

| 항목 | 3주(504h) |
|---|---:|
| EKS 컨트롤 플레인 | $50 |
| NAT Gateway ×1 | $30 |
| EC2 t3.medium ×3 + t3.small ×1 | $92 |
| RDS Multi-AZ + 읽기 복제본 | $62 |
| ALB | $18 |
| 퍼블릭 IPv4 · EBS · ECR · S3 | $28 |
| **합계** | **약 $280** |

**하루에 약 $13** 씩 나갑니다. 안 쓰는 날에도요.

### 🔴 시연이 끝나면 반드시 지우세요

```bash
bash aws/scripts/99-destroy.sh
```

지우지 않으면 **한 달에 $400** 이 계속 나갑니다.
"나중에 하겠다"가 가장 비쌉니다.

### Vagrant 와 다른 점

| | 로컬 | AWS |
|---|---|---|
| 클러스터 생성 | `vagrant up` | `eksctl create cluster` |
| 컨트롤 플레인 | node0 (taint 로 격리) | **AWS 관리 — 우리 VPC 밖** |
| 이미지 저장소 | Docker Registry + `registries.yaml` | **ECR** (인증은 노드 IAM 역할) |
| DB | CloudNativePG | **RDS Multi-AZ + 읽기 복제본** |
| 외부 노출 | NodePort 30080 | **ALB** |
| 이미지 빌드 | node4 에서 podman | **로컬 PC 에서 docker → ECR push** |

**Helm 차트 `templates/` 는 한 줄도 안 바뀝니다.** 값 파일만 바뀝니다.

---

## 1. 준비

### 도구 설치

```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# eksctl
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" \
  | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin

# kubectl · helm
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Windows 면 WSL2** 를 쓰세요. PowerShell 에서도 되지만 스크립트가 bash 입니다.

### 자격증명

```bash
aws configure
```

| 입력 | 값 |
|---|---|
| Access Key ID | IAM 사용자 키 |
| Secret Access Key | |
| Default region | **`ap-northeast-2`** |
| Output format | `json` |

**필요한 권한** — 클러스터를 만들려면 넓은 권한이 필요합니다.
학습 계정이면 `AdministratorAccess` 로 시작하는 게 현실적입니다.

### Docker

이미지 빌드에 필요합니다. **크롤러가 2.7GB** 라 디스크 여유를 확인하세요.

```bash
docker --version
df -h /var/lib/docker
```

> ⚠️ **Apple Silicon 맥**이면 `--platform linux/amd64` 가 필수입니다.
> 스크립트에 이미 들어 있습니다. 없으면 노드에서 `exec format error` 로 죽습니다.

---

## 2. 실행

```bash
git clone https://github.com/jpnjb0918-glitch/reverdi.git
cd reverdi
```

**순서대로** 실행합니다. 각 단계가 앞 단계 결과에 의존합니다.

```bash
bash aws/scripts/00-preflight.sh     # 사전 확인          1분
bash aws/scripts/10-cluster.sh       # EKS 클러스터      15~20분  ← vagrant up
bash aws/scripts/20-addons.sh        # ALB 컨트롤러       3~5분
bash aws/scripts/30-ecr.sh           # 이미지 빌드·push  20~35분
bash aws/scripts/40-rds.sh           # RDS              15~25분
bash aws/scripts/50-secrets.sh       # Secret            1분
bash aws/scripts/55-fill-values.sh   # 🔴 values-aws.yaml 의 <> 채우기
bash aws/scripts/60-app.sh           # 앱 배포           5~10분
bash aws/scripts/70-argocd.sh        # Argo CD           3~5분
bash aws/scripts/80-monitoring.sh    # 모니터링          5~10분
bash aws/scripts/90-jenkins.sh       # Jenkins           5~10분
bash aws/scripts/99-summary.sh       # 접속 정보
```

**전체 1시간 30분~2시간**. 이미지 빌드가 가장 깁니다.

### 병렬로 하면 시간을 줄일 수 있습니다

`30-ecr.sh` (이미지 빌드) 와 `40-rds.sh` (RDS 생성) 는 **서로 의존하지 않습니다.**
터미널을 두 개 열어 동시에 돌리면 20분쯤 절약됩니다.

다만 `10-cluster.sh` 와 `20-addons.sh` 는 먼저 끝나 있어야 합니다.

---

## 3. 각 단계가 하는 일

### `10-cluster.sh` — Vagrantfile 에 해당

`aws/cluster.yaml` 한 파일로 이것들이 생깁니다.

```
VPC 10.0.0.0/16 · 퍼블릭/사설 서브넷 3AZ · NAT Gateway 1개
EKS 컨트롤 플레인 (AWS 관리)
노드그룹 3종 — web ×3 (t3.medium) · batch ×1 (t3.small) · infra ×1
OIDC 공급자 + IRSA 역할 4개
```

**노드 라벨과 taint 가 로컬과 같습니다.**

| 노드그룹 | 라벨 | taint |
|---|---|---|
| `reverdi-web` | `workload=web` | 없음 |
| `reverdi-batch` | `workload=batch` | `NoSchedule` |
| `reverdi-infra` | `workload=infra` | `NoSchedule` |

**컨트롤 플레인에는 taint 를 안 겁니다.** AWS 관리 영역이라 워크로드가 뜰 수 없습니다.
로컬에서 node0 에 걸던 `CriticalAddonsOnly` 가 여기선 불필요합니다.

### `30-ecr.sh` — 이미지

**로컬 PC 에서 빌드해 push** 합니다.

노드에서 빌드하려면 Jenkins 를 먼저 올려야 하는데, Jenkins 를 올리려면 클러스터가
동작해야 하고, 클러스터가 동작하려면 이미지가 있어야 합니다. 순환입니다.
**첫 이미지는 손으로 올리는 게 맞습니다.**

수명주기 정책도 겁니다 — 최근 10개만 남깁니다. 없으면 이미지가 쌓여 요금이 계속 늡니다.

### `40-rds.sh` — DB

`aws/rds.yaml` (CloudFormation) 로 만듭니다.

| | |
|---|---|
| 주 인스턴스 | `db.t4g.small` · Multi-AZ |
| 동기 스탠바이 | 자동 (Multi-AZ 가 만듦) |
| 읽기 복제본 | `db.t4g.small` |
| 🔴 `rds.force_ssl=1` | **서버가 평문을 거부** |
| 퍼블릭 액세스 | **차단** |

**로컬 CloudNativePG 와 같은 모양**입니다.

```
로컬  reverdi-db-rw  /  reverdi-db-ro
AWS   WriterEndpoint /  ReaderEndpoint
```

### `50-secrets.sh` — 🔴 순서

로컬에서는 CNPG 가 비밀번호를 만들어 우리가 꺼내 썼습니다(문제 12).
**AWS 에서는 우리가 만들어 RDS 에 넣었으므로** 그 값을 그대로 씁니다.

백엔드 보안 4번에 따라 **Secret 을 둘로 나눕니다.**

| Secret | 받는 워크로드 |
|---|---|
| `reverdi-secret` | 웹 — 계정 · SESSION_SECRET · DB |
| `reverdi-db-secret` | 배치 — **DB 만** |

### `60-app.sh` — 앱

```bash
helm upgrade --install reverdi charts/reverdi -n reverdi \
  -f charts/reverdi/values-aws.yaml \
  --set image.repository="<ECR주소>/reverdi-backend" \
  --set secretScope.perWorkload=true
```

**`templates/` 는 로컬과 완전히 같습니다.** 값 파일만 바뀝니다.

S3 버킷도 여기서 만듭니다 — 퍼블릭 차단 · 암호화 포함.

---

## 4. 끝나면

```bash
bash aws/scripts/99-summary.sh
```

접속 주소와 비밀번호가 나옵니다.

### 웹 앱

```
http://<ALB주소>
```

ALB 주소는 이렇게도 볼 수 있습니다.

```bash
kubectl get ingress -n reverdi
```

> ⚠️ **도메인이 없어 HTTP 로만 뜹니다.**
> 도메인이 생기면 ACM 인증서를 만들고 `values-aws.yaml` 의
> `ingress.certificateArn` 에 넣은 뒤 `helm upgrade` 하면 HTTPS 가 됩니다.

### 🔴 Argo CD · Grafana 는 인터넷에 노출하지 않습니다

포트포워딩으로 봅니다.

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80
# http://localhost:8080

kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# http://localhost:3000
```

**Argo CD 는 클러스터를 바꿀 수 있는 도구**입니다. 인터넷에 열면
비밀번호 하나가 곧 클러스터 전체입니다.

---

## 5. 확인

### 노드 · AZ 분산

```bash
kubectl get nodes -L workload,topology.kubernetes.io/zone
```

**web 노드 3대가 서로 다른 AZ** 에 있어야 합니다.

```bash
kubectl get pod -n reverdi -o wide
```

웹 파드 3개가 **노드마다 하나씩** — `topologySpreadConstraints` 가 동작한 결과입니다.
로컬에서는 호스트명 기준이었는데, AWS 에서는 **AZ 기준**이 됩니다.

### 앱

```bash
curl -s http://<ALB주소>/ready | python3 -m json.tool
```

```json
{
  "ready": true,
  "database":       { "connected": true },
  "database_write": { "connected": true },
  "storage":        { "mode": "s3", "ok": true },
  "migration":      { "up_to_date": true }
}
```

🔴 **`storage.mode` 가 `s3` 인지** 보세요. `local` 이면 IRSA 가 안 붙은 겁니다.

### DB 암호화

```bash
kubectl run pgtest -n reverdi --rm -it --restart=Never \
  --image=postgres:17-alpine -- \
  psql "$(kubectl get secret reverdi-db-secret -n reverdi \
    -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed 's|postgresql+asyncpg|postgresql|')" \
  -c "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();"
```

`t` 가 나오면 TLS 로 붙은 겁니다.

### 비밀값 분리 확인

```bash
kubectl create job -n reverdi --from=cronjob/reverdi-crawler scope-test
kubectl exec -n reverdi job/scope-test -- printenv | grep -c ADMIN_PASSWORD
```

**`0`** 이어야 합니다. 그런데도 크롤러가 정상 동작하면 분리가 된 겁니다.

---

## 6. 시연

### 🔴 RDS 페일오버 — 발표 핵심

**창 1** — 조회를 계속 때린다

```bash
while true; do
  printf '%s  ' "$(date +%H:%M:%S)"
  curl -s -o /dev/null -w "%{http_code}\n" -m 3 http://<ALB주소>/
  sleep 1
done
```

**창 2** — 강제 페일오버

```bash
aws rds describe-db-instances --db-instance-identifier reverdi-db \
  --region ap-northeast-2 --query 'DBInstances[0].AvailabilityZone'

aws rds reboot-db-instance --db-instance-identifier reverdi-db \
  --force-failover --region ap-northeast-2

# 60~120초 뒤 AZ 가 바뀐다
aws rds describe-db-instances --db-instance-identifier reverdi-db \
  --region ap-northeast-2 --query 'DBInstances[0].AvailabilityZone'
```

**창 1 의 `200` 이 유지되면서 AZ 가 바뀝니다.**
읽기는 복제본으로 가기 때문입니다. **로컬에서 검증한 그 동작**입니다.

### Argo CD self-heal

```bash
kubectl scale deploy reverdi-web -n reverdi --replicas=1
kubectl get pod -n reverdi -w
```

### 크롤러

```bash
kubectl create job -n reverdi --from=cronjob/reverdi-crawler crawl-1
kubectl logs -n reverdi -l job-name=crawl-1 -f
```

**batch 노드에서만** 돕니다 (taint 로 격리).

### Grafana

`Explore` → Prometheus → Code 모드

```
sum(rate(http_requests_total[1m])) by (status)
```

---

## 7. 🔴 비용 관리

### 매일 확인

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`1`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table
```

### 예산 경보

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
cat > /tmp/budget.json <<EOF
{
  "BudgetName": "reverdi-demo",
  "BudgetLimit": { "Amount": "400", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF
cat > /tmp/notify.json <<'EOF'
[{
  "Notification": {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 80
  },
  "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "본인이메일@example.com" }]
}]
EOF
aws budgets create-budget --account-id "$ACCOUNT" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notify.json
```

**이메일 주소를 바꿔서** 실행하세요.

### 시연 안 하는 날 줄이기

노드를 0대로 내리면 EC2 요금이 멈춥니다. **EKS·NAT·RDS 는 계속 나갑니다.**

```bash
# 내리기
eksctl scale nodegroup --cluster reverdi --name reverdi-web --nodes 0 --region ap-northeast-2
eksctl scale nodegroup --cluster reverdi --name reverdi-batch --nodes 0 --region ap-northeast-2

# 올리기 (5분)
eksctl scale nodegroup --cluster reverdi --name reverdi-web --nodes 3 --region ap-northeast-2
eksctl scale nodegroup --cluster reverdi --name reverdi-batch --nodes 1 --region ap-northeast-2
```

하루 $4.4 → $2 정도로 줄어듭니다.

> ⚠️ `reverdi-infra` 는 내리지 마세요. Prometheus 데이터가 날아갑니다.

---

## 8. 🔴 삭제

```bash
bash aws/scripts/99-destroy.sh
```

**순서가 중요합니다.**

```
① Helm 릴리스   ALB · EBS 볼륨이 여기서 지워진다
② RDS 스택
③ EKS 클러스터  VPC · NAT 포함
④ 남은 것       ECR · S3 · 로그
```

순서를 바꾸면 `eksctl` 이 VPC 를 못 지웁니다.
ALB 가 서브넷을 잡고 있는데 **그건 쿠버네티스가 만든 거라 CloudFormation 이 모릅니다.**
`DependencyViolation` 으로 멈춥니다.

### 삭제 후 확인

```bash
aws ec2 describe-addresses --region ap-northeast-2                 # 탄력적 IP
aws elbv2 describe-load-balancers --region ap-northeast-2          # 로드밸런서
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters Name=status,Values=available                            # 미사용 EBS
aws rds describe-db-instances --region ap-northeast-2               # RDS
```

**전부 비어 있어야** 요금이 멈춥니다.

> ⚠️ `available` 상태의 EBS 볼륨은 아무것도 안 하는데 **요금은 나갑니다.**
> PVC 를 지우기 전에 클러스터를 지우면 이렇게 남습니다.

---

## 9. 막히면

### 단계별로 다시

각 스크립트는 독립적으로 다시 돌릴 수 있습니다.

```bash
bash aws/scripts/60-app.sh        # 앱만 다시
bash aws/scripts/99-summary.sh    # 접속 정보 다시
```

### 자주 막히는 곳

| 증상 | 원인 | 조치 |
|---|---|---|
| `exec format error` | arm64 맥에서 빌드 | `--platform linux/amd64` (스크립트에 이미 있음) |
| ALB 가 안 생김 | ALB 컨트롤러 미설치 | `bash aws/scripts/20-addons.sh` |
| 파드 `Pending` | 노드 자원 부족 · taint | `kubectl describe pod` |
| `storage.mode: local` | IRSA 미적용 | ServiceAccount 주석 확인 |
| RDS 접속 실패 | 보안그룹 · `force_ssl` | `DATABASE_SSL_MODE=require` 확인 |
| PVC `Pending` | gp3 StorageClass 없음 | `bash aws/scripts/20-addons.sh` |
| `eksctl delete` 가 멈춤 | ALB 가 서브넷 점유 | Helm 릴리스 먼저 삭제 |

### 로그

```bash
kubectl logs -n reverdi deploy/reverdi-web --tail=50
kubectl describe pod -n reverdi <파드명> | tail -20
kubectl get events -n reverdi --sort-by=.lastTimestamp | tail -15
```

---

## 10. 남은 작업 (보안 요청)

| # | 항목 | 상태 |
|:--:|---|---|
| 1 | RDS `force_ssl` | ✅ `rds.yaml` 에 포함 |
| 2 | 비밀값 범위 분리 | ✅ `60-app.sh` 가 `perWorkload=true` |
| 3 | **WAF** | 🔴 미적용 — 아래 |
| 4 | S3 비공개 | ✅ `60-app.sh` 가 처리 |
| 4 | CloudFront · 예산 · 복원 리허설 | 🔴 미적용 |

### WAF 를 붙이려면

```bash
# ALB ARN
aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text
```

콘솔에서 WAF 웹 ACL 을 만들고 이 ALB 에 연결합니다.

| 규칙 | 내용 |
|---|---|
| rate-based | IP 당 5분 100회 |
| 경로 차단 | `/metrics` `/docs` `/openapi.json` `/ready` → 404 |

**🔴 그전에 ALB XFF 속성을 바꿔야** 합니다.

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn <ALB_ARN> \
  --attributes Key=routing.http.xff_header_processing.mode,Value=replace \
  --region ap-northeast-2
```

없으면 클라이언트가 헤더를 위조해 **속도 제한을 우회**합니다.

### 백업 복원 리허설

**발표 전에 한 번은 해보세요.**

```bash
# 스냅샷
aws rds create-db-snapshot --db-instance-identifier reverdi-db \
  --db-snapshot-identifier reverdi-test-$(date +%Y%m%d) --region ap-northeast-2

# 복원 (새 인스턴스로)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier reverdi-restore-test \
  --db-snapshot-identifier reverdi-test-$(date +%Y%m%d) \
  --db-instance-class db.t4g.small --region ap-northeast-2

# 확인 후 삭제 (요금!)
aws rds delete-db-instance --db-instance-identifier reverdi-restore-test \
  --skip-final-snapshot --region ap-northeast-2
```

> **복원해본 적 없는 백업은 백업이 아닙니다.**
> 한 번은 해봐야 "복구할 수 있습니다"라고 말할 수 있습니다.
