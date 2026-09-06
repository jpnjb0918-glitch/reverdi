#!/bin/bash
# ===========================================================================
# [1/8] EKS 클러스터 — Vagrant 의 vagrant up 에 해당
#
# aws/cluster.yaml 한 파일로 VPC · NAT · 컨트롤 플레인 · 노드그룹 · IRSA 가 생긴다.
# 15~20분. 내부적으로 CloudFormation 스택 여러 개를 만든다.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

echo ""
echo "==========================================================="
echo " [1/8] EKS 클러스터 생성 (15~20분)"
echo "==========================================================="
echo ""
echo "  만들어지는 것"
echo "    VPC 10.0.0.0/16 · 퍼블릭/사설 서브넷 3AZ · NAT Gateway 1개"
echo "    EKS 컨트롤 플레인 (AWS 관리 — 우리 VPC 밖)"
echo "    노드그룹 3종 — web ×3 · batch ×1 · infra ×1"
echo "    OIDC 공급자 + IRSA 역할 4개"
echo ""
echo "  🔴 Vagrant 와 다른 점"
echo "    컨트롤 플레인이 AWS 관리 영역에 있어 우리가 taint 를 걸 필요가 없다."
echo "    로컬에서 node0 에 걸던 CriticalAddonsOnly 가 여기선 불필요하다."
echo ""

eksctl create cluster -f cluster.yaml

echo ""
echo "--- kubeconfig ---"
aws eks update-kubeconfig --region ap-northeast-2 --name reverdi

echo ""
kubectl get nodes -L workload
echo ""
echo "  ✅ 클러스터 준비 완료"
echo ""
echo "  확인: 노드 5대 · workload 라벨 web(3) batch(1) infra(1)"
