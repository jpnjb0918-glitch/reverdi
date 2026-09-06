#!/bin/bash
# ===========================================================================
# [8/9] 모니터링 — 🔴 기존 helm-values 를 그대로 쓴다
#
#   -f helm-values/kube-prometheus-stack.yaml      로컬 검증본
#   -f helm-values/aws/kube-prometheus-stack.yaml  AWS 오버레이
#
# 로컬에서 고친 서브차트 키(prometheus-node-exporter)가 그대로 따라온다.
# 문제 19 를 여기서 다시 겪지 않는다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

echo ""
echo "==========================================================="
echo " [8/9] 모니터링"
echo "==========================================================="

# 🔴 Grafana 비밀번호는 값 파일에 적지 않는다. Secret 을 미리 만든다.
#    (기존 kube-prometheus-stack.yaml 이 grafana-admin 을 참조한다)
GPW=$(openssl rand -hex 12)
kubectl delete secret grafana-admin -n monitoring >/dev/null 2>&1 || true
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password="$GPW" >/dev/null
echo "  OK   grafana-admin Secret"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
  -f helm-values/kube-prometheus-stack.yaml \
  -f helm-values/aws/kube-prometheus-stack.yaml \
  --timeout 15m

echo ""
echo "--- 앱 지표 수집 (ServiceMonitor) ---"
kubectl apply -f - <<'YAML' >/dev/null
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: reverdi-web
  namespace: monitoring
  labels: { release: kps }
spec:
  namespaceSelector: { matchNames: [reverdi] }
  selector:
    matchLabels:
      app.kubernetes.io/name: reverdi
      app.kubernetes.io/component: web
  endpoints:
    - { port: http, path: /metrics, interval: 30s }
YAML
echo "  OK   ServiceMonitor"

echo ""
kubectl get pod -n monitoring -o wide | head -10
echo ""
echo "  node-exporter 는 노드 수만큼 떠야 합니다:"
kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter --no-headers | wc -l
echo ""
echo "  ✅ 모니터링 준비 완료"
echo ""
echo "  접속:  kubectl port-forward -n monitoring svc/kps-grafana 3000:80"
echo "         http://localhost:3000   admin / $GPW"
