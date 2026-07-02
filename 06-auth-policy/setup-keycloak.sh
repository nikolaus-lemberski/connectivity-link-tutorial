#!/usr/bin/env bash
# Installs the Red Hat build of Keycloak with PostgreSQL, deploys a realm
# with an OIDC client and test user for the AuthPolicy tutorial.
#
# Manifests live in 06-auth-policy/keycloak/; this script automates their application.
# Usage: ./06-auth-policy/setup-keycloak.sh

set -euo pipefail
cd "$(dirname "$0")/.."

source export-cluster-env.sh

echo "==> Creating tutorial-keycloak namespace"
oc apply -f 06-auth-policy/keycloak/namespace.yaml

echo "==> Installing Red Hat build of Keycloak Operator (stable-v26.4)"
oc apply -f 06-auth-policy/keycloak/subscription.yaml

echo "==> Waiting for Keycloak Operator CSV to succeed"
oc wait csv -n tutorial-keycloak \
  -l operators.coreos.com/rhbk-operator.tutorial-keycloak \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s

echo "==> Deploying PostgreSQL for Keycloak"
export KEYCLOAK_DB_PASSWORD=$(openssl rand -base64 12)
envsubst < 06-auth-policy/keycloak/postgres.yaml | oc apply -f -

echo "==> Waiting for PostgreSQL rollout"
oc rollout status deployment/keycloak-pgsql -n tutorial-keycloak --timeout=120s

echo "==> Deploying Keycloak"
envsubst < 06-auth-policy/keycloak/keycloak.yaml | oc apply -f -

echo "==> Waiting for Keycloak service to appear"
until oc get svc tutorial-keycloak-service -n tutorial-keycloak >/dev/null 2>&1; do sleep 3; done

echo "==> Annotating service for TLS certificate"
oc annotate service tutorial-keycloak-service -n tutorial-keycloak \
  service.beta.openshift.io/serving-cert-secret-name=tutorial-keycloak-tls --overwrite

echo "==> Waiting for TLS secret"
until oc get secret tutorial-keycloak-tls -n tutorial-keycloak >/dev/null 2>&1; do sleep 3; done

echo "==> Waiting for Keycloak to become ready"
oc wait keycloak/tutorial-keycloak -n tutorial-keycloak \
  --for=condition=Ready --timeout=300s

echo "==> Importing tutorial realm (OIDC client + test user)"
oc apply -f 06-auth-policy/keycloak/keycloak-realm.yaml

echo "==> Waiting for realm import to complete"
oc wait keycloakrealmimport/connectivity-link-tutorial -n tutorial-keycloak \
  --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True \
  --timeout=180s

echo "==> Verifying OIDC token retrieval"
TOKEN=$(get_token)
if [ -n "$TOKEN" ]; then
  echo "Token retrieved successfully."
else
  echo "ERROR: Failed to retrieve token from Keycloak." >&2
  exit 1
fi

echo ""
echo "Keycloak is ready. OIDC discovery URL:"
echo "  https://keycloak.$CLUSTER_DOMAIN/realms/connectivity-link-tutorial"
