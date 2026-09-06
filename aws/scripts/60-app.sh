#!/bin/bash
# ===========================================================================
# [6/9] 앱 배포 — 🔴 로컬과 완전히 같은 차트
#
#   로컬  helm ... -f charts/reverdi/values-vagrant.yaml
#   AWS   helm ... -f charts/reverdi/values-aws.yaml
#
# templates/ 12개는 한 줄도 안 바뀐다. 값 파일만 바뀐다.
# 이게 로컬에서 검증한 것이 AWS 로 이어지는 지점이다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
REGION="ap-northeast-2"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="reverdi-uploads-${ACCOUNT}"

echo ""
echo "==========================================================="
echo " [6/9] 앱 배포"
echo "==========================================================="

# <> 가 남아 있으면 55 번을 안 돌린 것이다
if grep -q "<AWS_ACCOUNT_ID>" charts/reverdi/values-aws.yaml; then
  echo "  🔴 values-aws.yaml 에 <> 가 남아 있습니다."
  echo "     bash aws/scripts/55-fill-values.sh 를 먼저 실행하세요."
  exit 1
fi

echo "--- S3 버킷 ---"
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || {
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  # 🔴 퍼블릭 액세스 전면 차단 (보안 요청 4번)
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}
echo "  OK   $BUCKET (퍼블릭 차단 · 암호화)"

echo ""
echo "--- 차트 검증 ---"
helm lint charts/reverdi
helm template reverdi charts/reverdi -f charts/reverdi/values-aws.yaml > /dev/null
echo "  통과"

echo ""
echo "--- 설치 ---"
echo "  ① migrate-job (pre-install 훅) 이 alembic 을 먼저 실행"
echo "  ② 웹 파드 3개 — AZ 당 하나씩 (topologySpread)"
echo "  ③ ALB 생성 (2~4분 더)"
echo ""

# 🔴 secretScope.perWorkload=true — 백엔드 보안 4번
#    50-secrets.sh 가 reverdi-db-secret 을 이미 만들었다.
helm upgrade --install reverdi charts/reverdi -n reverdi \
  -f charts/reverdi/values-aws.yaml \
  --set secretScope.perWorkload=true \
  --timeout 15m

echo ""
kubectl get pod -n reverdi -o wide

echo ""
echo "--- ALB 주소 (2~4분 대기) ---"
HOST=""
for i in $(seq 1 40); do
  HOST=$(kubectl get ingress -n reverdi -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [ -n "$HOST" ] && { echo "  $HOST"; break; }
  sleep 15
done

if [ -n "$HOST" ]; then
  echo ""
  echo "--- 응답 확인 ---"
  for i in $(seq 1 20); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://${HOST}/health" || echo 000)
    [ "$CODE" = "200" ] && { echo "  /health → 200"; break; }
    echo "  대기 중... ($CODE)"
    sleep 15
  done
  echo ""
  curl -s "http://${HOST}/ready" | python3 -m json.tool || true
  echo ""
  echo "  ✅ 앱 배포 완료 — http://${HOST}"
  echo ""
  echo "  🔴 storage.mode 가 s3 인지 확인하세요. local 이면 IRSA 가 안 붙은 겁니다."
else
  echo "  ⚠️ ALB 주소가 아직 없습니다: kubectl get ingress -n reverdi"
fi
