# Smart Signal Corridor: New Relic demo environment

A connected traffic-signal pilot on US-41/70S Murfreesboro Pike (Nashville, Tennessee), built to
show full-stack observability with New Relic in a customer-like hybrid environment: a
traditional virtual machine tier and a Kubernetes tier on AWS. Fictional scenario; not
affiliated with any state agency.

**New Relic coverage:** APM (Python and Node.js), OpenTelemetry (one service instrumented only
with OpenTelemetry, joined into the same distributed traces), Browser, Synthetics,
Infrastructure, on-host integrations (NGINX, PostgreSQL, Redis), Kubernetes, AWS cloud
integration, logs in context, custom attributes, custom events, custom spans, dashboards and
alerts.

Start with [docs/RUNBOOK.md](docs/RUNBOOK.md).

```
services/ops-portal       Operations Portal (Flask) on the VM, behind NGINX
services/signal-api       controller check-ins, intersections, field reports (Python, New Relic agent)
services/timing-engine    timing plan calculator (Node.js, New Relic agent)
services/crew-dispatch    field crew dispatch (Python, OpenTelemetry only)
services/simulator        10 simulated signal controllers, staff and field reports
host/                     NGINX config, New Relic on-host integration and log configs
helm/                     New Relic Kubernetes integration (nri-bundle) values
k8s/                      Kubernetes manifests
scripts/                  local setup, AWS bootstrap, deploy, incident toggle
terraform/                AWS infrastructure
newrelic/                 dashboard builder, Synthetics script
.github/workflows/        container image builds to GHCR
```
