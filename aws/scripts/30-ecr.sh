#!/bin/bash
# ===========================================================================
# [3/8] ECR — 로컬의 Docker Registry 를 대체한다
#
# 🔴 로컬과 다른 점
#    registries.yaml 이 필요 없다. ECR 은 HTTPS 라 containerd 가 그냥 믿는다.
#    대신 인증이 필요한데, 노드의 IAM 역할이 자동으로 처리한다.
# ===========================================================================
set -euo pipefail
REGION="ap-northeast-2"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
SRC="https://github.com/epqlffltm/CloudeDX.git"

echo ""
echo "==========================================================="
echo " [3/8] ECR 저장소 + 이미지 빌드"
echo "==========================================================="
echo "  레지스트리: $ECR"

for repo in reverdi-backend reverdi-crawler; do
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$repo" --region "$REGION" \
      --image-scanning-configuration scanOnPush=true >/dev/null
  echo "  OK   $repo"

  # 🔴 수명주기 정책 — 없으면 이미지가 쌓여 요금이 계속 는다.
  #    최근 10개만 남긴다.
  aws ecr put-lifecycle-policy --repository-name "$repo" --region "$REGION" \
    --lifecycle-policy-text '{"rules":[{"rulePriority":1,"description":"keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}' >/dev/null
done

echo ""
echo "--- 로그인 ---"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

echo ""
echo "--- 소스 ---"
rm -rf /tmp/CloudeDX && git clone --depth 1 -q "$SRC" /tmp/CloudeDX
cd /tmp/CloudeDX
TAG=$(git rev-parse --short HEAD)
echo "  커밋 $TAG"

echo ""
echo "--- 빌드 (크롤러 2.7GB — 15~30분) ---"
echo "  🔴 로컬 PC 에서 빌드해 push 한다."
echo "     노드에서 빌드하려면 Jenkins 를 먼저 올려야 하는데, 순서가 꼬인다."
echo ""

# ⚠️ Apple Silicon 등 arm64 맥이면 --platform 이 필수다.
#    노드가 x86_64(t3)라 arm64 이미지는 exec format error 로 죽는다.
PLATFORM="--platform linux/amd64"

docker build $PLATFORM -f dockerfile.backend -t "${ECR}/reverdi-backend:${TAG}" -t "${ECR}/reverdi-backend:latest" .
docker push "${ECR}/reverdi-backend:${TAG}"
docker push "${ECR}/reverdi-backend:latest"
echo "  OK   backend"

docker build $PLATFORM -f dockerfile.crawler -t "${ECR}/reverdi-crawler:${TAG}" -t "${ECR}/reverdi-crawler:latest" .
docker push "${ECR}/reverdi-crawler:${TAG}"
docker push "${ECR}/reverdi-crawler:latest"
echo "  OK   crawler"

echo ""
echo "  ✅ 이미지 준비 완료 — 태그 $TAG"
echo ""
echo "  🔴 values-aws.yaml 에 이 주소를 넣으세요:"
echo "     image.repository       ${ECR}/reverdi-backend"
echo "     crawlerImage.repository ${ECR}/reverdi-crawler"
