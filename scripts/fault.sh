#!/bin/bash
# =============================================================================
# Turns the demo incident on and off.
# =============================================================================
#   sudo bash scripts/fault.sh timing-bug on    release timing plan 2026.2 (the defect)
#   sudo bash scripts/fault.sh timing-bug off   roll back to timing plan 2026.1
#   sudo bash scripts/fault.sh status           show which plan is live
#
# How it works: it changes the PLAN_VERSION environment variable on the
# timing-engine Deployment. Kubernetes then replaces the pods one at a time
# (a rolling update), exactly like a real release.
#
# Change tracking (optional but recommended for the demo): if NR_USER_KEY and
# TIMING_ENGINE_GUID are set, each switch is also recorded in New Relic as a
# deployment marker, so charts show a vertical line at the moment of the release.
#   export NR_USER_KEY='NRAK-...'            # User API key, from the API keys page
#   export TIMING_ENGINE_GUID='...'          # entity GUID of corridor-timing-engine
#                                            # (APM > corridor-timing-engine > metadata)
# =============================================================================
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Record a change-tracking marker through New Relic's GraphQL API (NerdGraph).
marker() { # $1 version, $2 description
  if [ -z "${NR_USER_KEY:-}" ] || [ -z "${TIMING_ENGINE_GUID:-}" ]; then
    echo "(no change marker: NR_USER_KEY or TIMING_ENGINE_GUID not set)"; return 0
  fi
  curl -s https://api.newrelic.com/graphql \
    -H "Content-Type: application/json" -H "API-Key: $NR_USER_KEY" \
    -d "{\"query\":\"mutation { changeTrackingCreateDeployment(deployment: {entityGuid: \\\"$TIMING_ENGINE_GUID\\\", version: \\\"$1\\\", description: \\\"$2\\\", user: \\\"release-pipeline\\\"}) { deploymentId } }\"}"
  echo
}

case "${1:-status}:${2:-}" in
  timing-bug:on)
    echo "$(date -u +%H:%M:%S) UTC  Releasing timing plan 2026.2"
    kubectl -n corridor set env deploy/timing-engine PLAN_VERSION=2026.2
    marker "timing-plan-2026.2" "Timing plan 2026.2: metric unit support"
    ;;
  timing-bug:off)
    echo "$(date -u +%H:%M:%S) UTC  Rolling back to timing plan 2026.1"
    kubectl -n corridor set env deploy/timing-engine PLAN_VERSION=2026.1
    marker "timing-plan-2026.1" "Rollback to timing plan 2026.1"
    ;;
  *)
    kubectl -n corridor get deploy timing-engine \
      -o jsonpath='{"PLAN_VERSION="}{.spec.template.spec.containers[0].env[?(@.name=="PLAN_VERSION")].value}{"\n"}'
    exit 0
    ;;
esac
kubectl -n corridor rollout status deploy/timing-engine --timeout=120s
