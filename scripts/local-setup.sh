#!/bin/bash
# =============================================================================
# LOCAL MODE: the whole Smart Signal Corridor demo on ONE Ubuntu machine.
# =============================================================================
# Runs the same application code, configs and Kubernetes manifests as the AWS
# build, so anything that works here works there. What it does, in order:
#
#   1. Generates database and cache passwords      (/etc/corridor/secrets.env)
#   2. Installs NGINX, PostgreSQL, Redis, Docker    (Ubuntu packages)
#   3. Configures PostgreSQL and Redis              (password protected, reachable from k3s pods)
#   4. Installs the Operations Portal               (Flask + New Relic Python agent, systemd service)
#   5. Configures NGINX in front of the portal
#   6. Installs the New Relic infrastructure agent  (+ NGINX, PostgreSQL, Redis integrations, log forwarding)
#   7. Installs k3s (Kubernetes) and Helm
#   8. Installs the New Relic Kubernetes integration (nri-bundle Helm chart)
#   9. Builds the 4 container images with Docker and imports them into k3s
#  10. Deploys the services to the "corridor" namespace
#
# Usage, from the repo root (sudo-rs on newer Ubuntu does not support "sudo -E",
# so the key is passed with "env" instead):
#   export NEW_RELIC_LICENSE_KEY='...NRAL'
#   sudo env NEW_RELIC_LICENSE_KEY="$NEW_RELIC_LICENSE_KEY" bash scripts/local-setup.sh
#
# Safe to rerun: every step checks before it changes anything.
# Undo: revert your VM snapshot (cleanest) or run scripts/local-teardown.sh.
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo (see usage at the top of this file)."; exit 1; }
: "${NEW_RELIC_LICENSE_KEY:?NEW_RELIC_LICENSE_KEY is not set. See usage at the top of this file.}"
NR_KEY="$NEW_RELIC_LICENSE_KEY"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NODE_IP=$(hostname -I | awk '{print $1}')   # this machine's main IP; pods use it to reach PostgreSQL and Redis
POD_CIDR="10.42.0.0/16"                     # k3s default pod network
CLUSTER_NAME="corridor-k3s-local"
HOST_NAME="corridor-host-local"
export DEBIAN_FRONTEND=noninteractive
step() { echo; echo "==> $*"; }

step "Repo: $REPO   Machine IP: $NODE_IP"

# ---------------------------------------------------------------- 0. remove the earlier Tidewater test, if present
# The first version of this demo (Tidewater Benefits) used the same ports. Clean it up quietly.
# (systemctl cat, not "list-unit-files | grep -q": with pipefail, grep -q exiting early
#  makes the pipeline fail and the check silently returns false.)
if systemctl cat portal-web.service >/dev/null 2>&1; then
  step "Removing the earlier Tidewater Benefits demo"
  systemctl disable --now portal-web || true
  rm -f /etc/systemd/system/portal-web.service /etc/nginx/sites-enabled/tidewater /etc/nginx/sites-available/tidewater
  systemctl daemon-reload
fi
if command -v kubectl >/dev/null && kubectl get ns benefits >/dev/null 2>&1; then
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl delete ns benefits --wait=true || true
fi

# Port 80 must be free or already NGINX; port 30081 must be free or already our signal-api.
if ss -ltnp 'sport = :80' | grep LISTEN | grep -vq nginx; then
  echo "Port 80 is used by something other than NGINX. Stop it and rerun."; exit 1
fi

# ---------------------------------------------------------------- 1. secrets
step "1/10 Generating local passwords"
install -d -m 700 /etc/corridor
if [ ! -f /etc/corridor/secrets.env ]; then
  echo "PG_PASS=$(openssl rand -hex 12)"    >  /etc/corridor/secrets.env
  echo "REDIS_PASS=$(openssl rand -hex 12)" >> /etc/corridor/secrets.env
  chmod 600 /etc/corridor/secrets.env
fi
. /etc/corridor/secrets.env

# ---------------------------------------------------------------- 2. packages
step "2/10 Installing NGINX, PostgreSQL, Redis, Python, Docker"
apt-get update -y
apt-get install -y nginx postgresql redis-server python3-venv curl gnupg jq openssl
command -v docker >/dev/null || apt-get install -y docker.io

# ---------------------------------------------------------------- 3. PostgreSQL and Redis
step "3/10 Configuring PostgreSQL and Redis"
PG_CONF_DIR=$(ls -d /etc/postgresql/*/main | head -1)
# Listen on all interfaces so pods can connect; pg_hba.conf below limits WHO may connect.
sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$PG_CONF_DIR/postgresql.conf"
grep -q "corridor-demo" "$PG_CONF_DIR/pg_hba.conf" || cat >> "$PG_CONF_DIR/pg_hba.conf" <<EOF
# corridor-demo: the app role may connect from k3s pods and from this machine, with a password
host corridor corridor $POD_CIDR scram-sha-256
host corridor corridor $NODE_IP/32 scram-sha-256
EOF
systemctl restart postgresql
# Two roles: "corridor" owns the app database; "newrelic" is read-only monitoring (pg_monitor).
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='corridor') THEN CREATE ROLE corridor LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='newrelic') THEN CREATE ROLE newrelic LOGIN; END IF;
END \$\$;
ALTER ROLE corridor PASSWORD '$PG_PASS';
ALTER ROLE newrelic PASSWORD '$PG_PASS';
GRANT pg_monitor TO newrelic;
SQL
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='corridor'" | grep -q 1 \
  || sudo -u postgres createdb -O corridor corridor

# Redis: listen on loopback and this machine's IP only, and require a password.
sed -i "s/^bind .*/bind 127.0.0.1 $NODE_IP/" /etc/redis/redis.conf
sed -i "/^requirepass /d" /etc/redis/redis.conf
echo "requirepass $REDIS_PASS" >> /etc/redis/redis.conf
systemctl restart redis-server

# ---------------------------------------------------------------- 4. Operations Portal
step "4/10 Installing the Operations Portal (Flask + New Relic Python agent)"
python3 -m venv /opt/corridor-portal-venv
/opt/corridor-portal-venv/bin/pip install -q -r "$REPO/services/ops-portal/requirements.txt"
# systemd unit: the agent is configured entirely by Environment= lines, and
# newrelic-admin run-program wraps gunicorn so the agent loads first.
cat > /etc/systemd/system/corridor-portal.service <<UNIT
[Unit]
Description=Smart Signal Corridor Operations Portal (Flask) with New Relic Python agent
After=network-online.target

[Service]
WorkingDirectory=$REPO/services/ops-portal
Environment=NEW_RELIC_LICENSE_KEY=$NR_KEY
Environment=NEW_RELIC_APP_NAME=corridor-ops-portal
Environment=NEW_RELIC_LABELS=env:local;tier:host;team:traffic-operations
Environment=NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
Environment=NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
Environment=SIGNAL_API_URL=http://$NODE_IP:30081
ExecStart=/opt/corridor-portal-venv/bin/newrelic-admin run-program /opt/corridor-portal-venv/bin/gunicorn -w 3 -b 127.0.0.1:8000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
chmod 600 /etc/systemd/system/corridor-portal.service   # it contains the license key
systemctl daemon-reload
systemctl enable corridor-portal
systemctl restart corridor-portal

# ---------------------------------------------------------------- 5. NGINX
step "5/10 Configuring NGINX as the reverse proxy"
cp "$REPO/host/nginx-corridor.conf" /etc/nginx/sites-available/corridor
ln -sf /etc/nginx/sites-available/corridor /etc/nginx/sites-enabled/corridor
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ---------------------------------------------------------------- 6. New Relic infrastructure agent
step "6/10 Installing the New Relic infrastructure agent and on-host integrations"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.newrelic.com/infrastructure_agent/gpg/newrelic-infra.gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/newrelic-infra.gpg
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [signed-by=/etc/apt/keyrings/newrelic-infra.gpg] https://download.newrelic.com/infrastructure_agent/linux/apt $CODENAME main" \
  > /etc/apt/sources.list.d/newrelic-infra.list
cat > /etc/newrelic-infra.yml <<CFG
license_key: $NR_KEY
display_name: $HOST_NAME
custom_attributes:
  environment: local
  tier: host
  project: smart-signal-corridor
CFG
chmod 600 /etc/newrelic-infra.yml
apt-get update -y
apt-get install -y newrelic-infra nri-nginx nri-postgresql nri-redis
rm -f /etc/newrelic-infra/integrations.d/*-config.yml
cp "$REPO"/host/newrelic/*-config.yml /etc/newrelic-infra/integrations.d/
cp "$REPO/host/newrelic/logs.yml" /etc/newrelic-infra/logging.d/logs.yml
sed -i "s|__PG_PASSWORD__|$PG_PASS|" /etc/newrelic-infra/integrations.d/postgresql-config.yml
sed -i "s|__REDIS_PASSWORD__|$REDIS_PASS|" /etc/newrelic-infra/integrations.d/redis-config.yml
chmod 600 /etc/newrelic-infra/integrations.d/*.yml
systemctl restart newrelic-infra

# ---------------------------------------------------------------- 7. k3s and Helm
step "7/10 Installing k3s (Kubernetes) and Helm"
if ! command -v k3s >/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
fi
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do echo "waiting for k3s..."; sleep 5; done

# ---------------------------------------------------------------- 8. New Relic Kubernetes integration
step "8/10 Installing the New Relic Kubernetes integration (nri-bundle)"
helm repo add newrelic https://helm-charts.newrelic.com >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install newrelic-bundle newrelic/nri-bundle \
  --namespace newrelic --create-namespace \
  -f "$REPO/helm/newrelic-values.yaml" \
  --set global.cluster="$CLUSTER_NAME" \
  --set global.licenseKey="$NR_KEY"
# Running pods keep the key they started with. Restart them all so a changed key
# (key rotation, or fixing a wrong key) takes effect everywhere, not just in the
# pods whose health checks happen to fail. Lesson from the first local run.
kubectl -n newrelic rollout restart deployment,daemonset

# ---------------------------------------------------------------- 9. images
step "9/10 Building the 4 service images and importing them into k3s"
for svc in signal-api timing-engine crew-dispatch simulator; do
  echo "    building corridor-$svc"
  docker build -q -t "local/corridor-$svc:latest" "$REPO/services/$svc" >/dev/null
  docker save "local/corridor-$svc:latest" | k3s ctr images import - >/dev/null
done

# ---------------------------------------------------------------- 10. deploy
step "10/10 Deploying the services"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: corridor
EOF
kubectl -n corridor create secret generic corridor-secrets \
  --from-literal=nr_license_key="$NR_KEY" \
  --from-literal=pg_password="$PG_PASS" \
  --from-literal=redis_password="$REDIS_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n corridor create configmap corridor-config \
  --from-literal=host_ip="$NODE_IP" \
  --dry-run=client -o yaml | kubectl apply -f -

# Local differences: locally built images that are never pulled, one replica each, env:local label.
sed -e "s|IMAGE_PREFIX|local|g" \
    -e "s|PULL_POLICY|Never|g" \
    -e "s|replicas: 2|replicas: 1|g" \
    -e "s|env:demo|env:local|g" \
    "$REPO/k8s/apps.yaml" | kubectl apply -f -
kubectl -n corridor rollout restart deploy >/dev/null
for d in signal-api timing-engine crew-dispatch corridor-simulator; do
  kubectl -n corridor rollout status "deploy/$d" --timeout=240s
done

echo
echo "==> DONE"
echo "Portal:        http://$NODE_IP/"
echo "Pods:          kubectl -n corridor get pods"
echo "Incident:      sudo bash $REPO/scripts/fault.sh timing-bug on"
echo "New Relic:     data appears within 2 to 5 minutes"
