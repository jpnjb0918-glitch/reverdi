#!/bin/bash
# ===========================================================================
# [5/8] Secret — 🔴 순서가 중요하다
#
# 로컬에서는 CNPG 가 비밀번호를 만들어 우리가 꺼내 썼다(문제 12).
# AWS 에서는 우리가 만들어 RDS 에 넣었으므로 그 값을 그대로 쓴다.
#
# 백엔드 보안 4번에 따라 Secret 을 둘로 나눈다.
#   reverdi-secret      웹 — 계정 · SESSION_SECRET · DB
#   reverdi-db-secret   배치 — DB 만
# ===========================================================================
set -euo pipefail
NS=reverdi
[ -f /tmp/reverdi-rds.env ] || { echo "🔴 /tmp/reverdi-rds.env 가 없습니다. 40-rds.sh 를 먼저 실행하세요."; exit 1; }
source /tmp/reverdi-rds.env

echo ""
echo "==========================================================="
echo " [5/8] Secret"
echo "==========================================================="

# 🔴 sslmode=require 를 URL 에 붙이지 않는다.
#    앱이 DATABASE_SSL_MODE 환경변수로 처리한다(values-aws.yaml).
#    URL 과 환경변수 양쪽에 있으면 어느 쪽이 이기는지 헷갈린다.
DB_URL="postgresql+asyncpg://reverdi:${DB_PASSWORD}@${DB_WRITER}:5432/reverdi"
DB_RO_URL="postgresql+asyncpg://reverdi:${DB_PASSWORD}@${DB_READER}:5432/reverdi"

ADMIN_PW=$(openssl rand -hex 12)
CLIENT_PW=$(openssl rand -hex 12)

kubectl delete secret reverdi-secret -n $NS >/dev/null 2>&1 || true
kubectl create secret generic reverdi-secret -n $NS \
  --from-literal=DATABASE_URL="$DB_URL" \
  --from-literal=DATABASE_RO_URL="$DB_RO_URL" \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ADMIN_USERNAME=admin \
  --from-literal=ADMIN_PASSWORD="$ADMIN_PW" \
  --from-literal=CLIENT_USERNAME=client \
  --from-literal=CLIENT_PASSWORD="$CLIENT_PW"
echo "  OK   reverdi-secret (웹)"

# 배치용 — DB 만. 크롤러가 뚫려도 관리자 비밀번호가 안 넘어간다.
kubectl delete secret reverdi-db-secret -n $NS >/dev/null 2>&1 || true
kubectl create secret generic reverdi-db-secret -n $NS \
  --from-literal=DATABASE_URL="$DB_URL" \
  --from-literal=DATABASE_RO_URL="$DB_RO_URL"
echo "  OK   reverdi-db-secret (배치)"

echo ""
echo "  ✅ Secret 준비 완료"
echo ""
echo "  로그인 계정 — 지금 메모하세요"
echo "    admin  / $ADMIN_PW"
echo "    client / $CLIENT_PW"
echo ""
echo "  나중에 다시 보려면:"
echo "    kubectl get secret reverdi-secret -n reverdi -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d"
