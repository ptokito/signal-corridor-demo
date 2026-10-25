"""
Builds the importable New Relic dashboard for the Smart Signal Corridor.

USAGE
  python3 newrelic/build_dashboard.py <NEW_RELIC_ACCOUNT_ID>
  -> writes newrelic/dashboard.rendered.json
  Import: Dashboards > Import dashboard > paste the file's contents.

THREE TABS, ONE PER AUDIENCE
  1. Traffic Operations   "Are my signals running safe timing right now?"
  2. Platform Health      MELT (Metrics, Events, Logs, Traces) and the four Golden
                          Signals (latency, traffic, errors, saturation), across
                          APM, OpenTelemetry, Browser, Synthetics, Kubernetes and
                          the host integrations
  3. Executive            risk and outcomes in plain numbers

Every query is scoped to this project (entity names starting "corridor-", the
NGINX/PostgreSQL/Redis log sources, monitors starting "Corridor") so the
dashboard stays clean in an account that also holds other applications.
"""
import json
import sys
from pathlib import Path

if len(sys.argv) != 2 or not sys.argv[1].isdigit():
    sys.exit("usage: python3 newrelic/build_dashboard.py <NEW_RELIC_ACCOUNT_ID>")
ACCOUNT = int(sys.argv[1])
APPS = "appName LIKE 'corridor-%'"


def w(title, query, viz="viz.line", col=1, row=1, width=4, height=3):
    """One widget: a title, an NRQL query, a chart type and a grid position (12 columns wide)."""
    return {
        "title": title,
        "layout": {"column": col, "row": row, "width": width, "height": height},
        "visualization": {"id": viz},
        "rawConfiguration": {"nrqlQueries": [{"accountIds": [ACCOUNT], "query": query}]},
    }


# ---------------------------------------------------------------- 1. Traffic Operations
operations = [
    w("Timing compliance, last 5 minutes",
      "FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true) AS 'Compliant check-ins' "
      "SINCE 5 minutes ago", viz="viz.billboard", col=1, row=1),
    w("Intersections on unsafe timing, last 5 minutes",
      "FROM SignalCheckin SELECT uniqueCount(intersectionId) AS 'Intersections' WHERE compliant IS false "
      "SINCE 5 minutes ago", viz="viz.billboard", col=5, row=1),
    w("Controller check-ins per minute",
      "FROM SignalCheckin SELECT rate(count(*), 1 minute) AS 'Check-ins / min' SINCE 5 minutes ago",
      viz="viz.billboard", col=9, row=1),
    w("Live timing by intersection",
      "FROM SignalCheckin SELECT latest(yellowSeconds) AS 'Yellow (s)', latest(planVersion) AS 'Plan', "
      "latest(speedMph) AS 'Speed (mph)', latest(controllerState) AS 'Controller' "
      "FACET intersectionName SINCE 5 minutes ago LIMIT 10", viz="viz.table", col=1, row=4, width=6, height=4),
    w("Timing compliance over time (%)",
      "FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true) AS 'Compliant %' TIMESERIES",
      col=7, row=4, width=6, height=4),
    w("Check-ins by timing plan version",
      "FROM SignalCheckin SELECT count(*) FACET planVersion TIMESERIES", viz="viz.area", col=1, row=8, width=6),
    w("Field reports by issue",
      "FROM Transaction SELECT count(*) WHERE appName = 'corridor-signal-api' AND issueType IS NOT NULL "
      "FACET issueType", viz="viz.bar", col=7, row=8, width=6),
]

# ---------------------------------------------------------------- 2. Platform Health
platform = [
    # MELT
    w("METRIC | App response time (ms)",
      f"FROM Metric SELECT average(apm.service.transaction.duration) * 1000 AS 'ms' WHERE {APPS} "
      "FACET appName TIMESERIES", col=1, row=1),
    w("EVENT | Kubernetes events in the corridor namespace",
      "FROM InfrastructureEvent SELECT count(*) WHERE category = 'kubernetes' "
      "AND event.involvedObject.namespace = 'corridor' FACET event.reason, event.involvedObject.name",
      viz="viz.table", col=5, row=1),
    w("LOG | Log lines by source",
      "FROM Log SELECT count(*) WHERE entity.name LIKE 'corridor-%' "
      "OR service IN ('nginx-proxy', 'postgresql', 'redis') FACET entity.name, service TIMESERIES",
      viz="viz.area", col=9, row=1),
    w("TRACE | p95 span duration by service (agents and OpenTelemetry)",
      "FROM Span SELECT percentile(duration.ms, 95) WHERE entity.name LIKE 'corridor-%' "
      "FACET entity.name TIMESERIES", col=1, row=4),
    # Golden Signals
    w("LATENCY | p95 web response time (ms)",
      f"FROM Transaction SELECT percentile(duration * 1000, 95) WHERE {APPS} AND transactionType = 'Web' "
      "FACET appName TIMESERIES", col=5, row=4),
    w("TRAFFIC | Requests per minute",
      f"FROM Transaction SELECT rate(count(*), 1 minute) WHERE {APPS} FACET appName TIMESERIES",
      col=9, row=4),
    w("ERRORS | Error rate (%)",
      f"FROM Transaction SELECT percentage(count(*), WHERE error IS true) WHERE {APPS} "
      "FACET appName TIMESERIES", col=1, row=7),
    w("SATURATION | Host CPU and memory (%)",
      "FROM SystemSample SELECT average(cpuPercent) AS 'CPU %', average(memoryUsedPercent) AS 'Memory %' "
      "WHERE project = 'smart-signal-corridor' OR clusterName LIKE 'corridor-%' "
      "FACET hostname TIMESERIES", col=5, row=7),
    w("SATURATION | Container memory (MB)",
      "FROM K8sContainerSample SELECT average(memoryWorkingSetBytes) / 1e6 AS 'MB' "
      "WHERE namespaceName = 'corridor' FACET containerName TIMESERIES", col=9, row=7),
    # Middleware, Browser, Synthetics
    w("NGINX | Active connections and requests per second",
      "FROM NginxSample SELECT average(net.connectionsActive) AS 'active', "
      "average(net.requestsPerSecond) AS 'req/s' TIMESERIES", col=1, row=10),
    w("REDIS and POSTGRESQL | Cache hit ratio and DB connections",
      "FROM RedisSample, PostgresqlDatabaseSample SELECT "
      "average(db.keyspaceHitsPerSecond) / (average(db.keyspaceHitsPerSecond) + average(db.keyspaceMissesPerSecond)) * 100 "
      "AS 'Redis hit %', latest(db.connections) AS 'Postgres connections' TIMESERIES", col=5, row=10),
    w("BROWSER | Page load p75 (s) and JavaScript errors",
      "FROM PageView, JavaScriptError SELECT percentile(duration, 75) AS 'Page load p75 (s)', "
      "filter(count(*), WHERE eventType() = 'JavaScriptError') AS 'JS errors' "
      "WHERE appName = 'corridor-ops-portal' TIMESERIES", col=9, row=10),
    w("SYNTHETICS | Check success rate by monitor",
      "FROM SyntheticCheck SELECT percentage(count(*), WHERE result = 'SUCCESS') AS 'Success %' "
      "WHERE monitorName LIKE 'Corridor%' FACET monitorName TIMESERIES", col=1, row=13, width=12),
]

# ---------------------------------------------------------------- 3. Executive
executive = [
    w("Corridor timing compliance (selected period)",
      "FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true) AS 'Compliant'",
      viz="viz.billboard", col=1, row=1),
    w("Unsafe timing plans sent to signals",
      "FROM SignalCheckin SELECT count(*) AS 'Unsafe plans served' WHERE compliant IS false",
      viz="viz.billboard", col=5, row=1),
    w("Minutes with unsafe timing",
      "FROM (FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true) AS pct TIMESERIES 1 minute) "
      "SELECT count(*) AS 'Minutes below 95%' WHERE pct < 95", viz="viz.billboard", col=9, row=1),
    w("Timing compliance trend (%)",
      "FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true) AS 'Compliant %' TIMESERIES",
      col=1, row=4, width=8),
    w("Crew notifications delivered (%)",
      "FROM Span SELECT percentage(count(*), WHERE otel.status_code IS NULL OR otel.status_code != 'ERROR') "
      "AS 'Delivered' WHERE name = 'notify.sms'", viz="viz.billboard", col=9, row=4),
    w("Field reports handled",
      "FROM Transaction SELECT count(*) AS 'Reports' WHERE appName = 'corridor-signal-api' AND issueType IS NOT NULL",
      viz="viz.billboard", col=9, row=7),
    w("Operator portal: page load p75 (s)",
      "FROM PageView SELECT percentile(duration, 75) AS 'p75 seconds' WHERE appName = 'corridor-ops-portal' TIMESERIES",
      col=1, row=7, width=8),
]

dashboard = {
    "name": "Smart Signal Corridor | Murfreesboro Pike",
    "description": "Traffic operations, platform health (MELT and Golden Signals) and executive outcomes",
    "permissions": "PUBLIC_READ_WRITE",
    "pages": [
        {"name": "Traffic Operations", "widgets": operations},
        {"name": "Platform Health (MELT + Golden Signals)", "widgets": platform},
        {"name": "Executive", "widgets": executive},
    ],
}

out = Path(__file__).with_name("dashboard.rendered.json")
out.write_text(json.dumps(dashboard, indent=2))
print(f"wrote {out} for account {ACCOUNT}: "
      f"{sum(len(p['widgets']) for p in dashboard['pages'])} widgets on {len(dashboard['pages'])} tabs")
