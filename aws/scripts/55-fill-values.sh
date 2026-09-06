#!/bin/bash
# ===========================================================================
# [5.5/9] values-aws.yaml 의 <> 자리 채우기
#
# 🔴 기존 파일을 그대로 쓰되, 계정 ID 처럼 사람마다 다른 값만 바꾼다.
#    --set 으로 넘길 수도 있지만, 파일에 박아두면
#      · Argo CD 가 git 에서 읽을 때도 같은 값을 본다
#      · 무엇이 들어갔는지 git diff 로 보인다
#    GitOps 에서는 파일에 있는 것이 정답이다.
#
# 🔴 계정 ID 는 비밀이 아니다. ARN 어디에나 들어간다.
#    비밀번호·토큰은 여기 넣지 않는다 — 그건 Secret 이다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
REGION="ap-northeast-2"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
BUCKET="reverdi-uploads-${ACCOUNT}"
F="charts/reverdi/values-aws.yaml"

echo ""
echo "==========================================================="
echo " [5.5/9] values-aws.yaml 채우기"
echo "==========================================================="
echo "  계정 $ACCOUNT"
echo "  ECR  $ECR"
echo "  버킷 $BUCKET"

cp "$F" "${F}.bak"

python3 - "$F" "$ACCOUNT" "$BUCKET" <<'PY'
import sys, pathlib, re
f, account, bucket = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(f)
s = p.read_text(encoding='utf-8')

s = s.replace('<AWS_ACCOUNT_ID>', account)
s = s.replace('<S3_BUCKET_NAME>', bucket)

# 🔴 도메인이 아직 없다 — ACM 인증서 자리를 비운다.
#    빈 문자열이면 ALB 가 HTTP 로만 뜬다.
#    도메인이 생기면 인증서를 만들고 이 줄에 ARN 을 넣은 뒤 helm upgrade.
s = re.sub(r'(\n\s*certificateArn:\s*)".*?"',
           r'\1""    # 도메인 생기면 ACM ARN 을 넣는다', s)

p.write_text(s, encoding='utf-8')
PY

echo ""
echo "--- 결과 ---"
grep -nE "repository:|certificateArn:|S3_BUCKET:" "$F"

echo ""
python3 -c "
import yaml
d = yaml.safe_load(open('$F', encoding='utf-8'))
assert '<' not in str(d), '아직 <> 가 남아 있습니다'
print('  OK   파싱 통과 · <> 자리 없음')
print('  image      ', d['image']['repository'])
print('  crawler    ', d['crawlerImage']['repository'])
print('  S3_BUCKET  ', d['config']['S3_BUCKET'])
print('  cert       ', repr(d['ingress']['certificateArn']))
"

echo ""
echo "  ✅ 완료 — 원본은 ${F}.bak 에 있습니다"
echo ""
echo "  🔴 git 에 커밋하세요. Argo CD 가 이 파일을 읽습니다."
echo "     git add $F && git commit -m 'chore: AWS 계정 값 반영' && git push"
