#!/bin/bash
# ===========================================================================
# [2/8] 애드온 — ALB 컨트롤러
#
# 🔴 이게 없으면 Ingress 를 만들어도 ALB 가 안 생긴다.
#    로컬에서는 NodePort 로 직접 들어왔지만, AWS 에서는 ALB 가 앞에 선다.
# ===========================================================================
set -euo pipefail
REGION="ap-northeast-2"
CLUSTER="reverdi"

echo ""
echo "==========================================================="
echo " [2/8] ALB 컨트롤러"
echo "==========================================================="

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "  VPC: $VPC_ID"

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# serviceAccount.create=false — cluster.yaml 의 IRSA 가 이미 만들었다.
# 여기서 또 만들면 IAM 역할 주석이 없는 SA 가 생겨 권한 오류가 난다.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait --timeout 10m

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s

echo ""
echo "--- 네임스페이스 ---"
for ns in reverdi infra argocd monitoring; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
done
kubectl get ns | grep -E "reverdi|infra|argocd|monitoring"

echo ""
echo "--- 🔴 EBS CSI 드라이버 IRSA 연결 ---"
# 애드온과 IRSA 는 별개다. cluster.yaml 이 만든 역할을 여기서 붙인다.
# 이게 없으면 PVC 가 전부 Pending 이 되고, Prometheus·Grafana·Jenkins 가 안 뜬다.
# 증상이 헷갈린다 — Helm 은 릴리스가 설치되면 "성공"이라 파드가 뜨는지는 안 본다.
EBS_ROLE=$(eksctl get iamserviceaccount --cluster "$CLUSTER" --region "$REGION" -o json 2>/dev/null \
  | python3 -c "import json,sys; print([x['status']['roleARN'] for x in json.load(sys.stdin) if x['metadata']['name']=='ebs-csi-controller-sa'][0])" 2>/dev/null || echo "")

if [ -n "$EBS_ROLE" ]; then
  echo "    역할: $EBS_ROLE"
  # 애드온이 없으면 만들고, 있으면 역할만 갱신한다
  if aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver \
       --region "$REGION" >/dev/null 2>&1; then
    aws eks update-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver \
      --service-account-role-arn "$EBS_ROLE" --region "$REGION" \
      --resolve-conflicts OVERWRITE >/dev/null
    echo "    애드온 갱신"
  else
    eksctl create addon --cluster "$CLUSTER" --region "$REGION" \
      --name aws-ebs-csi-driver --service-account-role-arn "$EBS_ROLE" --force
    echo "    애드온 생성"
  fi
  echo "    컨트롤러 기동 대기..."
  kubectl -n kube-system rollout status deploy/ebs-csi-controller --timeout=300s 2>/dev/null || true
else
  echo "    🔴 ebs-csi-controller-sa 역할을 못 찾았습니다."
  echo "       eksctl get iamserviceaccount --cluster $CLUSTER --region $REGION"
fi

echo ""
echo "--- 🔴 metrics-server ---"
# EKS 는 metrics-server 가 기본 설치가 아니다. 로컬 k3s 에는 내장이었다.
# 이게 없으면 HPA 가 cpu: <unknown> 이 되고 Argo CD 가 Degraded 로 본다.
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s || true

echo ""
echo "--- StorageClass ---"
# gp2 가 기본으로 잡혀 있으면 gp3 로 바꾼다. 같은 성능에 더 싸다.
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
YAML
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
kubectl get sc

echo ""
echo "  ✅ 애드온 준비 완료"
