# Jenkins 파이프라인 — AWS 설정

> 로컬(Vagrant)에서 검증한 파이프라인을 AWS 에서 돌립니다.
> **로컬과 달라지는 건 세 가지**입니다.

---

## 로컬 ↔ AWS 차이

| | 로컬 | AWS |
|---|---|---|
| 레지스트리 | `192.168.56.15:30500` | **ECR** |
| 인증 | 없음 (HTTP) | 🔴 **IRSA + ECR 토큰** |
| 값 파일 | `values-vagrant.yaml` | `values-aws.yaml` |

Jenkinsfile 이 **파라미터로 받도록** 고쳤습니다. 한 파일로 양쪽을 다 씁니다.

---

## 1. 🔴 빌드 에이전트에 ECR 권한 주기

**먼저 해야 합니다.** 이게 없으면 파드가 아예 안 뜹니다.

```bash
bash aws/scripts/95-jenkins-irsa.sh
```

### 왜 따로 만드나

`cluster.yaml` 의 `reverdi-web` · `reverdi-batch` 는 **`reverdi` 네임스페이스**에 있습니다.
Jenkins 빌드 파드는 **`infra` 네임스페이스**에서 뜨므로 그 SA 를 못 씁니다.

```
serviceaccount "reverdi-batch" not found
```

그래서 `infra` 에 `jenkins-ecr` 을 하나 더 만듭니다.

**권한은 좁게** — `AmazonEC2ContainerRegistryPowerUser` 는 push·pull 만 됩니다.
저장소 삭제는 안 되고요.

### 확인

```bash
kubectl get sa jenkins-ecr -n infra -o jsonpath='{.metadata.annotations}' ; echo
```

`eks.amazonaws.com/role-arn` 이 나와야 합니다.

---

## 2. Jenkins 접속

```bash
kubectl port-forward -n infra svc/jenkins 8080:8080 &
kubectl exec -n infra svc/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password ; echo
```

```
http://localhost:8080     admin / (위 비밀번호)
```

---

## 3. GitHub 토큰 등록

`Jenkins 관리` → `Credentials` → `System` → `Global` → `Add Credentials`

| | |
|---|---|
| Kind | **Username with password** |
| Username | GitHub 아이디 |
| Password | Personal Access Token (`repo` 권한) |
| **ID** | 🔴 **`gitops-push-token`** |

> ID 가 다르면 마지막 단계(git 커밋)에서 실패합니다.

### 토큰이 없으면

`github.com` → Settings → Developer settings → Personal access tokens
→ **Tokens (classic)** → Generate → 🔴 **`repo` 체크**

---

## 4. 파이프라인 생성

`새로운 Item` → 이름 `reverdi-ci` → **Pipeline**

| | |
|---|---|
| Definition | **Pipeline script from SCM** |
| SCM | Git |
| Repository URL | `https://github.com/epqlffltm/CloudeDX.git` |
| Branch | `*/main` |
| Script Path | `Jenkinsfile` |

**저장** → **지금 빌드**

> 첫 빌드는 파라미터를 읽기 위해 한 번 돌고 실패할 수 있습니다.
> 두 번째부터 `매개변수와 함께 빌드` 가 나타납니다.

---

## 5. 빌드 파라미터

| 파라미터 | AWS | 로컬 |
|---|---|---|
| `REGISTRY` | `611669940814.dkr.ecr.ap-northeast-2.amazonaws.com` | `192.168.56.15:30500` |
| `VALUES_FILE` | `values-aws.yaml` | `values-vagrant.yaml` |

**기본값이 AWS** 로 되어 있습니다. 로컬에서 돌릴 때만 바꾸면 됩니다.

---

## 6. 파이프라인이 하는 일

```
① 준비        uv 설치 · IMAGE_TAG = git 커밋 7자리
② lint        ruff (crawler extra 포함)
③ test        사이드카 Postgres + alembic + pytest
④ build       🔴 ECR 로그인 → Buildah 로 이미지 2종 → push
⑤ chart lint  helm template 으로 렌더링 검증
⑥ gitops      values-aws.yaml 의 image.tag 를 git 에 커밋
```

**⑥ 이후 Argo CD 가 감지해 배포합니다.** Jenkins 는 클러스터를 만지지 않습니다.

### ④ 단계가 로컬과 다릅니다

```bash
# 레지스트리 주소에 amazonaws.com 이 있으면 ECR 로 판단
aws ecr get-login-password --region ap-northeast-2 \
  | buildah login --username AWS --password-stdin $REGISTRY
```

**액세스 키가 없습니다.** IRSA 로 붙은 IAM 역할이 토큰을 받습니다.
ECR 은 HTTPS 라 `--tls-verify=false` 도 필요 없고요.

---

## 7. 확인

빌드가 끝나면:

```bash
# ECR 에 새 태그가 올라갔는지
aws ecr describe-images --repository-name reverdi-backend --region ap-northeast-2 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-3:].[imageTags[0],imagePushedAt]' --output table
```

```bash
# git 에 태그가 커밋됐는지
cd /tmp && rm -rf ci && git clone --depth 1 -q https://github.com/jpnjb0918-glitch/reverdi.git ci
grep -n -A2 "^image:" ci/charts/reverdi/values-aws.yaml
```

```bash
# Argo CD 가 감지했는지
kubectl get application reverdi -n argocd
kubectl get pod -n reverdi -o wide
```

**파드의 이미지 태그가 바뀌면** 전체 흐름이 동작한 겁니다.

---

## 8. 막히면

### 파드가 안 뜸

```
serviceaccount "jenkins-ecr" not found
```

→ `bash aws/scripts/95-jenkins-irsa.sh` 를 안 돌린 겁니다.

### ECR push 실패

```
denied: User ... is not authorized to perform: ecr:PutImage
```

```bash
kubectl get sa jenkins-ecr -n infra -o yaml | grep role-arn
```

`role-arn` 이 없으면 IRSA 가 안 붙은 겁니다.

### git 커밋 실패

```
Authentication failed
```

→ 자격증명 ID 가 `gitops-push-token` 인지 확인하세요.

### 로그 보기

```bash
kubectl get pod -n infra | grep -v jenkins-0
kubectl logs -n infra <에이전트파드> -c buildah --tail=30
```

---

## 9. 🔴 로컬에서 돌릴 때

Jenkinsfile 의 `serviceAccountName: jenkins-ecr` 이 **로컬에는 없습니다.**

```bash
# Vagrant 클러스터에서
kubectl create sa jenkins-ecr -n infra
```

빈 SA 라도 있으면 파드가 뜹니다. 로컬 레지스트리는 인증이 없으니 권한도 불필요합니다.

**또는** Jenkinsfile 에서 그 줄을 지우면 됩니다.
