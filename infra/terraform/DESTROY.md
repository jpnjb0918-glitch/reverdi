# 삭제 절차

> 🔴 **`terraform destroy` 만으로는 안 지워집니다.**
>
> 앞서 eksctl 로 만든 클러스터를 지울 때 **세 번 실패**했습니다.
> Terraform 도 같은 함정이 있습니다.

---

## 왜 실패하나

Terraform 은 **자기가 만든 것만** 압니다.

```
Helm 이 Ingress 를 만듦
  → ALB 컨트롤러가 ALB 와 보안그룹을 만듦   ← Terraform 은 모름
  → VPC 삭제 시 그것들이 막는다
```

PVC 도 마찬가지입니다. EBS 볼륨은 **CSI 드라이버가** 만들었습니다.

---

## 🔴 순서

### ① 컨트롤러가 살아 있을 때 정리

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name reverdi

# LoadBalancer 타입 Service 를 ClusterIP 로 되돌린다
kubectl get svc -A -o json | \
  jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns n; do kubectl patch svc "$n" -n "$ns" -p '{"spec":{"type":"ClusterIP"}}'; done

kubectl delete ingress --all -A --timeout=180s
```

**2~3분 기다린 뒤** 확인합니다.

```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'length(LoadBalancers)'
aws elb   describe-load-balancers --region ap-northeast-2 --query 'length(LoadBalancerDescriptions)'
```

🔴 **둘 다 `0` 이어야** 합니다.

> 클래식 LB(`elb`)와 ALB/NLB(`elbv2`)는 API 가 다릅니다.
> 앞서 `elbv2` 만 보고 "없다" 고 판단했다가 삭제가 실패했습니다.

### ② PVC 삭제 — EBS 볼륨이 남지 않게

```bash
kubectl delete pvc --all -A --timeout=180s
sleep 60
```

### ③ Terraform destroy

```bash
cd infra/terraform
terraform destroy
```

**20~30분** 걸립니다.

### ④ 잔재 확인

```bash
aws ec2 describe-addresses --region ap-northeast-2 --query 'Addresses[].[PublicIp]' --output table
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]' --output table
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName' --output text
aws elb   describe-load-balancers --region ap-northeast-2 --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
```

**전부 비어야** 요금이 멈춥니다.

---

## destroy 가 실패하면

### VPC 삭제가 막힐 때

컨트롤러가 만든 보안그룹이 남아 있습니다.

```bash
VPC=$(aws ec2 describe-vpcs --region ap-northeast-2 \
  --filters "Name=tag:Name,Values=reverdi-vpc" --query 'Vpcs[0].VpcId' --output text)

for sg in $(aws ec2 describe-security-groups --region ap-northeast-2 \
    --filters "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
  aws ec2 delete-security-group --group-id "$sg" --region ap-northeast-2
done

terraform destroy
```

`k8s-elb-*` · `k8s-traffic-*` 같은 이름이면 컨트롤러가 만든 것입니다.

### 상태와 실제가 어긋날 때

```bash
terraform refresh
terraform state list
```

손으로 지운 리소스가 있으면 상태에서 뺍니다.

```bash
terraform state rm <주소>
```

---

## 남기는 것

| | 요금 |
|---|---|
| **ECR 이미지** | 5GB 미만 월 $0.5 — 다시 만들 때 빌드 30분 절약 |
| Route 53 호스팅 영역 | 월 $0.5 — 도메인을 유지하면 필요 |
| 도메인 등록 | 연 $14 — Terraform 이 안 건드림 |

`force_destroy = true` 라 **S3 는 안에 든 것까지 지워집니다.**
로그나 업로드 파일을 남기려면 먼저 내려받으세요.

```bash
aws s3 sync s3://reverdi-loki-<계정> ./loki-backup/
```
