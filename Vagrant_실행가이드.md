# Vagrant 실행 가이드

> `vagrant up` 한 번으로 VM 6대에 쿠버네티스 클러스터와 앱·CI/CD·모니터링까지 올립니다.
>
> **✅ 2026-09-04 검증 완료** — 처음부터 다시 돌려 **약 90분** 만에 성공했습니다.

---

## 0. 시작하기 전에

### PC 사양 확인

| | 필요 |
|---|---|
| **RAM** | 🔴 **48GB 이상 권장** (VM 이 40GB 를 씁니다) |
| 디스크 여유 | 300GB |
| CPU | 8코어 이상 |

**RAM 이 32GB 이하면** 그대로 돌리기 어렵습니다. 아래 "9. RAM 이 부족하면" 을 보세요.

### 시간

**80~110분** 걸립니다. 대부분 이미지 다운로드와 크롤러 빌드(2.7GB) 시간입니다.
켜두고 다른 일 하셔도 됩니다.

---

## 1. 설치 (한 번만)

### ① VirtualBox

`https://www.virtualbox.org/wiki/Downloads` → **Windows hosts**

> ⚠️ **Hyper-V 와 충돌할 수 있습니다.**
> WSL2 나 Docker Desktop 을 쓰고 있다면 VirtualBox **7.1 이상**을 설치하세요.
> 그래도 VM 이 안 뜨면 관리자 PowerShell 에서:
> ```powershell
> bcdedit /enum | findstr hypervisorlaunchtype
> ```
> `Off` 로 바꾸면 VirtualBox 는 되지만 **WSL2 · Docker Desktop 이 함께 죽습니다.**

### ② Vagrant

`https://developer.hashicorp.com/vagrant/downloads` → **Windows AMD64**

🔴 설치 후 **PowerShell 을 새로 열어야** PATH 가 반영됩니다.

```powershell
vagrant --version
VBoxManage --version
```

둘 다 버전이 나오면 됩니다.

### ③ 디스크 플러그인

```powershell
vagrant plugin install vagrant-disksize
```

node4(60GB) · node5(100GB) 를 늘리는 데 필요합니다.

### ④ (권장) 콘솔 인코딩

```powershell
chcp 65001
```

이걸 안 하면 진행 메시지의 한글이 `?⑦궎吏` 처럼 깨져 보입니다.
**실행에는 지장이 없지만** 진행 상황을 읽기 어렵습니다.

---

## 2. 저장소 받기

```powershell
cd D:\          # 원하는 위치
git clone https://github.com/jpnjb0918-glitch/reverdi.git
cd reverdi\vagrant
```

> 🔴 **zip 으로 받지 마세요.** 윈도우 기본 압축 해제가 한글 인코딩을 깨뜨린 사례가 있습니다.
> `git clone` 이 확실합니다.

---

## 3. 실행

```powershell
vagrant up
```

로그를 남기려면:

```powershell
vagrant up 2>&1 | Out-File -FilePath build.log -Encoding utf8
```

> ⚠️ `Tee-Object` 는 콘솔 인코딩으로 기록해 한글이 깨집니다.
> **`Out-File -Encoding utf8`** 을 쓰세요.

---

## 4. 진행 중 보이는 정상 메시지

**아래는 전부 정상입니다.** 빨간 글씨로 나와도 오류가 아닙니다.

| 메시지 | 의미 |
|---|---|
| `Disk cannot be decreased in size. 30720 MB requested but disk is already 65536 MB` | bento 박스가 이미 64GB. 더 큰 건 문제없음 |
| `debconf: unable to initialize frontend` | 컨테이너에 터미널이 없음. `Noninteractive` 로 진행 |
| `Fixed port collision for 22` | Vagrant 가 알아서 포트를 옮김 |
| 한글이 `?⑦궎吏` 로 깨짐 | 콘솔 인코딩. VM 안에서는 정상 |

### 오래 걸려 멈춘 것처럼 보이는 구간

| 구간 | 시간 | 무엇을 하나 |
|---|---|---|
| 박스 다운로드 (첫 VM) | 5~10분 | ~600MB |
| `[1/5] 패키지 설치` (각 VM) | 2~3분 | dnf install |
| k3s 설치 (각 VM) | 1~2분 | |
| 🔴 **크롤러 이미지 빌드** | **20~30분** | 2.7GB · Chromium 다운로드 |
| Jenkins 플러그인 설치 | 5~10분 | |

**크롤러 빌드가 가장 깁니다.** 화면이 안 움직여도 기다리세요.

---

## 5. 진행 순서

```
node0 ~ node5 생성 · k3s 설치          각 10~15분
        ↓
node5 가 끝나면 자동으로 클러스터 구성 시작
        ↓
taint · 네임스페이스
레지스트리
이미지 빌드 (여기가 제일 오래)
DB (CloudNativePG 3대)
앱 배포 (Helm)
Argo CD
Prometheus · Grafana
Jenkins
        ↓
🔴 접속 정보 출력
```

### 다른 창에서 진행 확인

```powershell
cd D:\reverdi\vagrant
vagrant status
```

```powershell
vagrant ssh node0 -c "kubectl get nodes"
```

노드가 하나씩 늘어나는 걸 볼 수 있습니다.

---

## 6. 끝나면

마지막에 접속 주소와 비밀번호가 한 번에 출력됩니다.
**놓쳤거나 화면이 깨져 안 보이면** 다시 볼 수 있습니다.

```powershell
vagrant ssh node0 -c "bash /tmp/scripts/99-summary.sh"
```

### 접속 주소

| 포트 | 서비스 |
|---|---|
| **30080** | 웹 앱 (Reverdi) |
| **30081** | Argo CD |
| **30300** | Grafana |
| **30500** | 레지스트리 |
| **30808** | Jenkins |

`http://192.168.56.11:<포트>` — **`.11` ~ `.15` 아무 노드로 들어와도** 됩니다.

### 🔴 비밀번호는 설치할 때마다 새로 만들어집니다

파일에 적혀 있지 않습니다. 필요할 때 꺼내 씁니다.

```powershell
vagrant ssh node0
```

```bash
# 웹 앱
kubectl get secret reverdi-secret -n reverdi -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d ; echo

# DB
kubectl get secret reverdi-db-app -n reverdi -o jsonpath='{.data.password}' | base64 -d ; echo

# Grafana
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d ; echo

# Argo CD
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# Jenkins
kubectl exec -n infra svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password ; echo
```

---

## 7. 잘 됐는지 확인

```powershell
vagrant ssh node0
```

### 노드

```bash
kubectl get nodes -o wide
```

**6대가 `Ready`** 이고 **INTERNAL-IP 가 `.10` ~ `.15` 로 각자 다른지** 봅니다.
전부 `10.0.2.15` 로 같으면 문제입니다.

### 파드 분산

```bash
kubectl get pod -n reverdi -o wide
```

**웹 3개와 DB 3개가 node1 · 2 · 3 에 하나씩**이면 정상입니다.

### 앱

```bash
curl -s http://192.168.56.11:30080/ready | python3 -m json.tool
```

```json
{
  "ready": true,
  "database":       { "connected": true },
  "database_write": { "connected": true },
  "migration":      { "up_to_date": true }
}
```

### 전체

```bash
kubectl get pod -A -o wide | grep -v kube-system
```

`Running` 이 아닌 게 있으면 아래 "8. 막히면" 을 보세요.

---

## 8. 막히면

### 특정 단계만 다시 실행

각 스크립트는 **독립적으로 다시 돌릴 수 있습니다.**

```powershell
vagrant ssh node0
```

```bash
bash /tmp/scripts/60-app.sh        # 앱만 다시 배포
bash /tmp/scripts/80-monitoring.sh # 모니터링만
bash /tmp/scripts/99-summary.sh    # 접속 정보 다시 보기
```

### 증상별

| 증상 | 원인 | 조치 |
|---|---|---|
| `Timed out while waiting for the machine to boot` | 첫 부팅이 오래 걸림 | `vagrant status` 로 확인 후 `vagrant reload <노드>` |
| **Jenkins 파드가 `Init` 에서 멈춤** | 플러그인 의존성 충돌 (버전이 `:latest` 라 시점에 따라 다름) | `kubectl logs -n infra jenkins-0 -c init` → 아래 참조 |
| 박스 다운로드 404 | Rocky 가 Vault 로 이전 | Vagrantfile 이 이미 `bento` 사용 중 |
| 파드가 `Pending` | taint 에 toleration 없음 | `kubectl describe pod -n <ns> <파드>` |
| `ImagePullBackOff` | `registries.yaml` 미배포 | `bash /tmp/scripts/30-registry.sh` |
| `CreateContainerConfigError` | Secret 없음 | `bash /tmp/scripts/50-database.sh` |
| 노드 간 통신 안 됨 | Flannel 인터페이스 | `ip -d link show flannel.1` → `local 192.168.56.x` 확인 |

### Jenkins 플러그인 충돌

플러그인 버전을 `:latest` 로 두어, **설치 시점에 따라 조합이 달라집니다.**
의존성이 충돌하면 Jenkins 가 아예 뜨지 않습니다.

```bash
kubectl logs -n infra jenkins-0 -c init
```

```
Plugin git:X depends on configuration-as-code:Y,
but there is an older version defined on the top level
```

이런 메시지가 보이면 **그 플러그인을 명시적으로 추가**하거나,
`vagrant/scripts/90-jenkins.sh` 에서 차트 기본 버전을 쓰게 바꿉니다.

```yaml
  installLatestPlugins: false
```

그다음 다시 실행합니다.

```bash
helm uninstall jenkins -n infra
bash /tmp/scripts/90-jenkins.sh
```

> Jenkins 는 **CI 용이라 나머지와 독립**입니다.
> 여기서 막혀도 클러스터 · 앱 · DB · Argo CD · 모니터링은 이미 동작합니다.

### 처음부터 다시

```powershell
vagrant destroy -f
vagrant up
```

**5분이면 초기화**됩니다. 로컬 검증의 장점입니다.

### 그래도 안 되면

`build.log` 에서 **`Error` · `failed` · `command not found` · `non-zero exit status`** 를 찾아
그 앞뒤 20줄을 공유해주세요. 영어라 인코딩이 깨져도 읽힙니다.

**이미 겪은 문제 28건**이 `문제해결_기록.md` 에 정리돼 있습니다. 먼저 찾아보세요.

---

## 9. RAM 이 부족하면

`Vagrantfile` 의 `NODES` 배열에서 줄을 지우면 됩니다.

```ruby
NODES = [
  ["node0",  10,   4096,  2,   "30GB"],
  ["node1",  11,   4096,  2,   "30GB"],
  ["node2",  12,   4096,  2,   "30GB"],
  ["node3",  13,   4096,  2,   "30GB"],
  # ["node4",  14,   8192,  4,   "60GB"],   ← 지우면 크롤러·빌드 불가
  # ["node5",  15,  16384,  4,  "100GB"],   ← 지우면 레지스트리·CI/CD 불가
]
```

| 구성 | RAM | 가능한 것 |
|---|---:|---|
| 6 VM (기본) | 40GB | 전부 |
| 4 VM (node0~3) | **16GB** | 클러스터 · DB 페일오버 |

> ⚠️ 4 VM 으로 줄이면 `30-registry.sh` 이후가 실패합니다.
> 클러스터와 DB 까지만 확인하는 용도입니다.

---

## 10. VM 관리

```powershell
vagrant halt          # 정지 — 🔴 작업 끝나면 꼭 (RAM 40GB 를 잡고 있습니다)
vagrant up            # 다시 시작 — 클러스터는 그대로 복구됩니다
vagrant ssh node0     # 접속 (kubectl · helm 은 여기서)
vagrant status        # 상태
vagrant destroy -f    # 전부 삭제
```

### 🔴 PC 를 끄기 전에 `vagrant halt`

그냥 종료하면 다음에 켤 때 클러스터가 이상해질 수 있습니다.

---

## 11. 자동화하지 못한 것 — Jenkins 토큰

Jenkins 파이프라인을 돌리려면 **GitHub 토큰**이 필요합니다.
개인 자격증명이라 스크립트에 넣을 수 없습니다.

**여기까지 안 해도 나머지는 전부 동작합니다.** 필요할 때 하세요.

### ① 토큰 발급

`github.com` → 프로필 → **Settings** → 맨 아래 **Developer settings**
→ **Personal access tokens** → **Tokens (classic)** → **Generate new token**
→ 🔴 **`repo` 체크** → 생성

`ghp_...` 값을 복사합니다. **한 번만 보입니다.**

### ② Jenkins 에 등록

`http://192.168.56.11:30808` 접속 (비밀번호는 6번 참조)

`Jenkins 관리` → `Credentials` → `System` → `Global` → **Add Credentials**

| | |
|---|---|
| Kind | Username with password |
| Username | GitHub 아이디 |
| Password | 토큰 |
| **ID** | 🔴 **`gitops-push-token`** |

> ID 가 다르면 파이프라인 마지막 단계에서 실패합니다. Jenkinsfile 이 이 이름으로 찾습니다.

### ③ 파이프라인 생성

`새로운 Item` → 이름 `reverdi-ci` → **Pipeline** 선택

| | |
|---|---|
| Definition | **Pipeline script from SCM** |
| SCM | Git |
| Repository URL | `https://github.com/epqlffltm/CloudeDX.git` |
| Branch | `*/main` |
| Script Path | `Jenkinsfile` |

**저장** → **지금 빌드**

첫 빌드는 **15~25분** 걸립니다.

---

## 12. 시연해볼 것

### 🔴 DB 페일오버 — 발표용

**터미널 2개**를 엽니다. 둘 다 `vagrant ssh node0` 으로 접속합니다.

**창 1 — 조회를 계속 때린다**

```bash
while true; do
  printf '%s  ' "$(date +%H:%M:%S)"
  curl -s -o /dev/null -w "%{http_code}\n" -m 3 http://192.168.56.11:30080/
  sleep 1
done
```

**창 2 — 주 DB 를 죽인다**

```bash
kubectl get cluster -n reverdi          # PRIMARY 확인
kubectl delete pod -n reverdi reverdi-db-1
kubectl get cluster -n reverdi          # 자동 승격 관찰
```

**관찰** — 창 1 의 `200` 이 **끊기지 않으면서** `PRIMARY` 가 바뀝니다.
읽기는 replica 로 가기 때문입니다. **AWS RDS Multi-AZ 와 같은 동작**입니다.

### Argo CD self-heal

```bash
kubectl scale deploy reverdi-web -n reverdi --replicas=1
kubectl get pod -n reverdi -w
```

손으로 1개로 줄여도 **Argo CD 가 3개로 되돌립니다.**
git 에 적힌 것이 정답이기 때문입니다.

### 크롤러

```bash
kubectl create job -n reverdi --from=cronjob/reverdi-crawler crawl-1
kubectl logs -n reverdi -l job-name=crawl-1 -f
```

**node4 에서만** 돕니다 (taint 로 격리).
당근마켓 · 중고나라 · 번개장터를 순서대로 긁습니다.

### 속도 제한

```bash
for i in $(seq 1 12); do
  curl -s -o /dev/null -w "%{http_code} " -X POST \
    http://192.168.56.11:30080/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"wrong"}'
done ; echo
```

`401` 이 이어지다 **`429`** 가 나옵니다.

> ⚠️ 설정은 5회인데 **12회쯤에서 잠깁니다.**
> 파드가 3개라 각자 따로 세기 때문입니다. 이게 앱 레벨 제한의 한계고,
> 운영에서는 **AWS WAF** 로 올려야 합니다.

### Grafana 에서 앱 지표

`http://192.168.56.11:30300` → `Explore` → Prometheus → **Code** 모드

```
http_requests_total
sum(rate(http_requests_total[1m])) by (status)
```

---

## 13. 함께 읽으면 좋은 것

| 문서 | 내용 |
|---|---|
| `문제해결_기록.md` | **겪은 문제 28건** — 증상 · 원인 · 해결 · 배운 것 |
| `팀공유_구축테스트정리.md` | 최종 구성 · 검증 결과 · 담당별 작업 |
| `구축테스트_정리.drawio` | 도표 3장 |
| `AWS구성도_슬라이드.drawio` | 발표용 도표 4장 |

**막히면 `문제해결_기록.md` 를 먼저 찾아보세요.** 이미 겪은 것일 가능성이 높습니다.
