#!/bin/bash
# ===========================================================================
# [보조] Jenkins 빌드 에이전트에 ECR push 권한 주기
#
# 🔴 왜 따로 만드나
#    cluster.yaml 의 reverdi-web · reverdi-batch 는 reverdi 네임스페이스에 있다.
#    Jenkins 빌드 파드는 infra 네임스페이스에서 뜨므로 그 SA 를 쓸 수 없다.
#    ("serviceaccount not found" 로 파드가 안 뜬다)
#
#    그래서 infra 네임스페이스에 ECR 전용 SA 를 하나 더 만든다.
#
# 🔴 권한을 좁게 준다
#    AmazonEC2ContainerRegistryPowerUser 는 push·pull 은 되지만
#    저장소 삭제는 안 된다. 빌드에는 그걸로 충분하다.
# ===========================================================================
set -euo pipefail
REGION="ap-northeast-2"
CLUSTER="reverdi"

echo ""
echo "==========================================================="
echo " Jenkins 빌드 에이전트 IRSA (ECR push)"
echo "==========================================================="

eksctl create iamserviceaccount \
  --cluster "$CLUSTER" --region "$REGION" \
  --namespace infra --name jenkins-ecr \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser \
  --approve --override-existing-serviceaccounts

echo ""
kubectl get sa jenkins-ecr -n infra -o jsonpath='{.metadata.annotations}' ; echo

echo ""
echo "  ✅ 준비 완료"
echo ""
echo "  Jenkinsfile 의 BUILD_POD 가 이 SA 를 쓴다:"
echo "    serviceAccountName: jenkins-ecr"
