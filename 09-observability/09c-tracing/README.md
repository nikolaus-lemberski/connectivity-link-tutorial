# 09c — Tracing (Optional)

**What you'll learn:** Deploy distributed tracing for Connectivity Link using the Tempo Operator, an OpenTelemetry Collector, and the OpenShift Distributed Tracing console plugin for trace visualization.

**Prerequisites:** Section 09b completed (COO installed, Perses dashboards working). OpenShift Data Foundation (ODF) installed with NooBaa available for S3-compatible object storage.

## How to use this section

This section has two tracks so you can get a working demo quickly, then add deeper policy tracing.

- **Track A (Minimal, recommended first):** Get end-to-end correlated traces from `envoy-gateway` to `echo`.
- **Track B (Advanced):** Add Kuadrant component traces (`wasm-shim`, `authorino`, `limitador`) and cross-component correlation via `x-request-id`.

**Minimal success criterion (Track A):** In **Observe -> Traces**, you can find a trace with:

- root span service: `envoy-gateway`
- child span service: `echo` (`GET /`)
- HTTP responses from `https://echo.$CLUSTER_DOMAIN/` are `200`

## Overview

Distributed tracing lets you follow a single request as it flows through the gateway, policy enforcement components, and into your application. By instrumenting the echo service with an OpenTelemetry sidecar collector and auto-instrumentation, we get correlated end-to-end traces from Envoy through the application — not just isolated spans from each component.

```
                          ┌──────────────────────────────────────┐
                          │  Tempo Operator                      │
                          │                                      │
  ┌─────────┐  OTLP/gRPC  │  ┌──────────┐  OTLP/HTTP  ┌───────┐  │
  │ Envoy   │────────────►│  │  OTel    │────────────►│Tempo  │  │
  │ gateway │             │  │Collector │  (bearer    │Gateway│  │
  └────┬────┘             │  │ (central)│   token +   └───┬───┘  │
       │ traceparent      │  │          │   tenant)       │      │
  ┌────▼────────────────┐ │  └─────▲────┘           ┌─────▼───┐  │
  │ Echo Pod            │ │        │                │Distrib- │  │
  │ ┌───────┐ ┌───────┐ │ │        │                │  utor   │  │
  │ │ echo  │►│ OTel  │ │─┼────────┘                └────┬────┘  │
  │ │  app  │ │sidecar│ │ │  OTLP/gRPC              ┌────▼────┐  │
  │ └───────┘ └───────┘ │ │                         │Ingester │  │
  └─────────────────────┘ │                         └────┬────┘  │
  ┌─────────┐             │                         ┌────▼────┐  │
  │Authorino│────────────►│                         │ODF/S3   │  │
  └─────────┘             │                         └─────────┘  │
  ┌─────────┐             │                                      │
  │Limitador│────────────►│                                      │
  └─────────┘             └──────────────────────────────────────┘
                                        │
                                        ▼
                          ┌──────────────────────────────────────┐
                          │ OpenShift Console                    │
                          │ Observe → Traces (Distributed        │
                          │ Tracing UI Plugin)                   │
                          └──────────────────────────────────────┘
```

**Architecture highlights (short):**

- The TempoStack is deployed with **multi-tenancy** and a **gateway** for access control.
- A **central OpenTelemetry Collector** acts as an intermediary — it authenticates with the Tempo gateway using a bearer token and forwards traces to the correct tenant.
- **Envoy proxy tracing** is configured via an `EnvoyFilter` that patches the Envoy HTTP Connection Manager directly. This is necessary because the `openshift-gateway` Istio CR is managed by the Cluster Ingress Operator and does not allow adding custom `extensionProviders`.
- **Kuadrant component tracing** (Authorino, Limitador, wasm-shim) is configured via the `Kuadrant` CR `spec.observability.tracing` (advanced track).
- **Echo service tracing** uses an OTel Collector **sidecar** injected into the echo pod, combined with Python **auto-instrumentation** via the `Instrumentation` CR. The sidecar forwards traces to the central collector. Because Envoy propagates the `traceparent` header to the echo service, the echo spans are correlated with the Envoy spans in a single trace.
- Traces are visualized through the **Distributed Tracing console plugin** (Observe → Traces in the OpenShift web console).



## Step 1 (Required - Track A): Install the Tempo Operator

Install the Tempo Operator via OLM. This provides the `TempoStack` CRD for deploying a complete tracing backend.

```bash
oc apply -f 09-observability/09c-tracing/tempo-subscription.yaml
```

Wait for the operator to install:

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/tempo-product -n tempo --timeout=180s
```



## Step 2 (Required - Track A): Install the Red Hat build of OpenTelemetry Operator

The OpenTelemetry Operator provides the `OpenTelemetryCollector` CRD. The collector is needed as an intermediary between Envoy/Kuadrant components and the multi-tenant Tempo gateway (it handles bearer token authentication and tenant routing).

```bash
oc apply -f 09-observability/09c-tracing/otel-subscription.yaml
```

Wait for the operator to install:

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/opentelemetry-product -n openshift-opentelemetry-operator --timeout=180s
```



## Step 3 (Required - Track A): Provision Object Storage for TempoStack

TempoStack requires S3-compatible object storage for trace data. Since ODF with NooBaa is available on this cluster, create an `ObjectBucketClaim` to provision a bucket automatically.

```bash
oc apply -f 09-observability/09c-tracing/tempo-bucket-claim.yaml
```

Wait for the bucket to be provisioned:

```bash
oc wait --for=jsonpath='{.status.phase}'=Bound \
  objectbucketclaim/tempo-bucket -n tempo --timeout=120s
```



## Step 4 (Required - Track A): Create the TempoStack Storage Secret

Extract values from the OBC-provisioned ConfigMap and Secret, then create the TempoStack storage secret:

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



## Step 5 (Required - Track A): Deploy TempoStack

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



## Step 6 (Required - Track A): Deploy the OpenTelemetry Collector

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



## Step 7 (Required - Track A): Configure Envoy Proxy Tracing

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



## Step 8 (Optional - Track B): Configure Data-Plane Tracing in the Kuadrant CR

Update the Kuadrant CR to enable tracing for the wasm-shim, Authorino, and Limitador. This sends traces from the Connectivity Link policy engine to the OTel Collector.

> Skip this step if you only want the minimal gateway-to-app tracing demo.

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



## Step 9 (Required - Track A): Instrument the Echo Service

The echo service is a Python ASGI application. We combine three mechanisms to get correlated end-to-end traces:

1. **Sidecar collector** — an OTel Collector injected into the echo pod that receives traces on `localhost` and forwards them to the central collector.
2. **Auto-instrumentation** — the OTel Operator injects the OpenTelemetry Python SDK into the echo container via an init container.
3. **ASGI middleware** — a small code addition in `main.py` wraps the raw ASGI app with `OpenTelemetryMiddleware`, which creates spans for each HTTP request and reads the `traceparent` header propagated by Envoy.



### 9a: Prepare the echo service code

The auto-instrumentation injects the OTel Python SDK at runtime, but it cannot automatically wrap a raw ASGI function. The echo service's `main.py` includes a `try/except` block that applies the middleware when the SDK is available:

```python
try:
    from opentelemetry.instrumentation.asgi import OpenTelemetryMiddleware
    app = OpenTelemetryMiddleware(app, exclude_spans=["send", "receive"])
except ImportError:
    pass
```

The `exclude_spans=["send", "receive"]` option suppresses the low-level ASGI `http send`/`http receive` sub-spans that the middleware creates by default — without it, each request would generate 3 echo spans instead of 1 clean `GET /` span. When running without auto-instrumentation, the import fails gracefully and the app runs unmodified.

### 9b: Deploy the sidecar collector and instrumentation CRs

```bash
oc apply -f 09-observability/09c-tracing/otel-sidecar.yaml
oc apply -f 09-observability/09c-tracing/otel-instrumentation.yaml
```

Key details:

- The sidecar listens on both **gRPC (4317)** and **HTTP (4318)**. The Python auto-instrumentation uses the `http/protobuf` protocol by default, so it sends to the HTTP receiver on port 4318.
- The `Instrumentation` CR sets `exporter.endpoint: http://localhost:4318` and `propagators: [tracecontext, baggage]` — the `tracecontext` propagator reads `traceparent` headers from incoming requests, linking echo spans to Envoy parent spans.
- The `Instrumentation` CR disables **metrics and logs** export (`OTEL_METRICS_EXPORTER=none`, `OTEL_LOGS_EXPORTER=none`) because the sidecar collector only has a traces pipeline.



### 9c: Apply the echo deployment

The echo deployment in `04-app/deployment.yaml` includes the required annotations on the pod template:

- `sidecar.opentelemetry.io/inject: "true"` — triggers sidecar collector injection
- `instrumentation.opentelemetry.io/inject-python: "true"` — triggers Python auto-instrumentation

Apply (or re-apply) the deployment:

```bash
oc apply -f 04-app/deployment.yaml
oc rollout status deployment/echo -n tutorial-app --timeout=120s
```



### 9d: Verify the echo pod

The echo pod should now have the sidecar collector as a native sidecar (init container with `restartPolicy: Always`) and the auto-instrumentation init container:

```bash
oc get pod -n tutorial-app -l app=echo
# Should show 2/2 Running

oc get pod -n tutorial-app -l app=echo \
  -o jsonpath='{range .items[0].spec.initContainers[*]}{.name}{"\n"}{end}'
# Should show:
#   otc-container
#   opentelemetry-auto-instrumentation-python
```

> **Why a sidecar?** The sidecar collector runs on `localhost` inside the pod, so the auto-instrumented app can export traces without network overhead. The sidecar then forwards to the central collector which handles authentication and tenant routing to the TempoStack gateway.



## Step 10 (Required - Track A): Enable the Distributed Tracing Console Plugin

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



## Step 11: Verify Tracing End-to-End

### 11.0: Quick verification path (Track A)

If you only need a quick demonstration, do these in order:

1. **11a** Generate traffic
2. **11b** Confirm Envoy is exporting traces
3. **11c** Open **Observe -> Traces** and confirm one correlated `envoy-gateway -> echo` trace

Then stop here. Use **11d** only when you need deeper cross-component correlation.



### 11a: Generate Traffic

Obtain a token from Keycloak (AuthPolicy requires JWT authentication) and send requests through the gateway:

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export KEYCLOAK_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')

TOKEN=$(curl -sk -X POST "https://$KEYCLOAK_HOST/realms/connectivity-link-tutorial/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=tutorial-app&client_secret=tutorial-app-secret&username=testuser&password=testuser" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

for i in $(seq 1 5); do
  curl -sk -o /dev/null -w "Request $i: HTTP %{http_code}\n" \
    "https://echo.$CLUSTER_DOMAIN/" \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-request-id: smoke-test-$i"
  sleep 1
done
```

> **Note:** Tokens expire after 5 minutes. Re-run the token request if you get HTTP 401 responses.



### 11b: Check Envoy Trace Delivery

Verify Envoy is sending traces to the OTel Collector by checking the Envoy cluster stats:

```bash
GWPOD=$(oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=api-gateway -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-ingress $GWPOD -- pilot-agent request GET clusters 2>/dev/null \
  | grep "otel-collector.tempo.svc.cluster.local.*rq_total"
# rq_total should be > 0
```



### 11c: View Traces in the OpenShift Console

1. Open the OpenShift web console
2. Navigate to **Observe → Traces**
3. Select the **dev** tenant and search for traces by service name or time range
4. You should see traces from these service names:
  - **envoy-gateway** — Envoy proxy processing
  - **echo** — the echo application (auto-instrumented Python)
  - **authorino** — JWT authentication and authorization
  - **limitador** — rate limit checks
  - **wasm-shim** — the Connectivity Link wasm-shim policy engine

> **What to expect:** The `envoy-gateway` and `echo` traces are **correlated** — because Envoy propagates the `traceparent` header to the echo service, the echo span appears as a child of the Envoy span in a single trace. A typical correlated trace has **2 spans**: 1 envoy-gateway root span → 1 echo `GET /` child span. In the Distributed Tracing UI, look for traces with `rootServiceName=envoy-gateway` — when you expand them, you'll see the echo child span in the waterfall view. (The `exclude_spans=["send", "receive"]` option in `OpenTelemetryMiddleware` suppresses the noisy ASGI `http send`/`http receive` sub-spans.)
>
> Traces from `authorino` and `limitador` still contain **a single span** each, as these components report independently. The **wasm-shim** traces remain the most informative with **10+ spans** showing the full Kuadrant policy evaluation pipeline.



### 11d (Optional - Track B): Correlate with Request IDs

The `httpHeaderIdentifier: x-request-id` in the Kuadrant CR ensures the `x-request-id` header appears in trace spans:

```bash
curl -sk -v "https://echo.$CLUSTER_DOMAIN/" \
  -H "Authorization: Bearer $TOKEN" 2>&1 | grep x-request-id
# < x-request-id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

Use that request ID to search for the correlated trace.

## Understanding the Trace Data

With the echo service instrumented via auto-instrumentation and sidecar, you now get **correlated traces** between Envoy and the echo application. Other components still report independently.


| Service name             | Typical spans per trace | What it shows                                                                                                                                                         |
| ------------------------ | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `envoy-gateway` + `echo` | 2 (correlated)          | End-to-end: 1 Envoy root span → 1 echo `GET /` child span. Envoy propagates `traceparent` to the echo service, so both spans appear in a single trace. |
| `authorino`              | 1                       | A single authentication/authorization check (Track B)                                                                                                                  |
| `limitador`              | 1                       | A single rate-limit evaluation (Track B)                                                                                                                               |
| `wasm-shim`              | 10+                     | The full Kuadrant policy evaluation pipeline (Track B)                                                                                                                 |


**Correlated Envoy + echo traces** show the full request lifecycle: how long the request spent in the Envoy proxy vs. how long the application took to process it. This is the key benefit of instrumenting the echo service.

**The wasm-shim trace** is where you get the richest policy debugging insight. The wasm-shim runs as a Wasm filter inside Envoy and orchestrates the entire policy evaluation. Its trace spans show:

- **Duration** of each policy evaluation step
- **Calls to Authorino** for authentication/authorization
- **Calls to Limitador** for rate-limit checks
- **Success or failure** of each policy check
- **Request metadata** (path, method, response code)

**Correlating across components (Track B):** While `authorino` and `limitador` traces are separate, you can correlate them using the `x-request-id` header. When you send a request, Envoy assigns an `x-request-id` that is passed to all Kuadrant components. Search for this value in the trace attributes to find all related spans across services.

## Troubleshooting (Quick Matrix)

| Symptom | Likely cause | What to check |
| ------- | ------------ | ------------- |
| No **Observe -> Traces** menu item | UI plugin not available yet / stale browser session | `oc get uiplugin distributed-tracing`; refresh console or log out/in |
| `curl` to echo returns `401` | Missing or expired token | Re-run token request in 11a; token lifetime is short |
| Traces exist but no `echo` spans | Echo instrumentation not active | Echo pod annotations in `04-app/deployment.yaml`; `otc-container` and `opentelemetry-auto-instrumentation-python` init/sidecar presence |
| `envoy-gateway` trace exists but not correlated with `echo` | Missing/incorrect trace context propagation or outdated echo image | Confirm echo uses middleware with `OpenTelemetryMiddleware`; re-rollout deployment if needed |
| No new traces from gateway | Envoy not exporting to collector | `pilot-agent request GET clusters` check in 11b (`rq_total > 0`) |
| No Track B service traces (`wasm-shim`/`authorino`/`limitador`) | Kuadrant tracing not configured | Apply/check `09-observability/09c-tracing/kuadrant-tracing.yaml` and Kuadrant `Ready` condition |

## Verify

- [ ] `oc get csv -n tempo` shows Tempo Operator with `Succeeded`
- [ ] `oc get csv -n openshift-opentelemetry-operator` shows OpenTelemetry Operator with `Succeeded`
- [ ] `oc get objectbucketclaim tempo-bucket -n tempo` shows `Bound`
- [ ] `oc get pods -n tempo -l app.kubernetes.io/instance=tempostack` shows all components Running (including `gateway`)
- [ ] `oc get pods -n tempo -l app.kubernetes.io/name=otel-collector` shows Running
- [ ] `oc get envoyfilter otel-tracing -n openshift-ingress` exists
- [ ] `oc get kuadrant -n kuadrant-system` shows `Ready` with tracing configured
- [ ] `oc get otelinst echo-instrumentation -n tutorial-app` exists
- [ ] Echo pod has a sidecar container: `oc get pod -n tutorial-app -l app=echo -o jsonpath='{.items[0].spec.containers[*].name}'` includes `otc-container`
- [ ] `oc get uiplugin distributed-tracing` shows `Available`
- [ ] Envoy cluster stats show `rq_total > 0` for the OTel Collector cluster
- [ ] Traces from `envoy-gateway`, `echo`, `authorino`, `limitador`, and `wasm-shim` are visible in **Observe → Traces**
- [ ] `envoy-gateway` and `echo` traces are correlated (appear in the same trace with parent-child relationship)

---

## Appendix: Why these components exist

- **Central OTel Collector:** Needed because TempoStack is multi-tenant behind a gateway; the collector handles auth and tenant routing.
- **EnvoyFilter tracing patch:** Required because the managed gateway setup does not allow custom mesh `extensionProviders`.
- **Echo sidecar collector + Python auto-instrumentation:** Gives app spans without building collector/auth logic into the app itself.
- **Distributed Tracing UI plugin:** Native OpenShift trace search and waterfall view without relying on Jaeger UI.
- **Kuadrant tracing (Track B):** Adds policy-engine visibility for debugging real API protection flows, beyond simple gateway-to-app latency.

---

Previous: [09b — Cluster Observability Operator & Perses Dashboards](../09b-dashboards/README.md)
Next: [09d — Access Logs](../09d-access-logs/README.md)
