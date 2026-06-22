#!/usr/bin/env bash
# Brings GKE back up for testing. Mirrors the state after initial deployment.
set -euo pipefail

CLUSTER=rag-cluster
ZONE=us-central1-a
PROJECT=aham-store
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Fetching static IP from Terraform..."
STATIC_IP=$(cd "$REPO_ROOT/terraform" && terraform output -raw api_static_ip)
echo "    Static IP: $STATIC_IP"

echo "==> Patching k8s/service.yaml with static IP..."
sed "s/STATIC_IP_PLACEHOLDER/$STATIC_IP/" "$REPO_ROOT/k8s/service.yaml" > /tmp/service-patched.yaml

echo "==> Scaling node pool to 1..."
gcloud container clusters resize "$CLUSTER" \
  --node-pool=primary \
  --num-nodes=1 \
  --zone="$ZONE" \
  --project="$PROJECT" \
  --quiet

echo "==> Waiting for node to be Ready (may take ~2 min)..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Applying Kubernetes manifests..."
kubectl apply -f "$REPO_ROOT/k8s/deployment.yaml"
kubectl apply -f /tmp/service-patched.yaml
rm /tmp/service-patched.yaml

echo "==> Waiting for rollout..."
kubectl rollout status deployment/rag-api --timeout=180s

echo "==> Updating vite-api-url secret with static IP..."
echo -n "http://$STATIC_IP" | \
  gcloud secrets versions add vite-api-url \
    --data-file=- \
    --project="$PROJECT"

echo ""
echo "Done. GKE is up."
echo "  API endpoint: http://$STATIC_IP/api/query"
echo "  Frontend:     https://storage.googleapis.com/aham-store-frontend/index.html"
echo ""
echo "If this is the first time using this static IP, rebuild the frontend:"
echo "  gcloud builds triggers run frontend-deploy --branch=main --project=$PROJECT"
