# TempoStack Installation

**What you'll do:** Deploy the Tempo Operator and a TempoStack instance backed by S3-compatible object storage.

> **Important — Object Storage Required**
>
> TempoStack needs S3-compatible object storage to persist trace data.
> This tutorial assumes **OpenShift Data Foundation (ODF)** is installed, which provides NooBaa as an S3 backend.
>
> If ODF is **not** available on your cluster you have two options:
>
> 1. **Skip this section** — the rest of the tracing tutorial will not work, but all other tutorial sections are unaffected.
> 2. **Deploy an alternative S3-compatible datastore** such as [MinIO](https://min.io/) or [SeaweedFS](https://seaweedfs.github.io/). You will need to create the `tempo-bucket-secret` manually with the appropriate `endpoint`, `bucket`, `access_key_id`, and `access_key_secret` values, then skip straight to the TempoStack deployment step below.

## Quick Install (Script)

The install script automates all the steps below (Tempo Operator, object storage, secret, TempoStack):

```bash
./09-observability/09c-tracing/tempostack/install-tempostack.sh
```

If you prefer to run each step manually, follow the sections below.

## Manual Install

### 1. Install the Tempo Operator

```bash
oc apply -f 09-observability/09c-tracing/tempostack/tempo-subscription.yaml
```

Wait for the operator:

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/tempo-product -n tempo --timeout=180s
```

### 2. Provision Object Storage

Create an `ObjectBucketClaim` to provision a NooBaa bucket:

```bash
oc apply -f 09-observability/09c-tracing/tempostack/tempo-bucket-claim.yaml
```

Wait for the bucket to be provisioned:

```bash
oc wait --for=jsonpath='{.status.phase}'=Bound \
  objectbucketclaim/tempo-bucket -n tempo --timeout=120s
```

### 3. Create the TempoStack Storage Secret

Extract the OBC-provisioned credentials and create the secret that TempoStack expects:

```bash
BUCKET_NAME=$(oc get configmap tempo-bucket -n tempo -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get configmap tempo-bucket -n tempo -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(oc get configmap tempo-bucket -n tempo -o jsonpath='{.data.BUCKET_PORT}')
AWS_ACCESS_KEY_ID=$(oc get secret tempo-bucket -n tempo -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(oc get secret tempo-bucket -n tempo -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

oc create secret generic tempo-bucket-secret -n tempo \
  --from-literal=endpoint="https://$BUCKET_HOST:$BUCKET_PORT" \
  --from-literal=bucket="$BUCKET_NAME" \
  --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=access_key_secret="$AWS_SECRET_ACCESS_KEY"
```

### 4. Deploy TempoStack

```bash
oc apply -f 09-observability/09c-tracing/tempostack/tempo-stack.yaml
```

Key configuration:

- `tenants.mode: openshift` — enables OpenShift OAuth authentication and SubjectAccessReview authorization
- `tenants.authentication` — defines a `dev` tenant for trace data
- `template.gateway.enabled: true` — deploys the Tempo gateway for multi-tenancy
- `ClusterRole/ClusterRoleBinding` — grants authenticated users read access and the OTel Collector write access

Wait for the TempoStack to become ready:

```bash
oc wait --for=condition=Ready tempostack/tempostack -n tempo --timeout=300s

oc get pods -n tempo -l app.kubernetes.io/instance=tempostack
```

## Verify

- [ ] `oc get csv -n tempo` shows Tempo Operator with `Succeeded`
- [ ] `oc get objectbucketclaim tempo-bucket -n tempo` shows `Bound`
- [ ] `oc get pods -n tempo -l app.kubernetes.io/instance=tempostack` shows all components Running (including `gateway`)

---

Back to [09c — Tracing](../README.md)
