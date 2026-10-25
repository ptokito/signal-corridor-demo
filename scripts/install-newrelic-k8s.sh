#!/bin/bash
# =============================================================================
# AWS build: install the New Relic Kubernetes integration on the k3s node.
# =============================================================================
# Run on the k3s node as root:  bash /opt/corridor/scripts/install-newrelic-k8s.sh
#
# The license key is read from SSM Parameter Store (using the instance's IAM role),
# so it never appears in a file, in shell history, or in git.
#
# The nri-bundle chart installs, in the "newrelic" namespace:
#   newrelic-infrastructure  node, pod and container metrics (+ control plane on k3s)
#   kube-state-metrics       desired vs actual state of Deployments, pods, nodes
#   nri-kube-events          Kubernetes events (Killing, Unhealthy, BackOff, ...)
#   nri-metadata-injection   adds pod/namespace/deployment names to APM agents' data
#   newrelic-logging         Fluent Bit: every container's output to New Relic Logs
# =============================================================================
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
REGION="${AWS_REGION:-us-east-1}"
REPO=/opt/corridor
CLUSTER_NAME="corridor-k3s"

NR_KEY=$(aws ssm get-parameter --region "$REGION" --with-decryption \
  --name /signal-corridor/newrelic-license-key --query Parameter.Value --output text)

# Add New Relic's chart repository and refresh the chart index.
helm repo add newrelic https://helm-charts.newrelic.com
helm repo update

# Install or upgrade (idempotent). Values file has no secrets; key and name are passed here.
helm upgrade --install newrelic-bundle newrelic/nri-bundle \
  --namespace newrelic --create-namespace \
  -f "$REPO/helm/newrelic-values.yaml" \
  --set global.cluster="$CLUSTER_NAME" \
  --set global.licenseKey="$NR_KEY"

# Restart every New Relic pod so all of them pick up the current license key.
kubectl -n newrelic rollout restart deployment,daemonset
kubectl -n newrelic get pods
