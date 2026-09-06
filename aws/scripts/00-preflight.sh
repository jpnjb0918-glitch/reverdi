#!/bin/bash
# ===========================================================================
# [0/8] 사전 확인 — 시작하기 전에 빠진 게 없는지 본다
#
# 여기서 걸러야 15분 뒤에 "권한이 없다"로 실패하는 것을 막는다.
# ===========================================================================
set -euo pipefail
REGION="${AWS_REGION:-ap-northeast-2}"
CLUSTER="reverdi"

echo ""
echo "==========================================================="
echo " [0/8] 사전 확인"
echo "==========================================================="

echo "--- 도구 ---"
FAIL=0
for c in aws eksctl kubectl helm; do
  if command -v "$c" >/dev/null 2>&1; then
    printf "  OK   %-8s %s\n" "$c" "$($c version 2>&1 | head -1 | cut -c1-60)"
  else
    printf "  🔴 %-8s 없음\n" "$c"; FAIL=1
  fi
done
[ "$FAIL" = 1 ] && { echo ""; echo "  설치가 필요합니다. README 1장 참조."; exit 1; }

echo ""
echo "--- AWS 자격증명 ---"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "  계정 $ACCOUNT"
echo "  주체 $ARN"
echo "  리전 $REGION"

echo ""
echo "--- 이미 있는 리소스 (중복 생성 방지) ---"
if eksctl get cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  echo "  ⚠️ 클러스터 '$CLUSTER' 가 이미 있습니다."
  echo "     이어서 진행하려면 10-cluster.sh 를 건너뛰세요."
else
  echo "  OK   클러스터 없음 — 새로 만들 수 있습니다"
fi

if aws cloudformation describe-stacks --stack-name reverdi-rds --region "$REGION" >/dev/null 2>&1; then
  echo "  ⚠️ RDS 스택이 이미 있습니다."
else
  echo "  OK   RDS 스택 없음"
fi

echo ""
echo "--- 서비스 할당량 ---"
EIP=$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text)
echo "  탄력적 IP 사용 중: $EIP (기본 한도 5)"
[ "$EIP" -ge 4 ] && echo "  ⚠️ NAT Gateway 가 하나 더 필요합니다. 여유를 확인하세요."

echo ""
echo "🔴 비용 안내"
echo "   이 시점부터 요금이 발생합니다."
echo "   3주 기준 약 \$280 예상 (EKS \$50 · NAT \$30 · EC2 \$92 · RDS \$62 · 기타)"
echo "   시연이 끝나면 반드시 99-destroy.sh 를 실행하세요."
echo ""
