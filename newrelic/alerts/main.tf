# =============================================================================
# Smart Signal Corridor: New Relic alerts as code (Terraform)
# =============================================================================
# Creates, in New Relic account var.account_id:
#   1 alert policy   "Smart Signal Corridor"
#   6 NRQL alert conditions (described below, most important first)
#   1 email destination, 1 email channel, 1 workflow that sends every issue from
#     this policy to var.alert_email
#
# How New Relic alerting fits together:
#   condition  = a NRQL query + thresholds, evaluated every minute
#   policy     = a folder of conditions; decides how violations group into issues
#   workflow   = routes issues from the policy to notification channels
#   channel    = how to notify (here: email), using a destination (the address)
#
# Authentication: the provider reads a New Relic USER key (starts with NRAK-)
# from the NEW_RELIC_API_KEY environment variable, so no key is ever in this file.
#
# Run (from this folder):
#   export NEW_RELIC_API_KEY='NRAK-...'
#   terraform init
#   terraform plan  -out alerts.plan
#   terraform apply alerts.plan
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.0"
    }
  }
}

provider "newrelic" {
  account_id = var.account_id
  region     = "US"
}

# ---------------------------------------------------------------- policy
resource "newrelic_alert_policy" "corridor" {
  name = "Smart Signal Corridor"
  # One issue per condition AND per target (for example per service), so a
  # problem in signal-api and one in timing-engine are tracked separately.
  incident_preference = "PER_CONDITION_AND_TARGET"
}

# ---------------------------------------------------------------- 1. the business signal
# THE condition that catches the demo incident. During timing plan 2026.2 every
# service is healthy and returns HTTP 200, so no performance or error alert fires.
# This one evaluates what actually matters: are signals running safe timing?
resource "newrelic_nrql_alert_condition" "timing_compliance" {
  account_id  = var.account_id
  policy_id   = newrelic_alert_policy.corridor.id
  type        = "static"
  name        = "Signal timing compliance below standard"
  # Issue title shown in New Relic and used as the email subject. Without it, the
  # title is generic ("corridor-signal-api query result is below...").
  title_template = "Unsafe signal timing on the Murfreesboro Pike corridor"
  description = <<-EOT
    Share of controller check-ins receiving a yellow interval of at least 3.0 seconds.
    Below 95% means signals are running unsafe timing. First check: the planVersion
    attribute on recent SignalCheckin events and timing-engine spans; roll back the
    latest timing plan release if it coincides with the drop.
  EOT
  enabled                      = true
  violation_time_limit_seconds = 86400 # auto-close after 24 h if never resolved

  nrql {
    query = "FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true)"
  }

  # Event flow: data is grouped into 1-minute windows by event timestamp and each
  # window is evaluated 2 minutes after it closes (allows for late-arriving data).
  aggregation_method = "event_flow"
  aggregation_window = 60
  aggregation_delay  = 120

  critical {
    operator              = "below"
    threshold             = 95
    threshold_duration    = 120 # 2 consecutive minutes
    threshold_occurrences = "all"
  }
  warning {
    operator              = "below"
    threshold             = 99
    threshold_duration    = 120
    threshold_occurrences = "all"
  }
}

# ---------------------------------------------------------------- 2. signals going silent
# Ten controllers should check in every few seconds. Fewer than 10 distinct
# intersections in a minute means a signal (or the check-in path) is down.
# If no check-ins arrive at all, the "loss of signal" settings open an issue too.
resource "newrelic_nrql_alert_condition" "controllers_reporting" {
  account_id  = var.account_id
  policy_id   = newrelic_alert_policy.corridor.id
  type        = "static"
  name        = "Signal controllers not checking in"
  description = <<-EOT
    Fewer than 10 intersections checked in during the last minute, or no check-ins
    at all. Check the corridor-simulator (controllers), then signal-api health.
  EOT
  enabled                      = true
  violation_time_limit_seconds = 86400

  nrql {
    query = "FROM SignalCheckin SELECT uniqueCount(intersectionId)"
  }

  aggregation_method = "event_flow"
  aggregation_window = 60
  aggregation_delay  = 120

  critical {
    operator              = "below"
    threshold             = 10
    threshold_duration    = 180
    threshold_occurrences = "all"
  }

  # Loss of signal: no data for 5 minutes opens an issue (all controllers silent),
  # and the issue closes when data returns.
  expiration_duration            = 300
  open_violation_on_expiration   = true
  close_violations_on_expiration = true
}

# ---------------------------------------------------------------- 3. application errors
# Classic APM error-rate alert, one evaluation per service (FACET appName).
resource "newrelic_nrql_alert_condition" "app_error_rate" {
  account_id  = var.account_id
  policy_id   = newrelic_alert_policy.corridor.id
  type        = "static"
  name        = "Corridor service error rate high"
  description = "More than 5% of requests failing for 5 minutes on {{tag.appName}}. Open the service's Errors inbox."
  enabled                      = true
  violation_time_limit_seconds = 86400

  nrql {
    query = "FROM Transaction SELECT percentage(count(*), WHERE error IS true) WHERE appName LIKE 'corridor-%' FACET appName"
  }

  aggregation_method = "event_flow"
  aggregation_window = 60
  aggregation_delay  = 120

  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
  warning {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---------------------------------------------------------------- 4. slow check-ins
# Controllers expect an answer quickly. p95 web response time above 500 ms on
# signal-api for 5 minutes means the check-in path is degrading.
resource "newrelic_nrql_alert_condition" "signal_api_latency" {
  account_id  = var.account_id
  policy_id   = newrelic_alert_policy.corridor.id
  type        = "static"
  name        = "signal-api p95 response time high"
  description = "p95 response time on corridor-signal-api above 500 ms for 5 minutes. Check traces for slow PostgreSQL, Redis or timing-engine spans."
  enabled                      = true
  violation_time_limit_seconds = 86400

  nrql {
    query = "FROM Transaction SELECT percentile(duration, 95) WHERE appName = 'corridor-signal-api' AND transactionType = 'Web'"
  }

  aggregation_method = "event_flow"
  aggregation_window = 60
  aggregation_delay  = 120

  critical {
    operator              = "above"
    threshold             = 0.5 # seconds
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---------------------------------------------------------------- 5. Kubernetes crash loops
# More than 2 container restarts in 5 minutes in the corridor namespace means a
# service is crash-looping (bad release, out of memory, failing probes).
resource "newrelic_nrql_alert_condition" "k8s_restarts" {
  account_id  = var.account_id
  policy_id   = newrelic_alert_policy.corridor.id
  type        = "static"
  name        = "Corridor containers restarting"
  description = "Container {{tag.containerName}} restarted repeatedly. Check Kubernetes events and the previous container's logs."
  enabled                      = true
  violation_time_limit_seconds = 86400

  nrql {
    query = "FROM K8sContainerSample SELECT sum(restartCountDelta) WHERE namespaceName = 'corridor' FACET containerName"
  }

  aggregation_method = "event_flow"
  aggregation_window = 300
  aggregation_delay  = 120

  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}

# ---------------------------------------------------------------- 6. host tier
# CPU saturation on the VM that runs NGINX, the portal, PostgreSQL and Redis, plus
# loss of signal: if the host stops reporting for 5 minutes (powered off, network
# down, agent stopped) an issue opens.
resource "newrelic_nrql_alert_condition" "host_cpu" {
  account_id  = var.account_id
  policy_id   = newrelic_alert_policy.corridor.id
  type        = "static"
  name        = "Host tier CPU high or host not reporting"
  description = "The host tier ({{tag.hostname}}) is above 90% CPU for 5 minutes, or has stopped reporting."
  enabled                      = true
  violation_time_limit_seconds = 86400

  nrql {
    query = "FROM SystemSample SELECT average(cpuPercent) WHERE project = 'smart-signal-corridor' FACET hostname"
  }

  aggregation_method = "event_flow"
  aggregation_window = 60
  aggregation_delay  = 120

  critical {
    operator              = "above"
    threshold             = 90
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  expiration_duration            = 300
  open_violation_on_expiration   = true
  close_violations_on_expiration = true
}

# ---------------------------------------------------------------- notifications
# Destination: where notifications can go (an email address).
resource "newrelic_notification_destination" "email" {
  account_id = var.account_id
  name       = "Corridor on-call email"
  type       = "EMAIL"
  property {
    key   = "email"
    value = var.alert_email
  }
}

# Channel: how a notification is sent to that destination, and its subject line.
resource "newrelic_notification_channel" "email" {
  account_id     = var.account_id
  name           = "Corridor alerts by email"
  type           = "EMAIL"
  destination_id = newrelic_notification_destination.email.id
  product        = "IINT" # IINT = alert issues (New Relic's "incident intelligence")
  property {
    key   = "subject"
    value = "{{ issueTitle }}"
  }
}

# Workflow: send every issue raised by this policy to the email channel.
resource "newrelic_workflow" "corridor" {
  account_id            = var.account_id
  name                  = "Smart Signal Corridor to email"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "Issues from the Smart Signal Corridor policy"
    type = "FILTER"
    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.corridor.id]
    }
  }

  destination {
    channel_id = newrelic_notification_channel.email.id
    # Notify when an issue opens, is acknowledged, and closes (stated explicitly
    # rather than relying on the provider default).
    notification_triggers = ["ACTIVATED", "ACKNOWLEDGED", "CLOSED"]
  }
}

output "policy_id" {
  value = newrelic_alert_policy.corridor.id
}
