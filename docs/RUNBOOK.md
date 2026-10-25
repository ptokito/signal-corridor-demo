# Smart Signal Corridor: build runbook

Working guide for building the demo. Every command has a plain-language explanation.
Screenshots marked **Capture** go into the customer document.

## The scenario in one paragraph

A state DOT (modeled on Tennessee) is piloting connected traffic signals on 10 intersections of
US-41/70S Murfreesboro Pike in Nashville. Each signal controller checks in every few seconds and
receives its timing plan. Release **2026.2** of the timing engine has a unit-conversion defect
that shortens every yellow interval from about 4 seconds to about 2, below the 3-second minimum.
Every server stays healthy and every request returns HTTP 200, so traditional monitoring sees
nothing. New Relic catches it through a business signal (timing compliance), a Synthetics check
that asserts the safety rule, and traces that show the exact plan version and yellow value.

## Components

| Tier | Component | Language | New Relic instrumentation |
|---|---|---|---|
| Host (VM) | NGINX | | Infrastructure agent, NGINX integration, log forwarding |
| Host (VM) | Operations Portal (`ops-portal`) | Python, Flask | Python APM agent, Browser (auto-injected) |
| Host (VM) | PostgreSQL | | PostgreSQL integration, log forwarding |
| Host (VM) | Redis | | Redis integration, log forwarding |
| Kubernetes | `signal-api` | Python, Flask | Python APM agent, custom attributes, custom event `SignalCheckin` |
| Kubernetes | `timing-engine` | Node.js, Express | Node.js APM agent, custom attributes |
| Kubernetes | `crew-dispatch` | Python, Flask | OpenTelemetry only: auto-instrumentation, custom spans and attributes |
| Kubernetes | `corridor-simulator` | Python | none (it plays the outside world) |
| Kubernetes | cluster | | nri-bundle: infrastructure, kube-state-metrics, events, metadata injection, logs |
| AWS | EC2, EBS | | AWS cloud integration (API polling) |
| Internet | | | Synthetics: ping monitor plus scripted compliance check |

Request paths:
- **Controller check-in:** simulator → signal-api → timing-engine (Redis, PostgreSQL) → signal-api (PostgreSQL)
- **Engineer views a page:** browser → NGINX → ops-portal → signal-api → timing-engine
- **Field report:** browser → NGINX → ops-portal → signal-api → timing-engine → crew-dispatch

## Part A. Local test on your Ubuntu VM

1. Revert the VM snapshot taken before the first test (or skip: the setup script removes the
   earlier Tidewater test automatically). Take a fresh snapshot.
2. Copy the zip from Windows and unzip it on the VM:
   ```powershell
   scp D:\downloads\signal-corridor-demo.zip timokito@192.168.71.135:~
   ```
   ```bash
   cd ~ && rm -rf signal-corridor-demo && unzip -q signal-corridor-demo.zip && cd signal-corridor-demo
   ```
3. Run the setup with the license key from the NEW demo account:
   ```bash
   export NEW_RELIC_LICENSE_KEY='PASTE_NRAL_KEY'
   sudo env NEW_RELIC_LICENSE_KEY="$NEW_RELIC_LICENSE_KEY" bash scripts/local-setup.sh
   ```
4. Verify (see "Checks" below).

## Part B. AWS build

1. Create the GitHub repo `signal-corridor-demo` (public) and push this folder.
2. Wait for the `build-images` workflow, then make the four `corridor-*` packages public.
3. Terraform:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # set repo_url and newrelic_account_id
   export TF_VAR_newrelic_license_key='PASTE_NRAL_KEY'
   terraform init && terraform plan -out corridor.plan && terraform apply corridor.plan
   ```
4. On the k3s node (`$(terraform output -raw connect_k3s)`, then `sudo -i`):
   ```bash
   bash /opt/corridor/scripts/install-newrelic-k8s.sh
   bash /opt/corridor/scripts/deploy-apps.sh <host_private_ip> <github_user>
   ```
5. Synthetics, AWS integration, dashboard, alerts (separate steps).

## Checks

```bash
kubectl -n corridor get pods          # 4 Deployments, all Running
kubectl -n newrelic get pods          # all Running
kubectl -n corridor logs deploy/corridor-simulator --tail 5   # no "failed" lines
```

In New Relic after 5 minutes:

```sql
-- Every component reporting (expect corridor-ops-portal, corridor-signal-api,
-- corridor-timing-engine, corridor-crew-dispatch)
FROM Span SELECT count(*) WHERE entity.name LIKE 'corridor-%' FACET entity.name SINCE 10 minutes ago

-- Host integrations (expect NginxSample, PostgresqlDatabaseSample, RedisSample)
FROM NginxSample, PostgresqlDatabaseSample, RedisSample SELECT count(*) FACET eventType() SINCE 10 minutes ago

-- Business data (expect about 100% compliant, plan 2026.1)
FROM SignalCheckin SELECT count(*), percentage(count(*), WHERE compliant IS true) FACET planVersion SINCE 10 minutes ago
```

## The incident

```bash
sudo bash scripts/fault.sh timing-bug on     # release timing plan 2026.2
# ...10 minutes...
sudo bash scripts/fault.sh timing-bug off    # roll back
```

Expected: error rate stays 0%, compliance drops from 100% to 0%, the portal shows red yellow
values, the Synthetics check fails, traces show `planVersion=2026.2` and `yellowSeconds=2.0`.

## If something breaks

| Symptom | Likely cause | Fix |
|---|---|---|
| Portal shows "Corridor data is unavailable" | signal-api not ready or NodePort blocked | `kubectl -n corridor get pods`; on AWS check the security group rule for 30081 |
| Pods in `ImagePullBackOff` (AWS) | GHCR packages still private | Make them public |
| `crew-dispatch` missing in New Relic | OTLP export blocked or bad key | `kubectl -n corridor logs deploy/crew-dispatch` and look for export errors |
| No PostgreSQL or Redis data | integration password | check `/etc/newrelic-infra/integrations.d/`, then `systemctl restart newrelic-infra` |
| No Browser data | Browser not enabled for the APM app | APM > corridor-ops-portal > Browser > enable, then `systemctl restart corridor-portal` |
