#!/bin/bash
# ===========================================================================
# [9/9] Jenkins — 🔴 기존 helm-values/jenkins.yaml 을 그대로 쓴다
#
# 빌드 에이전트 파드 정의는 Jenkinsfile 안에 인라인으로 있다(문제 13).
# 그래서 값 파일에 podTemplates 가 없어도 동작한다.
#
# ⚠️ Jenkinsfile 의 nodeSelector 가 workload=batch 다.
#    AWS 노드그룹 이름은 다르지만 라벨은 같으므로 그대로 뜬다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

echo ""
echo "==========================================================="
echo " [9/9] Jenkins (5~10분)"
echo "==========================================================="

helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install jenkins jenkins/jenkins -n infra \
  -f helm-values/jenkins.yaml \
  -f helm-values/aws/jenkins.yaml \
  --timeout 15m

kubectl rollout status statefulset/jenkins -n infra --timeout=900s || true

echo ""
kubectl get pod -n infra -o wide | grep jenkins
echo ""
echo "  ✅ Jenkins 준비 완료"
echo ""
echo "  접속:  kubectl port-forward -n infra svc/jenkins 8080:8080"
echo "         http://localhost:8080"
echo "  비번:  kubectl exec -n infra svc/jenkins -c jenkins -- \\"
echo "           cat /run/secrets/additional/chart-admin-password"
echo ""
echo "  🔴 GitHub 토큰은 직접 등록해야 합니다 (ID: gitops-push-token)"
echo "     Jenkinsfile 의 REGISTRY 를 ECR 주소로 바꿔야 빌드가 됩니다."
