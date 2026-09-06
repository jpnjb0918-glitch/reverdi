#!/bin/bash
# ===========================================================================
# 🔴 전체 삭제 — 시연이 끝나면 반드시 실행
#
# 안 지우면 하루 $13, 한 달 $400 이 계속 나갑니다.
#
# 🔴 순서가 중요하다
#    ① Helm 릴리스 먼저 — ALB 와 EBS 볼륨이 여기서 지워진다
#    ② RDS 스택
#    ③ EKS 클러스터 (VPC · NAT 포함)
#    ④ 남은 것 (ECR · S3 · 로그)
#
#    순서를 바꾸면 eksctl 이 VPC 를 못 지운다.
#    ALB 가 서브넷을 잡고 있는데 그건 쿠버네티스가 만든 거라
#    CloudFormation 이 모른다. "DependencyViolation" 으로 멈춘다.
# ===========================================================================
set -uo pipefail
REGION="ap-northeast-2"
CLUSTER="reverdi"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

echo ""
echo "==========================================================="
echo " 🔴 전체 삭제"
echo "==========================================================="
echo ""
echo "  지워지는 것"
echo "    EKS 클러스터 · 노드 5대 · VPC · NAT Gateway"
echo "    RDS (주 · 스탠바이 · 읽기 복제본) — 🔴 데이터가 사라집니다"
echo "    ALB · EBS 볼륨 · CloudWatch 로그"
echo ""
echo "  남기는 것 (선택 삭제)"
echo "    ECR 이미지 · S3 버킷"
echo ""
read -p "  정말 지우시겠습니까? (yes 입력): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "  취소했습니다."; exit 0; }

echo ""
echo "--- [1/4] Helm 릴리스 (ALB · EBS 정리) ---"
for r in "reverdi:reverdi" "argocd:argocd" "kps:monitoring" "jenkins:infra" \
         "aws-load-balancer-controller:kube-system"; do
  n="${r%%:*}"; ns="${r##*:}"
  helm uninstall "$n" -n "$ns" 2>/dev/null && echo "  OK   $n" || echo "  -    $n (없음)"
done

echo ""
echo "  Ingress 정리 대기 (ALB 삭제 · 2~3분)..."
kubectl delete ingress --all -A --timeout=180s 2>/dev/null || true
sleep 60

echo ""
echo "  PVC 정리 (EBS 볼륨)"
kubectl delete pvc --all -A --timeout=180s 2>/dev/null || true

echo ""
echo "--- [2/4] RDS 스택 ---"
if aws cloudformation describe-stacks --stack-name reverdi-rds --region "$REGION" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name reverdi-rds --region "$REGION"
  echo "  삭제 요청 — 완료까지 10~15분"
  aws cloudformation wait stack-delete-complete --stack-name reverdi-rds --region "$REGION" && echo "  OK   RDS"
else
  echo "  -    RDS 스택 없음"
fi

echo ""
echo "--- [3/4] EKS 클러스터 (15~20분) ---"
eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait && echo "  OK   클러스터"

echo ""
echo "--- [4/4] 남은 것 ---"
echo ""
echo "  ECR 이미지 (선택)"
echo "    aws ecr delete-repository --repository-name reverdi-backend --force --region $REGION"
echo "    aws ecr delete-repository --repository-name reverdi-crawler --force --region $REGION"
echo ""
echo "  S3 버킷 (선택 — 업로드 이미지가 사라집니다)"
echo "    aws s3 rb s3://reverdi-uploads-${ACCOUNT} --force"
echo ""
echo "  CloudWatch 로그 그룹"
echo "    aws logs delete-log-group --log-group-name /aws/eks/${CLUSTER}/cluster --region $REGION"

echo ""
echo "--- 남은 요금 리소스 확인 ---"
echo ""
echo "  탄력적 IP (있으면 시간당 \$0.005)"
aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].[PublicIp,AssociationId]' --output table 2>/dev/null

echo "  로드밸런서"
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output table 2>/dev/null

echo "  EBS 볼륨 (available 상태면 미사용인데 요금은 나갑니다)"
aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size]' --output table 2>/dev/null

echo ""
echo "  ✅ 삭제 완료. 위 목록이 비어 있으면 요금이 멈춥니다."
echo ""
echo "  하루 뒤 Cost Explorer 로 확인하세요:"
echo "    aws ce get-cost-and-usage --time-period Start=\$(date -u +%Y-%m-%d),End=\$(date -u -d '+1 day' +%Y-%m-%d) \\"
echo "      --granularity DAILY --metrics UnblendedCost"
echo ""
