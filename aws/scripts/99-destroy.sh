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

# ===========================================================================
# 🔴 순서를 바꿨다 (2026-09-09 실패 → 수정)
#
#   전에는 helm uninstall 을 맨 먼저 했다. 그러면 ALB 컨트롤러가 사라지는데,
#   컨트롤러가 만든 로드밸런서와 보안그룹을 정리해줄 주체가 없어진다.
#
#   실제로 클러스터 삭제가 세 번 실패했다.
#     1차  클래식 LB "a528a611..." 가 서브넷을 잡고 있어 실패
#     2차  보안그룹 4개(k8s-elb-* · k8s-monitori-*)가 VPC 삭제를 막아 실패
#     3차  둘 다 손으로 지운 뒤 성공
#
#   Grafana 를 LoadBalancer 로 노출했을 때 만들어진 것들이었다.
#
#   그래서 순서를 바꾼다:
#     ① Service·Ingress 를 먼저 지운다   ← 컨트롤러가 살아 있을 때 LB 정리
#     ② 정리될 때까지 기다린다
#     ③ 그다음 helm uninstall
# ===========================================================================

echo ""
echo "--- [1/5] 🔴 Service · Ingress 먼저 (컨트롤러가 살아 있을 때) ---"

# LoadBalancer 타입 Service 를 ClusterIP 로 되돌린다 → LB 가 지워진다
for svc in $(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  ns="${svc%%/*}"; n="${svc##*/}"
  kubectl patch svc "$n" -n "$ns" -p '{"spec":{"type":"ClusterIP"}}' >/dev/null 2>&1 \
    && echo "  OK   $svc (LoadBalancer → ClusterIP)"
done

kubectl delete ingress --all -A --timeout=180s 2>/dev/null || true

echo ""
echo "  로드밸런서 정리 대기 (2~3분)..."
for i in $(seq 1 24); do
  N1=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)
  N2=$(aws elb   describe-load-balancers --region "$REGION" --query 'length(LoadBalancerDescriptions)' --output text 2>/dev/null || echo 0)
  [ "$N1" = "0" ] && [ "$N2" = "0" ] && { echo "  OK   전부 삭제됨"; break; }
  printf "    남은 LB: v2=%s classic=%s\n" "$N1" "$N2"
  sleep 15
done

echo ""
echo "--- [2/5] Helm 릴리스 ---"
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
echo "--- [3/5] RDS 스택 ---"
if aws cloudformation describe-stacks --stack-name reverdi-rds --region "$REGION" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name reverdi-rds --region "$REGION"
  echo "  삭제 요청 — 완료까지 10~15분"
  aws cloudformation wait stack-delete-complete --stack-name reverdi-rds --region "$REGION" && echo "  OK   RDS"
else
  echo "  -    RDS 스택 없음"
fi

echo ""
echo "--- [4/5] EKS 클러스터 (15~20분) ---"
# --force 를 붙인다. 남은 리소스가 있어도 최대한 진행한다.
# 실패해도 아래 보안그룹 정리 후 재시도하므로 || true 로 넘긴다.
eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait --force \
  && echo "  OK   클러스터" \
  || echo "  ⚠️  일부 실패 — 아래에서 보안그룹 정리 후 재시도합니다"

# ---------------------------------------------------------------------------
# 🔴 컨트롤러가 남긴 보안그룹 정리
#    ①에서 LB 를 지워도 보안그룹은 남을 수 있다. VPC 삭제를 막는다.
#      k8s-elb-*  ·  k8s-<네임스페이스>-*  ·  k8s-traffic-*
# ---------------------------------------------------------------------------
echo ""
echo "--- 남은 보안그룹 확인 ---"
VPC=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=eksctl-${CLUSTER}-cluster/VPC" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  for sg in $(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" >/dev/null 2>&1 \
      && echo "  OK   $sg 삭제" || echo "  -    $sg (의존성 있음 — 나중에 다시)"
  done

  # 보안그룹을 지웠으니 스택 삭제를 한 번 더
  if aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER}-cluster" \
       --region "$REGION" >/dev/null 2>&1; then
    echo "  VPC 스택 재삭제..."
    aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER}-cluster" --region "$REGION"
    aws cloudformation wait stack-delete-complete \
      --stack-name "eksctl-${CLUSTER}-cluster" --region "$REGION" 2>/dev/null \
      && echo "  OK   VPC 삭제 완료"
  fi
else
  echo "  OK   VPC 없음"
fi

echo ""
echo "--- [5/5] 남은 것 ---"
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
