# 08 — Rate Limit the API with RateLimitPolicy

**What you'll learn:** Use Kuadrant's RateLimitPolicy to protect your API from excessive traffic. Requests exceeding the configured rate receive HTTP 429 Too Many Requests.

**Prerequisites:** Phases 00–07 completed (Gateway with TLS, echo app running, AuthPolicy enforcing JWT authentication).

## How RateLimitPolicy Works

RateLimitPolicy is a Kuadrant CRD that attaches rate limiting rules to Gateway API resources. When targeting an HTTPRoute, a Wasm extension running inside Envoy counts requests and enforces limits using Limitador (the rate limiting service deployed by Connectivity Link).

```
┌────────┐    request     ┌──────────────┐   within limit    ┌─────────┐
│ Client │ ──────────────►│    Envoy     │ ─────────────────►│  echo   │
│        │                │   Gateway    │                   │ Service │
│        │◄── 429 ────────│              │                   │         │
└────────┘  (over limit)  │  Wasm shim   │                   └─────────┘
                          │      │       │
                          │      │ check │
                          │      ▼       │
                          │ ┌──────────┐ │
                          │ │Limitador │ │
                          │ │(counters)│ │
                          │ └──────────┘ │
                          └──────────────┘
```

In this tutorial the Limitador counters are stored **in-memory** — no Redis is required for a single-cluster setup. For multi-cluster or persistent rate limiting, see the Connectivity Link docs on configuring Redis storage.

## Step 1: Review the RateLimitPolicy Manifest

The policy targets the `echo` HTTPRoute and allows **5 requests per 10 seconds**:

```yaml
# 08-rate-limit-policy/rate-limit-policy.yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: echo-rate-limit
  namespace: tutorial-app
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: echo
  limits:
    global:
      rates:
        - limit: 5
          window: 10s
```

Key points:
- **targetRef** points to the `echo` HTTPRoute — the same route protected by AuthPolicy
- **limits.global** defines a named limit; the name is arbitrary
- **rates** specifies 5 requests allowed in a 10-second window
- Policies stack: AuthPolicy (JWT) is evaluated first, then RateLimitPolicy applies to authenticated requests

## Step 2: Apply the RateLimitPolicy

```bash
oc apply -f 08-rate-limit-policy/rate-limit-policy.yaml
```

Wait for the policy to be accepted and enforced:

```bash
oc get ratelimitpolicy echo-rate-limit -n tutorial-app
```

Check the status conditions:

```bash
oc get ratelimitpolicy echo-rate-limit -n tutorial-app -o jsonpath='{.status.conditions}' | python3 -m json.tool
# Accepted: True, Enforced: True
```

## Step 3: Obtain a Token

Since AuthPolicy is already enforced, you need a valid JWT to test rate limiting:

```shell
source export-cluster-env.sh
export TOKEN=$(get_token)
```

## Step 4: Verify — Send Requests Within the Limit (200)

Send a single authenticated request:

```bash
curl -sk -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  "https://echo.$CLUSTER_DOMAIN/"
```

Expected: **HTTP 200** — within the rate limit.

## Step 5: Verify — Exceed the Limit (429)

Send 10 rapid requests and observe the rate limit kicking in after the 5th:

```bash
for i in $(seq 1 10); do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "https://echo.$CLUSTER_DOMAIN/")
  echo "Request $i: HTTP $STATUS"
done
```

Expected output (approximate):

```
Request 1: HTTP 200
Request 2: HTTP 200
Request 3: HTTP 200
Request 4: HTTP 200
Request 5: HTTP 200
Request 6: HTTP 429
Request 7: HTTP 429
Request 8: HTTP 429
Request 9: HTTP 429
Request 10: HTTP 429
```

After 10 seconds, the counter resets and requests succeed again.

## How Both Policies Work Together

With both AuthPolicy and RateLimitPolicy enforced, the request flow is:

```
1. Client → Keycloak:  POST /token  (get JWT)
2. Client → Gateway:   GET /  with Authorization: Bearer <JWT>
3. Envoy  → Authorino: Validate JWT (reject → 401)
4. Envoy  → Limitador: Check rate limit (reject → 429)
5. Envoy  → echo:      Forward request
6. echo   → Client:    200 OK
```

> **Note:** Without a valid JWT, the request is rejected at step 3 with 401 — it never reaches the rate limiter. Rate limits only apply to authenticated traffic.

## Verify

- [ ] `oc get ratelimitpolicy echo-rate-limit -n tutorial-app` shows `Accepted` and `Enforced`
- [ ] Authenticated requests within limit → HTTP 200
- [ ] Rapid requests exceeding 5 in 10 seconds → HTTP 429
- [ ] After waiting 10 seconds, requests succeed again (counter resets)

---

Next: [09 — Observability](../09-observability/)
