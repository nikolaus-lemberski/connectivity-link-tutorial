#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

WAIT_TIMEOUT=120
NAMESPACE_WAIT_TIMEOUT=180

log() {
  echo "==> $*"
}

warn() {
  echo -e "${YELLOW}WARNING: $*${NC}"
}

resource_exists() {
  local kind=$1
  local name=$2
  local namespace=${3:-}

  if [[ -n "$namespace" ]]; then
    oc get "$kind" "$name" -n "$namespace" >/dev/null 2>&1
  else
    oc get "$kind" "$name" >/dev/null 2>&1
  fi
}

clear_finalizers() {
  local kind=$1
  local name=$2
  local namespace=${3:-}

  if [[ -n "$namespace" ]]; then
    oc patch "$kind" "$name" -n "$namespace" \
      -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
  else
    oc patch "$kind" "$name" \
      -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
  fi
}

delete_and_wait() {
  local kind=$1
  local name=$2
  local namespace=${3:-}
  local timeout=${4:-$WAIT_TIMEOUT}

  if ! resource_exists "$kind" "$name" "$namespace"; then
    return 0
  fi

  if [[ -n "$namespace" ]]; then
    oc delete "$kind" "$name" -n "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  else
    oc delete "$kind" "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  local elapsed=0
  while resource_exists "$kind" "$name" "$namespace" && [[ "$elapsed" -lt "$timeout" ]]; do
    sleep 3
    elapsed=$((elapsed + 3))
  done

  if resource_exists "$kind" "$name" "$namespace"; then
    warn "$kind/$name still present after ${timeout}s — clearing finalizers"
    clear_finalizers "$kind" "$name" "$namespace"
    if [[ -n "$namespace" ]]; then
      oc delete "$kind" "$name" -n "$namespace" --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
    else
      oc delete "$kind" "$name" --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
    fi
  fi
}

delete_all_and_wait() {
  local kind=$1
  local namespace=$2
  local timeout=${3:-$WAIT_TIMEOUT}

  local resources
  resources=$(oc get "$kind" -n "$namespace" -o name 2>/dev/null || true)
  if [[ -z "$resources" ]]; then
    return 0
  fi

  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    local name=${resource#*/}
    delete_and_wait "$kind" "$name" "$namespace" "$timeout"
  done <<< "$resources"
}

delete_csv_for_subscription() {
  local namespace=$1
  local subscription=$2

  local csv
  csv=$(oc get subscription "$subscription" -n "$namespace" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)

  delete_and_wait subscription "$subscription" "$namespace" 60

  if [[ -n "$csv" && "$csv" != "<no value>" ]]; then
    delete_and_wait csv "$csv" "$namespace" 120
  fi
}

force_cleanup_namespace() {
  local namespace=$1

  warn "Force-cleaning remaining resources in namespace $namespace"

  local api_resource
  for api_resource in $(oc api-resources --namespaced=true -o name 2>/dev/null); do
    local item
    for item in $(oc get "$api_resource" -n "$namespace" -o name 2>/dev/null || true); do
      [[ -z "$item" ]] && continue
      oc patch "$item" -n "$namespace" \
        -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
      oc delete "$item" -n "$namespace" --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
    done
  done

  if resource_exists namespace "$namespace"; then
    oc patch namespace "$namespace" \
      --type=json \
      -p='[{"op":"replace","path":"/spec/finalizers","value":[]}]' >/dev/null 2>&1 || true
  fi
}

delete_namespace_safe() {
  local namespace=$1
  local timeout=${2:-$NAMESPACE_WAIT_TIMEOUT}

  if ! resource_exists namespace "$namespace"; then
    return 0
  fi

  log "Deleting namespace $namespace"
  oc delete namespace "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  local elapsed=0
  while resource_exists namespace "$namespace" && [[ "$elapsed" -lt "$timeout" ]]; do
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if resource_exists namespace "$namespace"; then
    warn "Namespace $namespace stuck in Terminating after ${timeout}s"
    force_cleanup_namespace "$namespace"

    elapsed=0
    while resource_exists namespace "$namespace" && [[ "$elapsed" -lt 60 ]]; do
      sleep 5
      elapsed=$((elapsed + 5))
    done

    if resource_exists namespace "$namespace"; then
      warn "Namespace $namespace is still terminating — run: oc get all -n $namespace"
    fi
  fi
}

echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                        ⚠  WARNING  ⚠                           ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║  This script will remove ALL resources created by the           ║${NC}"
echo -e "${RED}║  Connectivity Link tutorial, including:                         ║${NC}"
echo -e "${RED}║                                                                 ║${NC}"
echo -e "${RED}║  • Red Hat Connectivity Link operator                           ║${NC}"
echo -e "${RED}║  • Red Hat build of Keycloak operator                           ║${NC}"
echo -e "${RED}║  • Cluster Observability Operator                               ║${NC}"
echo -e "${RED}║  • Tempo Operator                                               ║${NC}"
echo -e "${RED}║  • Red Hat build of OpenTelemetry Operator                      ║${NC}"
echo -e "${RED}║  • Gateway, Routes, Policies, and all tutorial namespaces       ║${NC}"
echo -e "${RED}║  • ClusterIssuer (selfsigned-cluster-issuer)                    ║${NC}"
echo -e "${RED}║  • User workload monitoring ConfigMap changes                   ║${NC}"
echo -e "${RED}║  • Tempo ObjectBucketClaim (but NOT ODF itself)                 ║${NC}"
echo -e "${RED}║                                                                 ║${NC}"
echo -e "${RED}║  Some of these components may have been installed before        ║${NC}"
echo -e "${RED}║  this tutorial. This script does NOT check for prior usage.     ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Are you sure you want to proceed? (yes/no)${NC}"
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

echo ""
echo "Starting cleanup..."
echo ""

log "Removing access log Telemetry CR..."
delete_and_wait telemetry api-gateway-access-logs openshift-ingress

log "Removing tracing components..."
delete_and_wait uiplugin distributed-tracing
delete_and_wait envoyfilter otel-tracing openshift-ingress

log "Removing tutorial-app tracing sidecar and instrumentation..."
delete_and_wait opentelemetrycollector otel-sidecar tutorial-app
delete_and_wait instrumentation echo-instrumentation tutorial-app

log "Removing TempoStack and collector..."
delete_and_wait tempostack tempostack tempo 180
delete_and_wait opentelemetrycollector otel tempo

log "Removing Tempo ObjectBucketClaim..."
delete_and_wait objectbucketclaim tempo-bucket tempo 180

log "Removing Tempo cluster RBAC..."
delete_and_wait clusterrolebinding tempostack-traces-reader
delete_and_wait clusterrolebinding tempostack-traces-writer
delete_and_wait clusterrole tempostack-traces-reader
delete_and_wait clusterrole tempostack-traces-writer

log "Removing OpenTelemetry Operator..."
delete_csv_for_subscription openshift-opentelemetry-operator opentelemetry-product
delete_and_wait operatorgroup openshift-opentelemetry-operator openshift-opentelemetry-operator
delete_namespace_safe openshift-opentelemetry-operator

log "Removing Tempo Operator..."
delete_csv_for_subscription tempo tempo-product
delete_and_wait operatorgroup tempo tempo
delete_namespace_safe tempo

log "Removing Perses dashboards and COO..."
delete_and_wait persesdashboard connectivity-link-overview kuadrant-system
delete_and_wait persesglobaldatasource thanos-querier-datasource
delete_and_wait uiplugin monitoring
delete_csv_for_subscription openshift-cluster-observability-operator cluster-observability-operator
delete_and_wait operatorgroup cluster-observability-operator openshift-cluster-observability-operator
delete_namespace_safe openshift-cluster-observability-operator

log "Reverting user workload monitoring..."
delete_and_wait configmap cluster-monitoring-config openshift-monitoring

log "Removing RateLimitPolicy..."
delete_and_wait ratelimitpolicy echo-rate-limit tutorial-app

log "Removing AuthPolicy..."
delete_and_wait authpolicy echo-auth tutorial-app

log "Removing Keycloak..."
delete_all_and_wait keycloakrealmimport tutorial-keycloak 120
delete_all_and_wait keycloak tutorial-keycloak 120
delete_csv_for_subscription tutorial-keycloak rhbk-operator
delete_and_wait operatorgroup keycloak-og tutorial-keycloak
delete_namespace_safe tutorial-keycloak

log "Removing TLSPolicy and TLS route..."
delete_and_wait tlspolicy api-gateway-tls openshift-ingress
delete_and_wait route api-gateway-tls openshift-ingress
delete_and_wait certificate api-gateway-https openshift-ingress
delete_and_wait secret api-gateway-tls openshift-ingress

log "Removing tutorial application..."
delete_namespace_safe tutorial-app

log "Removing Gateway and routes..."
delete_and_wait route api-gateway openshift-ingress
delete_and_wait gateway api-gateway openshift-ingress

log "Removing ClusterIssuer..."
delete_and_wait clusterissuer selfsigned-cluster-issuer

log "Removing Connectivity Link..."
delete_and_wait kuadrant kuadrant kuadrant-system 180
delete_csv_for_subscription kuadrant-system rhcl-operator
delete_and_wait operatorgroup kuadrant kuadrant-system
delete_namespace_safe kuadrant-system

echo ""
echo -e "${YELLOW}Cleanup complete.${NC}"
echo ""
echo "Note: The following were NOT removed:"
echo "  • OpenShift Data Foundation (ODF) — only the ObjectBucketClaim was deleted"
echo "  • cert-manager Operator for Red Hat OpenShift — only the ClusterIssuer was deleted"
echo "  • OpenShift cluster itself"
