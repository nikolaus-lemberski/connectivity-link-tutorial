#!/usr/bin/env bash
# Source this file to set common tutorial environment variables.
# Usage: source export-cluster-env.sh

export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export KEYCLOAK_HOST="keycloak.${CLUSTER_DOMAIN}"

echo "CLUSTER_DOMAIN=$CLUSTER_DOMAIN"
echo "KEYCLOAK_HOST=$KEYCLOAK_HOST"

get_token() {
  curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/connectivity-link-tutorial/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=tutorial-app" \
    -d "client_secret=tutorial-app-secret" \
    -d "username=testuser" \
    -d "password=testuser" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}
