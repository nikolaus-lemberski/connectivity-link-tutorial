# 09d — Access Logs

**What you'll learn:** Understand Envoy gateway access logs, make logging explicit and controllable via the Istio Telemetry API, and correlate access logs with distributed traces and metrics using `x-request-id`.

**Prerequisites:** Section 09c completed (tracing configured, Distributed Tracing UI Plugin working).

## Overview

Every request that flows through the Envoy gateway produces an **access log entry** written to stdout. These logs contain the request method, path, response code, timing, upstream host, and — critically — the `x-request-id` header that ties a log line to a distributed trace and to Kuadrant component logs.

Access logs are the quickest way to answer "what happened to this request?" — and when combined with traces and metrics, they give you the full picture from a single request ID.

```
Access Log (stdout)              Distributed Trace              Metrics
┌─────────────────────┐          ┌──────────────────┐          ┌──────────────────┐
│ x-request-id: abc   │          │ x-request-id:abc │          │ istio_requests   │
│ response_code: 429  │◄────────►│ envoy-gateway    │◄────────►│   _total{        │
│ duration: 4ms       │          │   └─ echo GET /  │          │     code="429"}  │
│ route: tutorial-app │          └──────────────────┘          └──────────────────┘
└─────────────────────┘
         correlate via x-request-id and time window
```

## Step 1: Understand the Access Log Format

Envoy emits access logs in the default Istio text format. View the current gateway logs:

```bash
GWPOD=$(oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=api-gateway -o jsonpath='{.items[0].metadata.name}')
oc logs -n openshift-ingress $GWPOD --tail=5
```

Each log line follows this format:

```
[TIMESTAMP] "METHOD PATH PROTOCOL" RESPONSE_CODE RESPONSE_FLAGS BYTES_RECV BYTES_SENT DURATION UPSTREAM_SVC_TIME "X_FORWARDED_FOR" "USER_AGENT" "X_REQUEST_ID" "AUTHORITY" "UPSTREAM_HOST" ...
```

Here is an annotated example:

```
[2026-06-30T08:21:11.477Z] "GET / HTTP/2" 429 - - "-" 0 18 4 - "10.232.0.2" "curl/8.7.1" "d7da4681-4655-917b-b818-96daac0ec7c3" "echo.apps.example.com" "-" outbound|80||echo.tutorial-app.svc.cluster.local - 10.232.1.10:443 10.232.0.2:49104 echo.apps.example.com tutorial-app.echo.0
```

| Field | Value | Meaning |
| ----- | ----- | ------- |
| Timestamp | `2026-06-30T08:21:11.477Z` | When the request was received |
| Method / Path / Protocol | `GET / HTTP/2` | The HTTP request line |
| Response code | `429` | HTTP status returned to the client |
| Response flags | `-` | Envoy response flags (e.g. `UH` = no healthy upstream) |
| Duration (ms) | `4` | Total request processing time |
| X-Request-ID | `d7da4681-...` | Unique request identifier for correlation |
| Authority | `echo.apps.example.com` | The `Host` header / SNI |
| Upstream host | `outbound\|80\|\|echo.tutorial-app.svc.cluster.local` | Where Envoy forwarded the request |
| Route name | `tutorial-app.echo.0` | The HTTPRoute that matched |



## Step 2: Apply the Telemetry CR

While access logging is active by default, applying a Telemetry CR makes it **explicit and controllable** — you can later add CEL filter expressions to log only errors, exclude health checks, or target specific workloads.

```bash
oc apply -f 09-observability/09d-access-logs/access-log-telemetry.yaml
```

This Telemetry CR:

- Uses the built-in `envoy` access log provider (writes to stdout)
- Targets the `api-gateway` workload via `selector.matchLabels`
- Outputs the standard Envoy text format (no Istio CR modification needed)

Verify the resource was created:

```bash
oc get telemetry -n openshift-ingress
# NAME                       AGE
# api-gateway-access-logs    ...
```

> **Production tips:** You can add CEL filter expressions to reduce log volume. Examples from the [Red Hat Connectivity Link docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability/rhcl-observability#configuring-access-logs_rhcl-observability):
>
> - **Errors only:** `filter: { expression: "response.code >= 400" }`
> - **Exclude health checks:** `filter: { expression: '!request.url_path.startsWith("/healthz")' }`
> - **Specific routes only:** `filter: { expression: 'request.url_path.startsWith("/api/")' }`



## Step 3: Generate Traffic Scenarios

Send three types of requests and **capture the `x-request-id` from each response**. Envoy generates a unique `x-request-id` for every external request — even if you send one in the request, Envoy replaces it with its own UUID. The ID returned in the response header is the one that appears in logs and traces.

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export KEYCLOAK_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')

TOKEN=$(curl -sk -X POST "https://$KEYCLOAK_HOST/realms/connectivity-link-tutorial/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=tutorial-app&client_secret=tutorial-app-secret&username=testuser&password=testuser" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

**Scenario 1 — Successful request (expect 200):**

```bash
curl -sk -w "\nHTTP %{http_code}\n" -D - -o /dev/null \
  "https://echo.$CLUSTER_DOMAIN/" \
  -H "Authorization: Bearer $TOKEN" 2>&1 | grep -i "x-request-id\|HTTP"
```

Note the `x-request-id` value from the response headers — you will use it in Step 4.

**Scenario 2 — Auth-denied request (expect 401):**

```bash
curl -sk -w "\nHTTP %{http_code}\n" -D - -o /dev/null \
  "https://echo.$CLUSTER_DOMAIN/" 2>&1 | grep -i "x-request-id\|HTTP"
```

**Scenario 3 — Rate-limited request (expect 429):**

```bash
for i in $(seq 1 10); do
  curl -sk -w "  HTTP %{http_code}\n" -D - -o /dev/null \
    "https://echo.$CLUSTER_DOMAIN/" \
    -H "Authorization: Bearer $TOKEN" 2>&1 | grep -i "x-request-id\|HTTP"
  echo "---"
done
```

Some of the later requests should return `429` once the rate limit is exceeded. Note one of the `x-request-id` values from a `429` response.

> **Why does Envoy replace `x-request-id`?** For external (ingress) requests, Envoy generates a fresh UUID to prevent clients from injecting arbitrary IDs. Inside the mesh, Envoy preserves and propagates the ID to upstream services. This is the ID that appears in access logs, traces, and Kuadrant component logs.



## Step 4: Read and Parse Access Logs

Use the `x-request-id` values you captured from the response headers in Step 3 to find each request in the gateway logs. Replace the example UUIDs below with your actual values:

```bash
GWPOD=$(oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=api-gateway -o jsonpath='{.items[0].metadata.name}')

# Replace these with the x-request-id values from Step 3
oc logs -n openshift-ingress $GWPOD | grep "<your-200-request-id>"
oc logs -n openshift-ingress $GWPOD | grep "<your-401-request-id>"
oc logs -n openshift-ingress $GWPOD | grep "<your-429-request-id>"
```

Alternatively, search by response code to see all recent requests of each type:

```bash
oc logs -n openshift-ingress $GWPOD --tail=50 | grep '" 200 '
oc logs -n openshift-ingress $GWPOD --tail=50 | grep '" 401 '
oc logs -n openshift-ingress $GWPOD --tail=50 | grep '" 429 '
```

You should see:

- **200 entries** — `via_upstream` in response flags, upstream host pointing to `echo.tutorial-app.svc.cluster.local`
- **401 entries** — upstream host `-` (request rejected by AuthPolicy before forwarding)
- **429 entries** — upstream host `-` (request rejected by RateLimitPolicy before forwarding)

> **Tip:** The `RESPONSE_FLAGS` field provides additional context. Common flags include:
> - `-` — normal response
> - `via_upstream` — response came from the upstream service
> - `UAEX` — unauthorized external service (auth failure)



## Step 5: Correlate Logs, Traces, and Metrics

This is the payoff — using `x-request-id` to follow a single request across all three observability pillars.

### 5a: Access log → Trace

Pick the `x-request-id` from a successful (200) request in Step 3 and find it in the Distributed Tracing UI:

1. Open the OpenShift web console → **Observe → Traces**
2. Select the **dev** tenant
3. Search for traces by time range matching your request
4. Look for a trace with root service `envoy-gateway` — expand it to see the `echo GET /` child span
5. In the span attributes, confirm the `x-request-id` matches the value from the access log

The access log told you the response code and timing. The trace shows you where the time was spent (Envoy processing vs. application processing).

### 5b: Access log → Metrics

Metrics provide the aggregate view. Query Thanos to see request counts by response code:

```bash
TOKEN_OC=$(oc whoami -t)
THANOS_HOST=$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.status.ingress[0].host}')

curl -sk -H "Authorization: Bearer $TOKEN_OC" \
  "https://$THANOS_HOST/api/v1/query" \
  --data-urlencode 'query=sum by (response_code) (increase(istio_requests_total{destination_service="echo.tutorial-app.svc.cluster.local"}[5m]))' \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('data', {}).get('result', []):
    code = r['metric'].get('response_code', '?')
    val = r['value'][1]
    print(f'  HTTP {code}: {val} requests')
"
```

You should see counts for `200`, `401`, and `429` — matching the three scenarios you generated.

### 5c: Putting it together

For a single request, you now have:

| Pillar | What it tells you | How to find it |
| ------ | ----------------- | -------------- |
| **Access log** | Response code, duration, route, upstream host | `oc logs ... \| grep <x-request-id>` |
| **Trace** | Span-level timing: Envoy → echo, with parent-child relationship | Observe → Traces, search by time range and service name |
| **Metrics** | Aggregate request counts, error rates, latency percentiles | Thanos query on `istio_requests_total` or `kuadrant_hits` |

This is the standard observability correlation pattern: **logs** give you the individual request detail, **traces** show the request flow and timing breakdown, and **metrics** reveal the overall trends and health.

## Verify

- [ ] `oc get telemetry api-gateway-access-logs -n openshift-ingress` exists
- [ ] Access logs visible: `oc logs -n openshift-ingress <GWPOD> --tail=5` shows log entries
- [ ] Response headers include `x-request-id` with an Envoy-generated UUID
- [ ] Grepping logs by `x-request-id` finds the matching log entry with correct response code
- [ ] The same `x-request-id` appears in the Distributed Tracing UI (Observe → Traces)
- [ ] Metrics query shows request counts by response code matching the generated traffic

---

Previous: [09c — Tracing (Optional)](../09c-tracing/README.md)
Next: [10 — Cleanup](../../10-cleanup/README.md)
