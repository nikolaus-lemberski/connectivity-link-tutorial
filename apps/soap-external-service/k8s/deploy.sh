#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for cmd in oc envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

echo "Creating namespace..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "Deploying application..."
oc apply -f "${SCRIPT_DIR}/deployment.yaml"

echo "Creating service..."
oc apply -f "${SCRIPT_DIR}/service.yaml"

echo "Resolving cluster domain..."
export CLUSTER_DOMAIN
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "Error: Could not resolve CLUSTER_DOMAIN." >&2
  exit 1
fi
echo "Using CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

echo "Creating HTTPRoute..."
envsubst < "${SCRIPT_DIR}/httproute.yaml" | oc apply -f -

echo "Exposing hostname via OpenShift Route (no cloud LoadBalancer on this cluster)..."
envsubst < "${SCRIPT_DIR}/route.yaml" | oc apply -f -

echo "Done."
