# AWS 이관 최종 — 변경 사항

> 2026-09-06 · EKS 실제 배포 완료. **`Synced / Healthy`**
> 배포 중 겪은 **8건**을 전부 반영했습니다.

---

## 최종 상태

| | |
|---|---|
| EKS 클러스터 | 노드 5대 (web 3 · batch 1 · infra 1) |
| RDS | Multi-AZ + 읽기 복제본 · `rds.force_ssl=1` |
| 웹 앱 | ALB · 3 AZ 분산 · `/ready` 전부 true |
| Argo CD | **Synced / Healthy** |
| Prometheus · Grafana · Jenkins | 정상 |
| Grafana 외부 노출 | NLB (학원에서 접속용) |

---

## 반영한 8건

| # | 파일 | 변경 |
|:--:|---|---|
| 21 | `aws/cluster.yaml` | 노드그룹 `availabilityZones` **제거** |
| 22 | `aws/rds.yaml` | `EngineVersion` → **`"17"`** |
| 23 | `values-aws.yaml` | ALB **HTTP 전용** |
| 24 | `values.yaml` · 템플릿 5개 | **IRSA** (`serviceAccountName`) |
| 25 | `cluster.yaml` · `20-addons.sh` | **EBS CSI** 애드온 + IRSA 연결 |
| 26 | `cluster.yaml` | batch `t3.small` → **`t3.medium`** |
| 27 | `deployment.yaml` | **주석 안의 Helm 문법 제거** |
| 28 | `20-addons.sh` | **metrics-server** 설치 |

---

## 🔴 로컬(Vagrant)에는 영향이 없습니다

```bash
helm template reverdi charts/reverdi -f charts/reverdi/values-vagrant.yaml | grep -c serviceAccountName
# → 0

helm template reverdi charts/reverdi -f charts/reverdi/values-aws.yaml | grep -c serviceAccountName
# → 3
```

**"환경 차이를 값으로 흡수한다"** 는 원칙이 지켜졌습니다.

---

## 특히 주의할 3건

### 25 — EBS CSI (가장 헷갈렸다)

**스크립트는 전부 "성공"으로 끝났는데 파드만 조용히 `Pending`** 이었습니다.

```
infra        jenkins-0            0/2   Pending
monitoring   kps-grafana-...      0/3   Pending
monitoring   prometheus-...       0/2   Pending
```

Helm 은 릴리스가 설치되면 성공입니다. **파드가 뜨는지는 안 봅니다.**

`cluster.yaml` 의 `serviceAccountRoleARN: null` 때문에 애드온이 아예 안 만들어졌고,
PVC 가 전부 `Pending` 이었습니다.

**역할 이름이 무작위**라 `cluster.yaml` 에 미리 적을 수 없어,
**조회·연결을 `20-addons.sh` 로 옮겼습니다.**

### 27 — 주석이 렌더링을 깨뜨림

24번을 고치면서 그 교훈을 주석으로 적었는데, **그 주석이 새 오류를 만들었습니다.**

```yaml
#    ⚠️ 이 줄을 {{- with }} 블록 안에 넣으면 안 된다.
```

**Helm 은 YAML 주석을 무시하지 않습니다.** 템플릿 엔진이 먼저 읽어서
`{{- with }}` 를 문법으로 처리합니다.

**검사**

```bash
grep -rn "^\s*#.*{{" charts/reverdi/templates/
```

아무것도 안 나와야 합니다.

### 25 · 28 — k3s 내장이 EKS 에는 없다

| | k3s | EKS |
|---|---|---|
| 스토리지 프로비저너 | `local-path` **내장** | EBS CSI **직접 설치** |
| 메트릭 | metrics-server **내장** | **직접 설치** |

"쿠버네티스는 같다"고 생각했는데, **배포판이 무엇을 끼워주느냐가 달랐습니다.**

---

## 적용

```bash
cd <저장소>
# 압축 해제 (기존 파일 덮어쓰기)

git status
git add -A
git commit -m "fix: AWS 이관 8건 반영 (EBS CSI · metrics-server · batch 노드 · 주석)"
git push
```

### 실행 중인 클러스터에는

**이미 손으로 다 적용**하셨으므로 추가 작업이 없습니다.
다음에 `vagrant destroy` 후 처음부터 다시 만들 때 이 파일들이 쓰입니다.

---

## 처음부터 다시 만들 때

```bash
bash aws/scripts/00-preflight.sh
bash aws/scripts/10-cluster.sh       # AZ · batch t3.medium 반영
bash aws/scripts/20-addons.sh        # 🔴 EBS CSI IRSA + metrics-server 포함
bash aws/scripts/30-ecr.sh
bash aws/scripts/40-rds.sh           # EngineVersion "17"
bash aws/scripts/50-secrets.sh
bash aws/scripts/55-fill-values.sh
bash aws/scripts/60-app.sh           # IRSA · ALB HTTP 전용
bash aws/scripts/70-argocd.sh
bash aws/scripts/80-monitoring.sh
bash aws/scripts/90-jenkins.sh
bash aws/scripts/99-summary.sh
```

**이번에 겪은 8건은 다시 안 나옵니다.**

---

## 🔴 시연 끝나면

```bash
# Grafana 외부 노출 닫기
kubectl patch svc kps-grafana -n monitoring -p '{"spec":{"type":"ClusterIP"}}'

# 전체 삭제
bash aws/scripts/99-destroy.sh
```

**하루 약 $14** 씩 나갑니다. 2~3주면 $290~300입니다.

### 시연 안 하는 날

```bash
eksctl scale nodegroup --cluster reverdi --name reverdi-web --nodes 0 --region ap-northeast-2
```

하루 $14 → $8 정도로 줄어듭니다.

---

## 문서

`문제해결_기록.md` 가 **28건**이 되었습니다.

| 구간 | 건수 |
|---|:--:|
| 로컬 구축 (1~20) | 20 |
| **AWS 이관 (21~28)** | **8** |

### 분류

| | 건수 |
|---|:--:|
| 환경 · 도구 문제 | 7 |
| **우리 코드 · 설정의 실수** | **17** |
| 이해가 부족했던 것 | 4 |

### AWS 8건의 공통점

| # | 로컬에서는 | AWS 에서는 |
|:--:|---|---|
| 21 | AZ 를 우리가 정함 | eksctl 이 고름 |
| 22 | 이미지 태그를 우리가 고름 | AWS 가 지원하는 것만 |
| 23 | NodePort — 인증서 개념 없음 | ALB 가 인증서를 요구 |
| 24 | 자격증명을 Secret 에 | IRSA 로 파드마다 |
| 25 | `local-path` 내장 | EBS CSI 직접 설치 |
| 26 | node4 가 8GB | t3.small 은 할당 가능 1.4GB |
| 27 | (해당 없음) | 주석이 렌더링을 깨뜨림 |
| 28 | metrics-server 내장 | 직접 설치 |

**"우리가 정할 수 있었던 것이 관리형 서비스에서는 아니다."**

발표에서 쓸 만한 정리입니다.
