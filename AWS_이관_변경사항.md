# AWS 이관 — 변경 사항

> 2026-09-06 · 실제 EKS 배포 중 발견한 문제 4건을 반영했습니다.
> **로컬(Vagrant)에는 영향이 없습니다.**

---

## 무엇이 바뀌었나

| 파일 | 변경 | 이유 |
|---|---|---|
| `aws/cluster.yaml` | 노드그룹 `availabilityZones` **제거** | eksctl 이 고른 AZ 와 어긋남 (문제 21) |
| `aws/rds.yaml` | `EngineVersion: "17.2"` → **`"17"`** | RDS 에 17.2 가 없음 (문제 22) |
| `charts/reverdi/values-aws.yaml` | ALB **HTTP 전용** | 인증서 없이 HTTPS 리스너 불가 (문제 23) |
| `charts/reverdi/values.yaml` | **IRSA 키 추가** (빈 값) | 로컬은 그대로 (문제 24) |
| `charts/reverdi/values-aws.yaml` | **IRSA 값** 추가 | 파드별 IAM 역할 |
| `charts/reverdi/templates/deployment.yaml` | `serviceAccountName` | |
| `templates/crawler-cronjob.yaml` 외 3개 | `batchServiceAccountName` | |

---

## 🔴 로컬에 영향이 없는 이유

`values-vagrant.yaml` 에 IRSA 값이 없어 **렌더링 자체가 안 됩니다.**

```bash
helm template reverdi charts/reverdi -f charts/reverdi/values-vagrant.yaml \
  | grep -c serviceAccountName
# → 0

helm template reverdi charts/reverdi -f charts/reverdi/values-aws.yaml \
  | grep -c serviceAccountName
# → 3
```

**"환경 차이를 값으로 흡수한다"** 는 원칙이 지켜졌습니다.

---

## 적용

```bash
cd <저장소>
# 압축 해제 (기존 파일 덮어쓰기)

git status
git add -A
git commit -m "fix: AWS 이관 - IRSA, ALB HTTP 전용, RDS 메이저 버전, 노드그룹 AZ"
git push
```

### 로컬 클러스터가 떠 있으면

**아무것도 안 해도 됩니다.** 다음 `helm upgrade` 때 자연스럽게 반영되고,
결과는 지금과 같습니다.

확인만 하시려면:

```bash
helm template reverdi charts/reverdi -f charts/reverdi/values-vagrant.yaml | grep -c serviceAccountName
# 0 이면 로컬은 그대로
```

---

## 각 변경의 상세

### ① 노드그룹 AZ 제거

```yaml
# 전
availabilityZones: [ap-northeast-2a, ap-northeast-2b, ap-northeast-2c]

# 후 — 없음
```

eksctl 이 VPC 를 만들 때 AZ 를 스스로 고릅니다. 이번엔 **b·c·d** 를 골랐는데
노드그룹에 `2a` 를 박아둬서 실패했습니다.

비워두면 **ASG 가 사설 서브넷 전체에 분산**합니다.

### ② RDS 메이저 버전

```yaml
EngineVersion: "17"     # 전: "17.2"
```

RDS 는 관리형이라 AWS 가 지원하는 마이너만 씁니다.
2026-09 기준 **17.5~17.11** 만 있습니다.

### ③ ALB HTTP 전용

```yaml
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
# ssl-redirect 제거
```

도메인이 없어 `certificateArn` 을 비웠는데 HTTPS 443 이 남아 있어
**ALB 생성 자체가 실패**했습니다.

**도메인이 생기면 세 가지를 같이** 바꿔야 합니다.

| | |
|---|---|
| `certificateArn` | ACM ARN |
| `listen-ports` | `'[{"HTTP": 80}, {"HTTPS": 443}]'` |
| `ssl-redirect` | `"443"` |

값 파일 주석에 적어뒀습니다.

### ④ IRSA

```yaml
# values.yaml — 로컬은 비운다
serviceAccountName: ""
batchServiceAccountName: ""

# values-aws.yaml
serviceAccountName: reverdi-web        # S3 읽기/쓰기/삭제
batchServiceAccountName: reverdi-batch # S3 쓰기만
```

이게 없으면 파드가 **노드의 IAM 역할**로 AWS 에 붙습니다.

```
INFO  Found credentials from IAM Role: ...NodeInstanceRole
ERROR S3 저장소 확인 실패 (AccessDenied)
```

**⚠️ `with` 블록 안에 넣으면 안 됩니다.**

```
nil pointer evaluating interface {}.serviceAccountName
```

`with` 안에서는 `.` 이 바뀌어 `.Values` 를 못 읽습니다.
`spec:` 바로 아래, 어떤 `with` 도 시작되기 전에 넣었습니다.

---

## 문제 기록

`문제해결_기록.md` 에 **21~24번**으로 추가했습니다.

| # | |
|:--:|---|
| 21 | eksctl AZ 불일치 |
| 22 | RDS 17.2 없음 |
| 23 | 인증서 없이 HTTPS 리스너 |
| 24 | 노드 IAM 역할로 S3 접근 (IRSA 누락) |

**총 24건**이 되었고, 전 문서의 건수도 맞췄습니다.

### 네 건의 공통점

| # | 로컬에서는 | AWS 에서는 |
|:--:|---|---|
| 21 | AZ 를 우리가 정함 | **eksctl 이 고름** |
| 22 | 이미지 태그를 우리가 고름 | **AWS 가 지원하는 것만** |
| 23 | NodePort — 인증서 개념 없음 | **ALB 가 인증서를 요구** |
| 24 | 자격증명을 Secret 에 | **IRSA 로 파드마다** |

**"우리가 정할 수 있었던 것이 관리형 서비스에서는 아니다."**

발표에서 쓸 만한 정리입니다.
