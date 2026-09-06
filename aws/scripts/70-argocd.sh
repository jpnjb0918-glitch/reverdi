#!/bin/bash
# ===========================================================================
# [7/9] Argo CD — 🔴 기존 helm-values/argocd.yaml 을 그대로 쓴다
#
#   -f helm-values/argocd.yaml          로컬에서 검증한 설정
#   -f helm-values/aws/argocd.yaml      AWS 에서만 다른 부분
#
# Helm 은 -f 를 여러 번 받으면 뒤에 온 것이 이긴다.
# toleration · nodeSelector · 자원 요청은 로컬에서 쓰던 그대로 유지된다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."      # 저장소 루트

echo ""
echo "==========================================================="
echo " [7/9] Argo CD"
echo "==========================================================="
echo ""
echo "  기존 값 파일 + AWS 오버레이"
echo "    helm-values/argocd.yaml       (로컬에서 검증한 것)"
echo "    helm-values/aws/argocd.yaml   (NodePort → ClusterIP)"
echo ""

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd -n argocd \
  -f helm-values/argocd.yaml \
  -f helm-values/aws/argocd.yaml \
  --timeout 10m

kubectl wait --for=condition=available --timeout=300s deploy/argocd-server -n argocd

echo ""
echo "  ✅ Argo CD 준비 완료"
echo ""
echo "  접속:  kubectl port-forward -n argocd svc/argocd-server 8080:80"
echo "         http://localhost:8080"
echo "  비번:  kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "           -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  ⚠️ Application 등록은 아직 하지 않았습니다."
echo "     values-aws.yaml 의 <> 자리를 채워 git 에 push 한 뒤,"
echo "     argocd/application.yaml 의 valueFiles 를 values-aws.yaml 로 바꿔 적용하세요."
