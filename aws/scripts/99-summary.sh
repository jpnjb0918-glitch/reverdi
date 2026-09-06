#!/bin/bash
# ===========================================================================
# 접속 정보 — 로컬의 99-summary.sh 와 같은 역할
# ===========================================================================
set -uo pipefail
REGION="ap-northeast-2"

HOST=$(kubectl get ingress -n reverdi -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
APP_PW=$(kubectl get secret reverdi-secret -n reverdi -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
CLI_PW=$(kubectl get secret reverdi-secret -n reverdi -o jsonpath='{.data.CLIENT_PASSWORD}' 2>/dev/null | base64 -d)
ARG_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
GRA_PW=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

cat <<BANNER

███████████████████████████████████████████████████████████████
   AWS 배포 완료
███████████████████████████████████████████████████████████████

BANNER

echo "───────────────────────────────────────────────────────────"
echo " 접속"
echo "───────────────────────────────────────────────────────────"
echo ""
echo "  웹 앱   http://${HOST:-(ALB 대기 중)}"
echo "          admin  / ${APP_PW:-확인필요}"
echo "          client / ${CLI_PW:-확인필요}"
echo ""
echo "  🔴 Argo CD · Grafana · Jenkins 는 ALB 를 안 만든다."
echo "     포트포워딩으로 본다 — 인터넷에 노출하지 않는다."
echo ""
echo "  Argo CD   kubectl port-forward -n argocd svc/argocd-server 8080:80"
echo "            http://localhost:8080   admin / ${ARG_PW:-확인필요}"
echo ""
echo "  Grafana   kubectl port-forward -n monitoring svc/kps-grafana 3000:80"
echo "            http://localhost:3000   admin / ${GRA_PW:-확인필요}"
echo ""

cat <<'HOWTO'
───────────────────────────────────────────────────────────
 비밀번호 다시 확인
───────────────────────────────────────────────────────────

  kubectl get secret reverdi-secret -n reverdi \
    -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d ; echo

  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d ; echo

  kubectl get secret grafana-admin -n monitoring \
    -o jsonpath='{.data.admin-password}' | base64 -d ; echo


───────────────────────────────────────────────────────────
 🔴 비용 — 매일 확인하세요
───────────────────────────────────────────────────────────

  이번 달 지출
    aws ce get-cost-and-usage \
      --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
      --granularity MONTHLY --metrics UnblendedCost \
      --group-by Type=DIMENSION,Key=SERVICE \
      --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`1`].[Keys[0],Metrics.UnblendedCost.Amount]' \
      --output table

  3주 예상 약 $280.

  ⚠️ 시연이 끝나면 반드시:
       bash aws/scripts/99-destroy.sh


───────────────────────────────────────────────────────────
 시연
───────────────────────────────────────────────────────────

  ── RDS 페일오버 ────────────────────────────────────────
  창1)
    while true; do printf '%s  ' "$(date +%H:%M:%S)"; \
      curl -s -o /dev/null -w "%{http_code}\n" -m 3 \
      http://<ALB주소>/; sleep 1; done

  창2)
    aws rds reboot-db-instance --db-instance-identifier reverdi-db \
      --force-failover --region ap-northeast-2

    → 창1 의 200 이 유지되면서 AZ 가 바뀝니다.
      로컬 CloudNativePG 에서 본 것과 같은 동작입니다.

  ── Argo CD self-heal ───────────────────────────────────
  kubectl scale deploy reverdi-web -n reverdi --replicas=1
  kubectl get pod -n reverdi -w

  ── 파드 분산 (AZ 당 하나) ───────────────────────────────
  kubectl get pod -n reverdi -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,AZ:.metadata.labels'
  kubectl get nodes -L topology.kubernetes.io/zone

HOWTO

echo ""
kubectl get pod -A -o wide 2>/dev/null | grep -vE "kube-system|Completed" | head -20
echo ""
