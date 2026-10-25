#!/bin/bash
# Undo scripts/local-setup.sh. Reverting your VM snapshot is cleaner; this is the fallback.
# Usage: sudo bash scripts/local-teardown.sh [--purge]
#   --purge also uninstalls the New Relic packages.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

# Stop the portal and the infrastructure agent.
systemctl disable --now corridor-portal newrelic-infra 2>/dev/null
rm -f /etc/systemd/system/corridor-portal.service && systemctl daemon-reload

# Remove k3s entirely (this also removes every pod, image and the New Relic Kubernetes integration).
[ -x /usr/local/bin/k3s-uninstall.sh ] && /usr/local/bin/k3s-uninstall.sh

# Put NGINX back to its default site.
rm -f /etc/nginx/sites-enabled/corridor /etc/nginx/sites-available/corridor
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null
systemctl reload nginx 2>/dev/null

# Drop the demo database and roles; restore Redis defaults.
sudo -u postgres psql -c "DROP DATABASE IF EXISTS corridor" -c "DROP ROLE IF EXISTS corridor" -c "DROP ROLE IF EXISTS newrelic" 2>/dev/null
sed -i "/^requirepass /d; s/^bind .*/bind 127.0.0.1 -::1/" /etc/redis/redis.conf && systemctl restart redis-server

# Remove the Docker images and local secrets.
for t in signal-api timing-engine crew-dispatch simulator; do docker rmi "local/corridor-$t:latest" 2>/dev/null; done
rm -rf /etc/corridor /opt/corridor-portal-venv

if [ "${1:-}" = "--purge" ]; then
  apt-get purge -y newrelic-infra nri-nginx nri-postgresql nri-redis
  rm -f /etc/apt/sources.list.d/newrelic-infra.list /etc/newrelic-infra.yml
fi
echo "Smart Signal Corridor removed. PostgreSQL still listens on all interfaces and pg_hba.conf"
echo "still has the 'corridor-demo' lines; remove them by hand if this machine is shared."
