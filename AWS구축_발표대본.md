# AWS 구축 — 발표 자료

> 📊 도표 — `AWS구축_발표.drawio` (4장 · 16:9)
>
> 슬라이드 순서대로 말할 내용을 정리했습니다. 그대로 읽어도 되고, 참고만 하셔도 됩니다.

---

## 슬라이드 1 — 구축 순서

### 화면

10단계 목록 (도표 1페이지)

### 말할 것

> 로컬에서 검증을 마친 뒤 AWS 로 옮겼습니다.
>
> **방식은 같습니다.** 로컬에서 `Vagrantfile` 하나로 VM 6대를 세웠듯이,
> AWS 에서는 `cluster.yaml` 하나로 VPC 와 EKS 클러스터를 만듭니다.
> 둘 다 git 에 있는 YAML 이고, 명령 한 줄로 실행됩니다.
>
> ```
> eksctl create cluster -f aws/cluster.yaml
> ```
>
> 이 한 줄이 VPC · 서브넷 · NAT · 컨트롤 플레인 · 노드그룹 3종 ·
> IRSA 역할까지 전부 만듭니다. 15분 걸립니다.

### 각 단계에서 짚을 것

| 단계 | 한 문장 |
|:--:|---|
| 1 | `cluster.yaml` 한 파일 — Vagrantfile 과 같은 역할 |
| 2 | **로컬에 없던 것들** — ALB 컨트롤러 · EBS CSI · metrics-server |
| 3 | 첫 이미지는 손으로 올린다 (Jenkins 가 없으니 순환) |
| 4 | RDS Multi-AZ — CloudNativePG 를 대체 |
| 5 | 🔴 **Secret 을 둘로 나눈다** — 크롤러는 DB 접속만 |
| 6 | **차트는 그대로, 값 파일만 교체** |
| 7 | Argo CD 가 git 을 감시 |
| 8 | Prometheus + Grafana |
| 9 | Jenkins — 빌드 에이전트는 파드로 뜬다 |
| 10 | **전체 흐름 완성** |

### 예상 질문

**"왜 콘솔로 안 만들었나요?"**

> 재현이 안 되기 때문입니다. 클릭 순서를 문서로 옮겨야 하고,
> 지울 때도 의존성 순서를 손으로 풀어야 합니다.
> YAML 로 선언하면 `eksctl delete cluster` 한 줄로 정리됩니다.

---

## 슬라이드 2 — 로컬에서 검증한 것을 그대로

### 화면

왼쪽 "그대로 쓰는 것" / 오른쪽 "바뀌는 것" (도표 2페이지)

### 말할 것

> 이번 구조의 핵심입니다.
>
> **Helm 차트의 `templates/` 12개는 한 줄도 안 바꿨습니다.**
> 파드 분산 규칙, 무중단 배포 설정, 읽기·쓰기 분리 —
> 로컬에서 확인한 그대로가 AWS 에서 돕니다.
>
> 바뀌는 건 **값 파일 하나**입니다.
>
> ```
> helm install ... -f values-vagrant.yaml    # 로컬
> helm install ... -f values-aws.yaml        # AWS
> ```

### 대응 표를 짚으며

| 항목 | 로컬 | AWS |
|---|---|---|
| 이미지 저장소 | 레지스트리 | ECR |
| 데이터베이스 | CloudNativePG | RDS Multi-AZ |
| 외부 노출 | NodePort | ALB |
| 스토리지 | local-path | gp3 (EBS) |
| 파일 저장 | MinIO | S3 |

> 왼쪽 것들은 **버려집니다.** 하지만 그것으로 검증한
> 앱 설정과 운영 감각은 남습니다.

### 🔴 "로컬에 없던 개념" 을 강조

> 네 가지가 새로 필요했습니다.
>
> **IRSA** — 파드마다 다른 IAM 역할을 줍니다.
> 웹은 S3 읽기·쓰기·삭제, 크롤러는 쓰기만.
> 크롤러가 뚫려도 파일을 지울 수는 없습니다.
>
> **EBS CSI** — 로컬 k3s 는 `local-path` 프로비저너가 내장인데
> EKS 에는 없어서 직접 설치했습니다.
>
> **ALB 컨트롤러** — Ingress 를 만들어도 이게 없으면 ALB 가 안 생깁니다.
>
> **ECR 인증** — 로컬 레지스트리는 인증이 없었는데,
> ECR 은 IAM 토큰이 필요합니다.

### 마무리

> 로컬에서 `vagrant destroy && vagrant up` 으로 몇 번이고
> 다시 만들며 검증했습니다. **부수고 다시 만들 수 있는 환경**이었기 때문에
> 실패를 두려워하지 않고 실험할 수 있었습니다.

---

## 슬라이드 3 — CI / CD

### 화면

Jenkins → ECR / git → Argo CD 흐름도 (도표 3페이지)

### 말할 것

> **Jenkins 는 빌드만 하고, Argo CD 가 배포합니다.**
> 서로 클러스터를 만지지 않습니다.
>
> Jenkins 가 하는 일은 여기까지입니다 —
> 코드를 검사하고, 테스트를 돌리고, 이미지를 만들어 ECR 에 올리고,
> **배포 저장소의 이미지 태그를 git 에 커밋**합니다.
>
> 그다음은 Argo CD 가 합니다. git 을 감시하다가
> 변경을 발견하면 클러스터에 반영합니다.

### 🔴 저장소를 둘로 나눈 이유

> 앱 소스와 배포 설정을 **다른 저장소**에 뒀습니다.
>
> 같은 곳에 두면 무한 루프가 납니다.
> Jenkins 가 빌드하고 태그를 커밋하는데,
> **그 커밋이 다시 Jenkins 를 깨웁니다.**

### 이렇게 나눈 이점

> **Jenkins 에 클러스터 권한이 필요 없습니다.**
> kubeconfig 도, EKS 접근 IAM 도 안 줘도 됩니다.
> Jenkins 가 뚫려도 클러스터는 안전합니다.
>
> **git 커밋이 곧 배포 이력입니다.**
> 지금 무엇이 떠 있는지 git 이 증명합니다.
>
> 손으로 `kubectl` 로 바꿔도 Argo CD 가 되돌립니다.
> 롤백은 `git revert` 입니다.

### 오늘 확인한 것

> 파이프라인을 실제로 돌렸습니다.
>
> ```
> values-aws.yaml   tag: "latest"  →  tag: "985a7bf"
> 파드 이미지        reverdi-backend:latest  →  reverdi-backend:985a7bf
> ```
>
> **손으로 `kubectl` 을 치지 않았는데 배포됐습니다.**

### 예상 질문

**"Jenkins 대신 GitHub Actions 를 쓰면 안 되나요?"**

> 됩니다. 실제로 이 저장소는 GitHub Actions 도 함께 씁니다.
> Jenkins 를 넣은 건 **사내 CI 서버를 운영하는 경험**을 위해서였습니다.
> 빌드 에이전트를 파드로 띄우는 구조도 그 자체로 배울 게 있었고요.

---

## 슬라이드 4 — 구축 결과

### 화면

4개 영역 검증 항목 + 페일오버 로그 (도표 4페이지)

### 말할 것

> 설계한 대로 동작하는지 항목별로 확인했습니다.

### 인프라

> 노드 5대가 역할별로 나뉘어 있습니다.
> 웹 3대는 **서로 다른 AZ** 에 있습니다.
>
> 로컬에서는 호스트명 기준으로 노드 3대에 흩었는데,
> AWS 에서는 **AZ 기준**으로 같은 제약이 동작합니다.
> 차트는 그대로고 `topologyKey` 만 바뀌었습니다.
>
> AZ 하나가 통째로 죽어도 나머지 2개로 서비스가 유지됩니다.

### 데이터베이스

> RDS Multi-AZ 에 읽기 복제본을 붙였습니다.
>
> **`rds.force_ssl` 을 켜서 평문 접속을 서버가 거부**합니다.
> 앱 쪽에도 TLS 요구 설정이 있는데, **둘 다 있어야** 완성입니다.
> 앱 설정만 있으면 서버가 평문을 받아주는 한 실수로 평문이 될 수 있습니다.

### 애플리케이션

> `/ready` 가 DB 읽기·쓰기, S3, 마이그레이션 상태를 전부 확인합니다.
>
> **`storage.mode` 가 `s3`** 라는 건 IRSA 가 동작한다는 뜻입니다.
> 액세스 키를 컨테이너에 넣지 않고, 파드가 IAM 역할로 인증합니다.

### CI/CD

> 파이프라인이 테스트 376건을 통과하고 이미지를 올렸습니다.
> Argo CD 는 `Synced / Healthy` 입니다.

### 🔴 페일오버 시연

> 이게 오늘 가장 보여드리고 싶은 부분입니다.
>
> 조회 요청을 1초마다 보내면서 **주 DB 를 강제로 전환**했습니다.
> AZ 가 바뀌는 동안에도 **응답이 한 번도 끊기지 않았습니다.**
>
> 읽기가 복제본으로 가기 때문입니다.
> 로컬 CloudNativePG 에서 확인한 것과 **같은 동작**입니다.

---

## 발표 전 준비

### 화면 캡처 목록

| 화면 | 어디서 |
|---|---|
| VPC 리소스 맵 | 콘솔 → VPC → 리소스 맵 |
| EKS 노드그룹 3종 | 콘솔 → EKS → 컴퓨팅 |
| **CloudFormation 스택** | 🔴 "코드로 만들었다"는 증거 |
| RDS Multi-AZ | 콘솔 → RDS |
| 웹 앱 화면 | ALB 주소 |
| Grafana 대시보드 | NLB 주소 |
| Jenkins 파이프라인 SUCCESS | 포트포워딩 |
| Argo CD 리소스 트리 | 포트포워딩 |

### 터미널로 보여줄 것

```bash
# 노드 · AZ 분산
kubectl get nodes -L workload,topology.kubernetes.io/zone
kubectl get pod -n reverdi -o wide

# 앱 상태
curl -s http://<ALB주소>/ready | python3 -m json.tool

# GitOps
kubectl get application reverdi -n argocd
kubectl get pod -n reverdi -o jsonpath='{.items[0].spec.containers[0].image}'
```

### 🔴 페일오버 시연 — 터미널 3개

**창 1** — 응답 감시

```bash
HOST=$(kubectl get ingress -n reverdi -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
while true; do
  printf '%s  ' "$(date +%H:%M:%S)"
  curl -s -o /dev/null -w "%{http_code}\n" -m 3 "http://$HOST/"
  sleep 1
done
```

**창 2** — DB 상태

```bash
watch -n 5 'aws rds describe-db-instances --db-instance-identifier reverdi-db \
  --region ap-northeast-2 \
  --query "DBInstances[0].[DBInstanceStatus,AvailabilityZone]" --output table'
```

**창 3** — 전환 실행

```bash
aws rds reboot-db-instance --db-instance-identifier reverdi-db \
  --force-failover --region ap-northeast-2
```

**60~120초** 뒤 AZ 가 바뀝니다. 창 1 의 `200` 은 유지됩니다.

---

## 질문 대비

### "비용은 얼마나 드나요?"

> 3주 기준 약 **$340** 입니다. 하루 $16 정도고요.
>
> 가장 큰 비중은 EKS 컨트롤 플레인($50), EC2 노드($110),
> RDS($62) 입니다.
>
> NAT Gateway 는 인터페이스 엔드포인트 대신 1개만 뒀습니다.
> 엔드포인트를 6종 × 3AZ 로 두면 월 $131 인데, 이 규모에서는 NAT 가 쌉니다.
>
> 시연이 끝나면 `99-destroy.sh` 한 줄로 전부 지웁니다.

### "왜 도메인이 없나요?"

> 아직 정하지 않았습니다. ALB 는 HTTP 로만 열려 있습니다.
>
> 도메인이 생기면 ACM 인증서를 만들고 값 파일 세 줄만 바꾸면
> HTTPS 가 됩니다. 그 자리는 이미 만들어뒀습니다.

### "보안은 어떻게 했나요?"

> 네 가지를 했습니다.
>
> **DB 는 사설 서브넷에** 두고 공인 IP 를 주지 않았습니다.
> 접근도 노드 보안그룹에서 오는 것만 허용합니다.
>
> **평문 접속을 서버가 거부**합니다 (`rds.force_ssl`).
>
> **Secret 을 워크로드별로 나눴습니다.** 크롤러는 DB 접속 정보만 받습니다.
> 뚫려도 관리자 비밀번호는 안 넘어갑니다.
>
> **IRSA 로 파드마다 IAM 역할**을 줍니다. 액세스 키가 컨테이너에 없습니다.
>
> 남은 것도 있습니다 — WAF 는 아직 안 붙였습니다.
> 앱 레벨 호출 제한은 파드 수만큼 느슨해지는데,
> 그건 WAF 의 rate-based rule 로 올려야 합니다.

### "로컬 검증이 정말 도움이 됐나요?"

> 됐습니다. 두 가지 면에서요.
>
> **첫째, 차트가 그대로 통했습니다.** `templates/` 12개를 안 바꿨습니다.
>
> **둘째, 무엇이 다른지 알고 시작했습니다.**
> 로컬에서 CloudNativePG 로 페일오버를 확인해뒀으니,
> RDS Multi-AZ 에서 같은 걸 볼 때 "무엇을 봐야 하는지" 알았습니다.
>
> 다만 로컬에 없던 개념 — IRSA · EBS CSI · ALB · ECR 인증 —
> 은 AWS 에서 처음 만났습니다. 그건 로컬로 대비할 수 없는 부분입니다.

---

## 🔴 시간이 부족하면

**슬라이드 2 와 4** 만 쓰셔도 됩니다.

| 슬라이드 | 메시지 |
|---|---|
| **2** | 로컬에서 검증한 것이 그대로 통했다 |
| **4** | 실제로 동작한다 (페일오버 시연) |

1번(순서)과 3번(CI/CD)은 **질문이 나오면** 꺼내는 백업으로 두셔도 좋습니다.
