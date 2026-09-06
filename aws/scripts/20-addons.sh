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
