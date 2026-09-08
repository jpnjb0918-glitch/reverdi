# Reverdi AWS Terraform

기존 `aws/cluster.yaml`, `aws/rds.yaml`, `aws/scripts/*.sh`의 목적을 Terraform으로 통합한 배포본입니다.

## 기존 설계와 대응

- VPC: `10.0.0.0/16`, 서울 3 AZ, public/private subnet
- NAT Gateway: 1개 (기존 `nat.gateway: Single`과 동일한 비용 절감 선택)
- EKS: managed node groups 3종
  - web: t3.medium × 3, `workload=web`
  - batch: t3.medium × 1, `workload=batch:NoSchedule`
  - infra: t3.medium × 1, `workload=infra:NoSchedule`
- EBS CSI + gp3 StorageClass
- AWS Load Balancer Controller + ALB
- Metrics Server + HPA
- RDS PostgreSQL 17, Multi-AZ writer + read replica
- RDS private subnet / 5432은 EKS node SG에서만 허용
- `rds.force_ssl=1`, storage encryption
- ECR backend/crawler + 최근 10개 lifecycle
- S3 upload bucket + public access block + AES256 encryption
- IRSA: ALB controller / EBS CSI / web S3 / batch S3
- Argo CD / Prometheus-Grafana / Jenkins 선택 설치
- 앱 Secret은 Terraform이 생성하므로 Terraform state에 비밀값이 들어갑니다.

> **중요:** Terraform state를 로컬 파일 하나로 장기간 보관하지 마세요. 실제 운영/팀 환경에서는 암호화된 S3 backend + DynamoDB locking(또는 HCP Terraform 등)을 사용하세요.

## 0. 사전 준비

Windows PowerShell 기준:

```powershell
aws configure
aws sts get-caller-identity

terraform version
helm version
kubectl version --client
```

AWS 자격 증명에는 EKS/VPC/RDS/IAM/ECR/S3를 만들 권한이 필요합니다.

## 1. Terraform 초기화

```powershell
cd reverdi-main	erraform
copy terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

첫 apply에서는 `deploy_app=false`로 두는 것을 권장합니다.

## 2. ECR 이미지 push

Terraform이 ECR repository만 만들고 애플리케이션 이미지를 빌드하지는 않습니다.

출력된 repository URL을 확인한 뒤:

```powershell
aws ecr get-login-password --region ap-northeast-2 |
  docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com

docker build --platform linux/amd64 -t <BACKEND_REPO>:git-abcdef1 -f <backend-dockerfile> .
docker push <BACKEND_REPO>:git-abcdef1

docker build --platform linux/amd64 -t <CRAWLER_REPO>:git-abcdef1 -f <crawler-dockerfile> .
docker push <CRAWLER_REPO>:git-abcdef1
```

이 저장소에는 Dockerfile 자체가 포함되어 있지 않으므로 실제 Dockerfile 경로는 애플리케이션 소스 저장소/빌드 환경에 맞춰 지정해야 합니다.

## 3. 앱 배포

`terraform.tfvars`:

```hcl
deploy_app = true
image_tag  = "git-abcdef1"
```

그 다음:

```powershell
terraform apply
```

Helm chart의 migration hook이 먼저 실행되고 웹 3개 + crawler CronJob + ALB가 올라갑니다.

## 4. 확인

```powershell
aws eks update-kubeconfig --region ap-northeast-2 --name reverdi

kubectl get nodes -L workload,topology.kubernetes.io/zone
kubectl get pods -A
kubectl get ingress -n reverdi
kubectl get pvc -A
```

ALB 주소:

```powershell
kubectl get ingress -n reverdi
```

앱 readiness:

```powershell
curl http://<ALB-DNS>/ready
```

`storage.mode`가 `s3`, database connected/write connected가 정상인지 확인합니다.

## 5. Argo CD / Grafana / Jenkins

인터넷에 NodePort로 노출하지 않고 ClusterIP로 설치합니다.

```powershell
kubectl port-forward -n argocd svc/argocd-server 8080:80
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
kubectl port-forward -n infra svc/jenkins 8080:8080
```

주의: 같은 로컬 포트를 동시에 사용할 수 없으므로 실제로는 각각 다른 터미널/포트를 사용하세요.

## 6. HTTPS

ACM 인증서와 DNS가 준비되면:

```hcl
domain              = "example.com"
acm_certificate_arn = "arn:aws:acm:..."
```

그리고 `app-values.yaml.tftpl`의 listen ports를 HTTPS까지 열도록 수정해야 합니다.

현재는 원본 설계와 동일하게 HTTP 80만 사용합니다.

## 7. 비용/삭제

이 구성은 EKS + NAT Gateway + RDS Multi-AZ + RDS read replica + 5대 EC2라 데모 환경에서도 비용이 발생합니다.

전체 삭제:

```powershell
terraform destroy
```

`force_destroy=true`인 S3와 `skip_final_snapshot=true`인 RDS를 사용하므로 **운영 환경에는 그대로 쓰지 마세요.**

## 원본 AWS 파일과 달라진 핵심

1. `eksctl + CloudFormation + bash`를 Terraform으로 통합했습니다.
2. EBS CSI IRSA 연결을 Terraform dependency로 고정했습니다.
3. EKS ServiceAccount가 원본 chart에는 없던 문제를 Terraform에서 직접 생성해 해결했습니다.
4. `values-aws.yaml`의 계정 ID/S3 bucket 하드코딩을 제거했습니다.
5. Argo CD/Jenkins/Prometheus의 Vagrant용 `NodePort`와 `local-path`를 AWS에서는 Terraform Helm override로 바꿉니다.
6. RDS는 기존 CloudFormation과 동일하게 private + Multi-AZ + read replica + TLS 강제 구조입니다.
7. 기존 `aws/scripts/70-argocd.sh`, `80-monitoring.sh`가 참조하는 `helm-values/aws/*.yaml` 파일이 현재 압축본에는 존재하지 않아, Terraform에서 AWS 차이를 직접 override하도록 만들었습니다.
