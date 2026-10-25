#!/bin/bash
# Host tier bootstrap for AWS (runs once, as EC2 user data, on first boot).
# Terraform renders this file with templatefile() and fills in: region, repo_url,
# k3s_private_ip and vpc_cidr. Secrets are NOT in this file: they are read from
# SSM Parameter Store at boot, using the instance's IAM role.
# Same steps as scripts/local-setup.sh steps 1 to 6.
# Progress log: /var/log/corridor-bootstrap.log
#
# No "set -x" here on purpose: tracing would print every command with its values,
# writing the license key and passwords into the log and the EC2 console output.
# Progress is reported with step() lines instead.
set -euo pipefail
exec > /var/log/corridor-bootstrap.log 2>&1
step() { echo "$(date -u +%H:%M:%S) ==> $*"; }

REGION="${region}"
REPO_URL="${repo_url}"
K3S_IP="${k3s_private_ip}"
VPC_CIDR="${vpc_cidr}"

step "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx postgresql redis-server python3-venv git curl gnupg jq
snap install aws-cli --classic

step "Reading secrets from SSM Parameter Store"
param() { aws ssm get-parameter --region "$REGION" --with-decryption --name "$1" --query Parameter.Value --output text; }
NR_KEY=$(param /signal-corridor/newrelic-license-key)
PG_PASS=$(param /signal-corridor/postgres-password)
REDIS_PASS=$(param /signal-corridor/redis-password)

# ---------------------------------------------------------------- PostgreSQL
step "Configuring PostgreSQL"
PG_CONF_DIR=$(ls -d /etc/postgresql/*/main)
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "$PG_CONF_DIR/postgresql.conf"
echo "host corridor corridor $VPC_CIDR scram-sha-256" >> "$PG_CONF_DIR/pg_hba.conf"
systemctl restart postgresql
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE corridor LOGIN PASSWORD '$PG_PASS';
CREATE DATABASE corridor OWNER corridor;
-- read-only monitoring user for the New Relic PostgreSQL integration
CREATE ROLE newrelic LOGIN PASSWORD '$PG_PASS';
GRANT pg_monitor TO newrelic;
SQL

# ---------------------------------------------------------------- Redis
step "Configuring Redis"
sed -i "s/^bind .*/bind 0.0.0.0/" /etc/redis/redis.conf
sed -i "s/^protected-mode yes/protected-mode no/" /etc/redis/redis.conf
echo "requirepass $REDIS_PASS" >> /etc/redis/redis.conf
systemctl restart redis-server

# ---------------------------------------------------------------- Operations Portal (Flask + New Relic Python agent)
step "Installing the Operations Portal"
git clone "$REPO_URL" /opt/corridor
python3 -m venv /opt/corridor-portal-venv
/opt/corridor-portal-venv/bin/pip install -r /opt/corridor/services/ops-portal/requirements.txt

cat > /etc/systemd/system/corridor-portal.service <<UNIT
[Unit]
Description=Smart Signal Corridor Operations Portal (Flask) with New Relic Python agent
After=network-online.target

[Service]
WorkingDirectory=/opt/corridor/services/ops-portal
Environment=NEW_RELIC_LICENSE_KEY=$NR_KEY
Environment=NEW_RELIC_APP_NAME=corridor-ops-portal
Environment=NEW_RELIC_LABELS=env:demo;tier:host;team:traffic-operations
Environment=NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
Environment=NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
Environment=SIGNAL_API_URL=http://$K3S_IP:30081
ExecStart=/opt/corridor-portal-venv/bin/newrelic-admin run-program /opt/corridor-portal-venv/bin/gunicorn -w 3 -b 127.0.0.1:8000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
chmod 600 /etc/systemd/system/corridor-portal.service
systemctl enable --now corridor-portal

# ---------------------------------------------------------------- NGINX reverse proxy
step "Configuring NGINX"
cp /opt/corridor/host/nginx-corridor.conf /etc/nginx/sites-available/corridor
ln -sf /etc/nginx/sites-available/corridor /etc/nginx/sites-enabled/corridor
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- New Relic infrastructure agent
step "Installing the New Relic infrastructure agent and integrations"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.newrelic.com/infrastructure_agent/gpg/newrelic-infra.gpg \
  | gpg --dearmor -o /etc/apt/keyrings/newrelic-infra.gpg
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [signed-by=/etc/apt/keyrings/newrelic-infra.gpg] https://download.newrelic.com/infrastructure_agent/linux/apt $CODENAME main" \
  > /etc/apt/sources.list.d/newrelic-infra.list

cat > /etc/newrelic-infra.yml <<CFG
license_key: $NR_KEY
display_name: corridor-host-tier
custom_attributes:
  environment: demo
  tier: host
  project: smart-signal-corridor
CFG

apt-get update -y
apt-get install -y newrelic-infra nri-nginx nri-postgresql nri-redis

# On-host integration configs and log forwarding (copied from the repo, then secrets filled in)
cp /opt/corridor/host/newrelic/*-config.yml /etc/newrelic-infra/integrations.d/
cp /opt/corridor/host/newrelic/logs.yml /etc/newrelic-infra/logging.d/logs.yml
sed -i "s|__PG_PASSWORD__|$PG_PASS|" /etc/newrelic-infra/integrations.d/postgresql-config.yml
sed -i "s|__REDIS_PASSWORD__|$REDIS_PASS|" /etc/newrelic-infra/integrations.d/redis-config.yml
chmod 600 /etc/newrelic-infra/integrations.d/*.yml /etc/newrelic-infra.yml
systemctl restart newrelic-infra

step "BOOTSTRAP COMPLETE"
