#!/bin/bash
# ===========================================================================
# [4/8] RDS — CloudNativePG 를 대체한다
#
# 15~25분 걸린다. Multi-AZ 라 스탠바이까지 만든 뒤 읽기 복제본을 붙인다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
REGION="ap-northeast-2"
CLUSTER="reverdi"
STACK="reverdi-rds"

echo ""
echo "==========================================================="
echo " [4/8] RDS PostgreSQL (15~25분)"
echo "==========================================================="

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# 사설 서브넷만 고른다. RDS 를 퍼블릭에 두면 안 된다.
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*Private*" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

# 노드 보안그룹 — RDS 가 이걸 소스로 허용한다
NODE_SG=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

echo "  VPC     $VPC_ID"
echo "  서브넷  $SUBNETS"
echo "  노드 SG $NODE_SG"

# 🔴 비밀번호는 여기서 만들고 파일에 남기지 않는다.
DBPW=$(openssl rand -hex 16)

echo ""
echo "--- 스택 배포 ---"
aws cloudformation deploy \
  --template-file rds.yaml \
  --stack-name "$STACK" \
  --region "$REGION" \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    PrivateSubnetIds="$SUBNETS" \
    NodeSecurityGroupId="$NODE_SG" \
    DBPassword="$DBPW" \
  --no-fail-on-empty-changeset

WRITER=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`WriterEndpoint`].OutputValue' --output text)
READER=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ReaderEndpoint`].OutputValue' --output text)

echo ""
echo "  쓰기 $WRITER"
echo "  읽기 $READER"

# 다음 스크립트가 쓰도록 임시 저장 (권한 600)
umask 077
cat > /tmp/reverdi-rds.env <<VARS
DB_WRITER=$WRITER
DB_READER=$READER
DB_PASSWORD=$DBPW
VARS

echo ""
echo "  ✅ RDS 준비 완료"
echo "  🔴 접속 정보는 /tmp/reverdi-rds.env 에 있습니다 (50-secrets.sh 가 씁니다)"
