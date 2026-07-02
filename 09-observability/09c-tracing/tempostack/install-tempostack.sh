#!/usr/bin/env bash
# Install TempoStack with ODF/NooBaa object storage for the tracing tutorial.
# Usage: ./install-tempostack.sh
#
# Prerequisites:
#   - OpenShift cluster with ODF installed (NooBaa provides S3 storage)
#   - Logged in with oc (cluster-admin)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="tempo"

echo "==> Installing Tempo Operator"
oc apply -f "$SCRIPT_DIR/tempo-subscription.yaml"

echo "==> Waiting for Tempo Operator subscription"
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/tempo-product -n "$NAMESPACE" --timeout=180s

echo "==> Waiting for Tempo Operator CSV to succeed"
CSV=$(oc get subscription tempo-product -n "$NAMESPACE" -o jsonpath='{.status.installedCSV}')
oc wait csv/"$CSV" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s

echo "==> Provisioning object storage (ObjectBucketClaim)"
oc apply -f "$SCRIPT_DIR/tempo-bucket-claim.yaml"

oc wait --for=jsonpath='{.status.phase}'=Bound \
  objectbucketclaim/tempo-bucket -n "$NAMESPACE" --timeout=120s

echo "==> Creating TempoStack storage secret from OBC"
BUCKET_NAME=$(oc get configmap tempo-bucket -n "$NAMESPACE" -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get configmap tempo-bucket -n "$NAMESPACE" -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(oc get configmap tempo-bucket -n "$NAMESPACE" -o jsonpath='{.data.BUCKET_PORT}')
AWS_ACCESS_KEY_ID=$(oc get secret tempo-bucket -n "$NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(oc get secret tempo-bucket -n "$NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

oc create secret generic tempo-bucket-secret -n "$NAMESPACE" \
  --from-literal=endpoint="https://$BUCKET_HOST:$BUCKET_PORT" \
  --from-literal=bucket="$BUCKET_NAME" \
  --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=access_key_secret="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> Deploying TempoStack"
oc apply -f "$SCRIPT_DIR/tempo-stack.yaml"

echo "==> Waiting for TempoStack to become ready (up to 5 minutes)"
oc wait --for=condition=Ready tempostack/tempostack -n "$NAMESPACE" --timeout=300s

echo ""
echo "TempoStack is ready."
oc get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=tempostack
