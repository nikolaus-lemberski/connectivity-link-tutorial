# 09a — Metrics & Monitoring

**What you'll learn:** Enable metrics collection for Connectivity Link and your gateways using OpenShift user workload monitoring, so Prometheus scrapes metrics from Envoy, Authorino, Limitador, and Gateway API state.

**Prerequisites:** Phases 00–08 completed (Gateway with TLS, echo app, AuthPolicy, RateLimitPolicy all enforced).

## Overview

Connectivity Link exposes metrics from several sources:

- **Envoy** — request rate, latency, error codes, bytes in/out (standard Istio/Envoy metrics)
- **Authorino** — authentication and authorization decisions
- **Limitador** — rate limit counters and decisions
- **Gateway API state metrics** — resource status from a kube-state-metrics exporter deployed by the operator

When you enable observability in the Kuadrant CR, Connectivity Link creates `ServiceMonitor` and `PodMonitor` resources that tell Prometheus where to scrape these metrics.

```
┌─────────────────────────────────────────────────────────────────┐
│ OpenShift User Workload Monitoring                              │
│                                                                 │
│ ┌────────────┐  scrape  ┌────────────────────────────────────┐  │
│ │ Prometheus │◄─────────│ ServiceMonitor / PodMonitor        │  │
│ │   (UWM)    │          │ (created by Kuadrant operator)     │  │
│ └─────┬──────┘          └────────────────────────────────────┘  │
│       │                                                         │
│       │ federate                                                │
│       ▼                                                         │
│ ┌──────────────┐                                                │
│ │ Thanos       │  ◄── dashboards query here                     │
│ │ Querier      │                                                │
│ └──────────────┘                                                │
└─────────────────────────────────────────────────────────────────┘

Metrics sources:
  ┌─────────┐  ┌───────────┐  ┌───────────┐  ┌──────────────────┐
  │  Envoy  │  │ Authorino │  │ Limitador │  │ kube-state       │
  │ gateway │  │           │  │           │  │ metrics-kuadrant │
  └─────────┘  └───────────┘  └───────────┘  └──────────────────┘
```

This section (09a) covers enabling the metrics pipeline. Dashboards and tracing are covered in subsequent sections.

## Step 1: Enable User Workload Monitoring

OpenShift's built-in monitoring stack must be configured to scrape metrics from user workloads (namespaces outside `openshift-*`). This is done by setting `enableUserWorkload: true` in the `cluster-monitoring-config` ConfigMap.

Check whether it is already enabled:

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null
# If output contains "enableUserWorkload: true", skip to Step 2
```

If the ConfigMap does not exist or the setting is missing, apply it:

```bash
oc apply -f 09-observability/09a-metrics-monitoring/user-workload-monitoring.yaml
```

<details>
<summary>user-workload-monitoring.yaml</summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```
</details>

Wait for the user workload monitoring Prometheus pods to start (may take 30–60 seconds after the ConfigMap is applied). The pods don't exist yet immediately after applying the ConfigMap, so poll for them before waiting on their `Ready` condition:

```shell
until oc get pod -l app.kubernetes.io/name=prometheus -n openshift-user-workload-monitoring 2>/dev/null | grep -q prometheus; do sleep 5; done
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n openshift-user-workload-monitoring --timeout=180s
```

Verify the pods are running:

```bash
oc get pods -n openshift-user-workload-monitoring
# NAME                                   READY   STATUS    RESTARTS   AGE
# prometheus-user-workload-0             ...     Running   ...        ...
# prometheus-user-workload-1             ...     Running   ...        ...
# thanos-ruler-user-workload-0           ...     Running   ...        ...
```

## Step 2: Enable Observability in the Kuadrant CR

Update the Kuadrant CR to enable built-in observability. This tells the operator to create `ServiceMonitor` and `PodMonitor` resources for all Connectivity Link components and gateways.

```bash
oc apply -f 09-observability/09a-metrics-monitoring/kuadrant-observability.yaml
```

<details>
<summary>kuadrant-observability.yaml</summary>

```yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
  labels:
    app.kubernetes.io/part-of: connectivity-link-tutorial
spec:
  observability:
    enable: true
```
</details>

Wait for the Kuadrant resource to reconcile:

```bash
oc wait kuadrant/kuadrant --for="condition=Ready=true" -n kuadrant-system --timeout=120s
```

## Step 3: Verify ServiceMonitors and PodMonitors

Once observability is enabled, the Kuadrant operator creates monitoring resources labeled with `kuadrant.io/observability=true`:

```bash
oc get servicemonitor,podmonitor -A -l kuadrant.io/observability=true
```

You should see monitors in multiple namespaces:

- **`kuadrant-system`** — monitors for Authorino, Limitador, and the kube-state-metrics-kuadrant exporter
- **`openshift-ingress`** — monitors for the Envoy gateway pods
- **Gateway system namespace** (typically `istio-system` or similar) — monitors for Istio control-plane metrics

## Step 4: Verify Metrics Are Being Scraped

Confirm that Prometheus is collecting Connectivity Link metrics by querying the Thanos API. The Kuadrant Wasm shim exposes metrics like `kuadrant_hits` (total requests processed by the policy engine):

```bash
TOKEN=$(oc whoami -t)
THANOS_HOST=$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.status.ingress[0].host}')

curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/query?query=kuadrant_hits" | jq . | head -20
```

You should see results with labels pointing to the gateway pod in `openshift-ingress`.

> **Note:** Metrics may take 2–3 minutes to appear after enabling observability and generating traffic. The scrape interval is 30 seconds, and Thanos may take an additional cycle to make newly scraped metrics available. If the query returns empty results, wait a minute and try again.

You can also check Gateway API state metrics:

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/query?query=kube_customresource_gateway_info" | jq . | head -20
```

> **Tip:** If `kuadrant_hits` returns empty, generate some traffic first — send a few authenticated requests through the gateway as in sections 06 and 08. Metrics only appear after requests flow through the policy engine.

To see all available Connectivity Link metrics:

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/label/__name__/values" \
  | jq -r '.data[] | select(test("kuadrant|limitador|authorino|kube_customresource_gateway"; "i"))' \
  | sort
```

## What Metrics Are Available?

With observability enabled, the following metric families are scraped:

| Source | Example Metrics | Purpose |
|--------|----------------|---------|
| Kuadrant Wasm shim | `kuadrant_hits`, `kuadrant_allowed`, `kuadrant_denied`, `kuadrant_errors` | Policy engine decisions per request |
| Envoy / Istio | `istio_requests_total`, `istio_request_duration_milliseconds_bucket` | Request throughput, latency, error rates |
| Authorino | `auth_server_evaluator_*`, `auth_server_authconfig_*` | Auth decisions, latency per auth step |
| Limitador | `limitador_*` | Rate limit decisions, counter values |
| Gateway API state | `kube_customresource_gateway_info`, `kube_customresource_gateway_class_info` | Resource status and metadata |

These metrics form the foundation for the dashboards you will create in the next section.

## Verify

- [ ] `oc get configmap cluster-monitoring-config -n openshift-monitoring` exists with `enableUserWorkload: true`
- [ ] Prometheus pods are running in `openshift-user-workload-monitoring`
- [ ] `oc get kuadrant -n kuadrant-system` shows `Ready` with `spec.observability.enable: true`
- [ ] `oc get servicemonitor,podmonitor -A -l kuadrant.io/observability=true` shows monitors created
- [ ] Querying Thanos for `kuadrant_hits` or `kube_customresource_gateway_info` returns results

---

Next: [09b — Cluster Observability Operator & Perses Dashboards](../09b-dashboards/README.md)
