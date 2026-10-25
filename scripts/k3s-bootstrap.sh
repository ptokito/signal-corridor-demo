#!/bin/bash
# k3s node bootstrap. Rendered by Terraform templatefile().
# Installs single-node Kubernetes (k3s), Helm, and the AWS CLI, then clones the repo.
# The New Relic Kubernetes integration and the apps are installed by hand afterwards
# (see docs/RUNBOOK.md) so each step can be shown and explained.
# Progress log: /var/log/corridor-bootstrap.log
set -euxo pipefail
exec > /var/log/corridor-bootstrap.log 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl jq
snap install aws-cli --classic

# k3s: lightweight, CNCF-conformant Kubernetes. Traefik ingress is disabled because
# NGINX on the host tier is our front door.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -

# Helm, the Kubernetes package manager, used to install the New Relic bundle chart.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' > /etc/profile.d/k3s.sh
echo 'export AWS_REGION=${region}' >> /etc/profile.d/k3s.sh

git clone "${repo_url}" /opt/corridor
chmod -R a+rX /opt/corridor

echo "BOOTSTRAP COMPLETE"
