# 09c — Tracing (Optional)

**What you'll learn:** Deploy distributed tracing for Connectivity Link using the Tempo Operator, an OpenTelemetry Collector, and the OpenShift Distributed Tracing console plugin for trace visualization.

**Prerequisites:** Section 09b completed (COO installed, Perses dashboards working). OpenShift Data Foundation (ODF) installed with NooBaa available for S3-compatible object storage.

## Overview

Distributed tracing lets you follow a single request as it flows through the gateway and policy enforcement components — Envoy, the wasm-shim module, Authorino (authentication), and Limitador (rate limiting). This is invaluable for debugging request-level issues and understanding policy enforcement timing.

```
                          ┌──────────────────────────────────────┐
                          │  Tempo Operator                      │
                          │                                      │
  ┌─────────┐  OTLP/gRPC  │  ┌──────────┐  OTLP/HTTP  ┌───────┐  │
  │ Envoy   │────────────►│  │  OTel    │────────────►│Tempo  │  │
  │ gateway │             │  │Collector │  (bearer    │Gateway│  │
  └─────────┘             │  │          │   token +   └───┬───┘  │
  ┌─────────┐             │  │          │   tenant)       │      │
  │Authorino│────────────►│  └──────────┘           ┌─────▼───┐  │
  └─────────┘             │                         │Distrib- │  │
  ┌─────────┐             │                         │  utor   │  │
  │Limitador│────────────►│                         └────┬────┘  │
  └─────────┘             │                         ┌────▼────┐  │
                          │                         │Ingester │  │
                          │                         └────┬────┘  │
                          │                         ┌────▼────┐  │
                          │                         │ODF/S3   │  │
                          │                         └─────────┘  │
                          └──────────────────────────────────────┘
                                        │
                                        ▼
                          ┌──────────────────────────────────────┐
                          │ OpenShift Console                    │
                          │ Observe → Traces (Distributed        │
                          │ Tracing UI Plugin)                   │
                          └──────────────────────────────────────┘
```

**Architecture highlights:**

- The TempoStack is deployed with **multi-tenancy** and a **gateway** for access control.
- An **OpenTelemetry Collector** acts as an intermediary — it authenticates with the Tempo gateway using a bearer token and forwards traces to the correct tenant.
- **Envoy proxy tracing** is configured via an `EnvoyFilter` that patches the Envoy HTTP Connection Manager directly. This is necessary because the `openshift-gateway` Istio CR is managed by the Cluster Ingress Operator and does not allow adding custom `extensionProviders`.
- **Kuadrant component tracing** (Authorino, Limitador, wasm-shim) is configured via the `Kuadrant` CR `spec.observability.tracing`.
- Traces are visualized through the **Distributed Tracing console plugin** (Observe → Traces in the OpenShift web console).

## Step 1: Install the Tempo Operator

Install the Tempo Operator via OLM. This provides the `TempoStack` CRD for deploying a complete tracing backend.

```bash
oc apply -f 09-observability/09c-tracing/tempo-subscription.yaml
```

Wait for the operator to install:

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/tempo-product -n tempo --timeout=180s
```

## Step 2: Install the Red Hat build of OpenTelemetry Operator

The OpenTelemetry Operator provides the `OpenTelemetryCollector` CRD. The collector is needed as an intermediary between Envoy/Kuadrant components and the multi-tenant Tempo gateway (it handles bearer token authentication and tenant routing).

```bash
oc apply -f 09-observability/09c-tracing/otel-subscription.yaml
```

Wait for the operator to install:

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/opentelemetry-product -n openshift-opentelemetry-operator --timeout=180s
```

## Step 3: Provision Object Storage for TempoStack

TempoStack requires S3-compatible object storage for trace data. Since ODF with NooBaa is available on this cluster, create an `ObjectBucketClaim` to provision a bucket automatically.

```bash
oc apply -f 09-observability/09c-tracing/tempo-bucket-claim.yaml
```

Wait for the bucket to be provisioned:

```bash
oc wait --for=jsonpath='{.status.phase}'=Bound \
  objectbucketclaim/tempo-bucket -n tempo --timeout=120s
```

## Step 4: Create the TempoStack Storage Secret

Extract values from the OBC-provisioned ConfigMap and Secret, then create the TempoStack storage secret:

```bash
BUCKET_NAME=$(oc get configmap tempo-bucket -n tempo -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get configmap tempo-bucket -n tempo -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(oc get configmap tempo-bucket -n tempo -o jsonpath='{.data.BUCKET_PORT}')
AWS_ACCESS_KEY_ID=$(oc get secret tempo-bucket -n tempo -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(oc get secret tempo-bucket -n tempo -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

oc create secret generic tempo-bucket-secret -n tempo \
  --from-literal=endpoint="https://${BUCKET_HOST}:${BUCKET_PORT}" \
  --from-literal=bucket="$BUCKET_NAME" \
  --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=access_key_secret="$AWS_SECRET_ACCESS_KEY"
```

## Step 5: Deploy TempoStack

Deploy a multi-tenant TempoStack with the gateway enabled and RBAC for trace read/write access.

```bash
oc apply -f 09-observability/09c-tracing/tempo-stack.yaml
```

Key configuration:

- `tenants.mode: openshift` — enables OpenShift OAuth authentication and SubjectAccessReview authorization
- `tenants.authentication` — defines a `dev` tenant for trace data
- `template.gateway.enabled: true` — deploys the Tempo gateway for multi-tenancy
- `template.queryFrontend.jaegerQuery.enabled: false` — Jaeger UI is disabled
- `ClusterRole/ClusterRoleBinding` for reading — grants all authenticated OpenShift users read access to traces
- `ClusterRole/ClusterRoleBinding` for writing — grants the OTel Collector's ServiceAccount write access

Wait for the TempoStack to become ready:

```bash
oc wait --for=condition=Ready tempostack/tempostack -n tempo --timeout=300s

oc get pods -n tempo -l app.kubernetes.io/instance=tempostack
```

## Step 6: Deploy the OpenTelemetry Collector

Deploy an OpenTelemetry Collector that receives OTLP traces and forwards them to the Tempo gateway with bearer token authentication and the correct tenant header.

```bash
oc apply -f 09-observability/09c-tracing/otel-collector.yaml
```

Key configuration:

- **Receives** OTLP gRPC on port 4317 — Envoy and Kuadrant components send traces here
- **Exports** via OTLP HTTP to the Tempo gateway on port 8080, with the tenant name (`dev`) in the URL path
- **Bearer token auth** — uses the ServiceAccount token to authenticate with the Tempo gateway
- **TLS** — trusts the OpenShift service CA to validate the gateway's certificate

Verify the collector is running:

```bash
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=otel-collector -n tempo --timeout=120s

oc logs -n tempo -l app.kubernetes.io/name=otel-collector --tail=5
# Should see: "Everything is ready. Begin running and processing data."
```

## Step 7: Configure Envoy Proxy Tracing

The `openshift-gateway` Istio CR is managed by the Cluster Ingress Operator, which prevents adding custom `extensionProviders` to the mesh config. To enable Envoy proxy tracing, we use an `EnvoyFilter` that directly patches the Envoy HTTP Connection Manager with an OpenTelemetry tracing configuration.

```bash
oc apply -f 09-observability/09c-tracing/envoy-tracing-filter.yaml
```

This EnvoyFilter:

- Targets the `api-gateway` workload via `workloadSelector`
- Configures the HTTP Connection Manager's tracing provider to use OpenTelemetry
- Points to the OTel Collector cluster at `otel-collector.tempo.svc.cluster.local:4317`
- Sets 100% sampling (adjust for production)

Verify the Envoy proxy picked up the tracing configuration:

```bash
GWPOD=$(oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=api-gateway -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-ingress $GWPOD -- pilot-agent request GET config_dump 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for config in data.get('configs', []):
    if 'ListenersConfigDump' in config.get('@type', ''):
        for ls in config.get('dynamic_listeners', []):
            for fc in ls.get('active_state', {}).get('listener', {}).get('filter_chains', []):
                for f in fc.get('filters', []):
                    tc = f.get('typed_config', {})
                    if 'tracing' in tc:
                        print('Tracing configured:', tc['tracing']['provider']['name'])
"
# Should output: Tracing configured: envoy.tracers.opentelemetry
```

## Step 8: Configure Data-Plane Tracing in the Kuadrant CR

Update the Kuadrant CR to enable tracing for the wasm-shim, Authorino, and Limitador. This sends traces from the Connectivity Link policy engine to the OTel Collector.

```bash
oc apply -f 09-observability/09c-tracing/kuadrant-tracing.yaml
```

Key configuration:

- `tracing.defaultEndpoint` — points to the OTel Collector using gRPC OTLP (`rpc://` prefix, port 4317)
- `dataPlane.httpHeaderIdentifier` — correlates traces across components using the `x-request-id` header that Envoy generates for each request

Wait for the Kuadrant CR to reconcile:

```bash
oc wait kuadrant/kuadrant --for="condition=Ready=true" -n kuadrant-system --timeout=120s
```

## Step 9: Enable the Distributed Tracing Console Plugin

The Distributed Tracing UI Plugin adds an **Observe → Traces** menu item to the OpenShift web console, providing full trace search and waterfall visualization powered by the TempoStack. Since we deployed a multi-tenant TempoStack with a gateway, the plugin auto-discovers it.

```bash
oc apply -f 09-observability/09c-tracing/tracing-ui-plugin.yaml
```

Wait for the plugin to become available:

```bash
oc wait uiplugin/distributed-tracing --for=condition=Available --timeout=120s

oc get consoleplugin distributed-tracing-console-plugin
```

> **Note:** You may need to refresh the OpenShift web console (or log out and back in) for the new **Observe → Traces** menu item to appear.

## Step 10: Verify Tracing End-to-End

### 10a: Generate Traffic

Send some requests through the gateway to generate traces:

```bash
for i in $(seq 1 5); do
  curl -sk -o /dev/null -w "Request $i: HTTP %{http_code}\n" \
    "https://echo.${CLUSTER_DOMAIN}/" \
    -H "x-request-id: smoke-test-$i"
  sleep 1
done
```

### 10b: Check Envoy Trace Delivery

Verify Envoy is sending traces to the OTel Collector by checking the Envoy cluster stats:

```bash
GWPOD=$(oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=api-gateway -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-ingress $GWPOD -- pilot-agent request GET clusters 2>/dev/null \
  | grep "otel-collector.tempo.svc.cluster.local.*rq_total"
# rq_total should be > 0
```

### 10c: View Traces in the OpenShift Console

1. Open the OpenShift web console
2. Navigate to **Observe → Traces**
3. Select the **dev** tenant and search for traces by service name or time range
4. You should see traces from these service names:
   - **envoy-gateway** — Envoy proxy processing
   - **authorino** — JWT authentication and authorization
   - **limitador** — rate limit checks
   - **wasm-shim** — the Connectivity Link wasm-shim policy engine

> **What to expect:** Most traces from `envoy-gateway`, `authorino`, and `limitador` will contain **a single span** each. This is normal — each component reports its operations independently with its own trace ID. The **wasm-shim** traces are the most informative: they contain **multiple spans** (typically 10+) showing the full Kuadrant policy evaluation pipeline — auth checks, rate-limit checks, and each step of the request processing. Focus on wasm-shim traces for the richest debugging insight.
>
> Fully correlated end-to-end traces (where a single trace links Envoy → wasm-shim → Authorino → Limitador) would require trace context propagation between all components, which is not configured out of the box.

### 10d: Correlate with Request IDs

The `httpHeaderIdentifier: x-request-id` in the Kuadrant CR ensures the `x-request-id` header appears in trace spans:

```bash
curl -sk -v "https://echo.${CLUSTER_DOMAIN}/" 2>&1 | grep x-request-id
# < x-request-id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

Use that request ID to search for the correlated trace.

## Understanding the Trace Data

Each component generates its own traces independently. Because trace context is not propagated between components, you will see **separate traces per component** rather than one unified trace per request.

| Service name | Typical spans per trace | What it shows |
|---|---|---|
| `envoy-gateway` | 1 | The HTTP request flowing through the Envoy proxy (timing, status code, headers) |
| `authorino` | 1 | A single authentication/authorization check |
| `limitador` | 1 | A single rate-limit evaluation |
| `wasm-shim` | 10+ | The full Kuadrant policy evaluation pipeline — this is the most valuable trace |

**The wasm-shim trace** is where you get the richest debugging insight. The wasm-shim runs as a Wasm filter inside Envoy and orchestrates the entire policy evaluation. Its trace spans show:

- **Duration** of each policy evaluation step
- **Calls to Authorino** for authentication/authorization
- **Calls to Limitador** for rate-limit checks
- **Success or failure** of each policy check
- **Request metadata** (path, method, response code)

**Correlating across components:** While traces are separate, you can correlate them using the `x-request-id` header. When you send a request, Envoy assigns an `x-request-id` that is passed to all Kuadrant components. Search for this value in the trace attributes to find all related spans across services.

## Verify

- [ ] `oc get csv -n tempo` shows Tempo Operator with `Succeeded`
- [ ] `oc get csv -n openshift-opentelemetry-operator` shows OpenTelemetry Operator with `Succeeded`
- [ ] `oc get objectbucketclaim tempo-bucket -n tempo` shows `Bound`
- [ ] `oc get pods -n tempo -l app.kubernetes.io/instance=tempostack` shows all components Running (including `gateway`)
- [ ] `oc get pods -n tempo -l app.kubernetes.io/name=otel-collector` shows Running
- [ ] `oc get envoyfilter otel-tracing -n openshift-ingress` exists
- [ ] `oc get kuadrant -n kuadrant-system` shows `Ready` with tracing configured
- [ ] `oc get uiplugin distributed-tracing` shows `Available`
- [ ] Envoy cluster stats show `rq_total > 0` for the OTel Collector cluster
- [ ] Traces from `envoy-gateway`, `authorino`, `limitador`, and `wasm-shim` are visible in **Observe → Traces**

---

Previous: [09b — Cluster Observability Operator & Perses Dashboards](../09b-dashboards/README.md)
Next: [10 — Cleanup](../../10-cleanup/README.md)
