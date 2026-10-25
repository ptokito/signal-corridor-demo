#!/bin/bash
# =============================================================================
# AWS build: deploy the corridor services to the k3s node.
# =============================================================================
# Run on the k3s node as root:
#   bash /opt/corridor/scripts/deploy-apps.sh <host_private_ip> <github_user>
# <host_private_ip> is the "host_private_ip" output from terraform.
# <github_user> is whose GitHub Container Registry (GHCR) holds the images.
#
# Steps:
#   1. Create the "corridor" namespace
#   2. Copy the 3 secrets from SSM Parameter Store into a Kubernetes Secret
#   3. Save the host tier's IP in a ConfigMap (PostgreSQL, Redis and NGINX live there)
#   4. Fill in the image names and apply k8s/apps.yaml
#   5. Wait for every Deployment to finish rolling out
# =============================================================================
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
HOST_IP="${1:?usage: deploy-apps.sh <host_private_ip> <github_user>}"
OWNER="${2:?usage: deploy-apps.sh <host_private_ip> <github_user>}"
REGION="${AWS_REGION:-us-east-1}"
REPO=/opt/corridor

param() { aws ssm get-parameter --region "$REGION" --with-decryption --name "$1" --query Parameter.Value --output text; }

# 1. namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: corridor
EOF

# 2. secrets: piped straight from SSM into Kubernetes, never written to disk
kubectl -n corridor create secret generic corridor-secrets \
  --from-literal=nr_license_key="$(param /signal-corridor/newrelic-license-key)" \
  --from-literal=pg_password="$(param /signal-corridor/postgres-password)" \
  --from-literal=redis_password="$(param /signal-corridor/redis-password)" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. config
kubectl -n corridor create configmap corridor-config \
  --from-literal=host_ip="$HOST_IP" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. images come from ghcr.io/<owner>; always pull so a new push is picked up on restart
sed -e "s|IMAGE_PREFIX|ghcr.io/$OWNER|g" -e "s|PULL_POLICY|Always|g" \
  "$REPO/k8s/apps.yaml" | kubectl apply -f -

# 5. wait
for d in signal-api timing-engine crew-dispatch corridor-simulator; do
  kubectl -n corridor rollout status "deploy/$d" --timeout=240s
done
kubectl -n corridor get pods -o wide
