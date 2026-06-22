#!/usr/bin/env bash
# Scales down GKE to zero cost. Run this when you're done testing.
# Saves ~$33-38/mo (node ~$15 + LoadBalancer ~$18).
set -euo pipefail

CLUSTER=rag-cluster
ZONE=us-central1-a
PROJECT=aham-store

echo "==> Deleting LoadBalancer service (stops billing for external IP)..."
kubectl delete service rag-api --ignore-not-found

echo "==> Scaling node pool to 0 (stops compute billing)..."
gcloud container clusters resize "$CLUSTER" \
  --node-pool=primary \
  --num-nodes=0 \
  --zone="$ZONE" \
  --project="$PROJECT" \
  --quiet

echo ""
echo "Done. GKE is down."
echo "  Node:         0 (was 1 x e2-small)"
echo "  LoadBalancer: deleted"
echo "  Static IP:    still reserved (costs ~\$0.01/hr while unused)"
echo "  Cluster:      still exists, free (zonal single-cluster free tier)"
echo ""
echo "To bring it back up: ./scripts/kube-up.sh"
