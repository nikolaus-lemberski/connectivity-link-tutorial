# 07 — IP Restriction

**What you'll learn:** Use AuthPolicy authorization rules with CEL predicates to block a specific IP address from accessing your API. Blocked requests receive HTTP 403 Forbidden.

**Prerequisites:** Phases 00–06 completed (Gateway with TLS, echo app running, AuthPolicy enforcing JWT authentication).

## How IP Restriction Works

Kuadrant's AuthPolicy supports `when` conditions — CEL (Common Expression Language) predicates that control when a rule is activated. By combining a `when` predicate with an authorization rule that denies access, you can block traffic from specific IP addresses.

```
┌────────┐    request     ┌──────────────┐   IP not blocked  ┌─────────┐
│ Client │ ──────────────►│    Envoy     │ ─────────────────►│  echo   │
│        │                │   Gateway    │                   │ Service │
│        │◄── 403 ────────│              │                   │         │
└────────┘  (IP blocked)  │  AuthPolicy  │                   └─────────┘
                          │  (Authorino) │
                          │      │       │
                          │ 1. JWT authn │
                          │ 2. IP check  │
                          └──────────────┘
```

The request flow:
1. **Authentication** — JWT is validated first (existing `keycloak-jwt` rule from Phase 06)
2. **Authorization** — The source IP is checked against the denylist
3. If the IP **matches** the blocked IP, the OPA rule fires and returns `allow = false` → HTTP 403
4. If the IP **does not match**, the `when` predicate is false, the deny rule is skipped, and the request proceeds

The predicate inspects the `x-forwarded-for` request header, which carries the real client IP even when Envoy sits behind the OpenShift Cluster Ingress Operator (HAProxy router). `startsWith` handles the case where the header contains a chain of IPs — the originating client IP is always first.

## Step 1: Discover Your Source IP

Send an authenticated request to the echo service and look at the response. The echo service mirrors the request headers, including `x-forwarded-for` which carries your real client IP:

```shell
source export-cluster-env.sh
export TOKEN=$(get_token)

RESPONSE=$(curl -sk -H "Authorization: Bearer $TOKEN" "https://echo.$CLUSTER_DOMAIN/")
echo "$RESPONSE" | python3 -m json.tool

export CLIENT_IP=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['headers']['x-forwarded-for'].split(',')[0].strip())")
echo "CLIENT_IP=$CLIENT_IP"
```

The first IP in `x-forwarded-for` is exported as `CLIENT_IP` for use in the next step.

## Step 2: Review the IP Restriction AuthPolicy

The policy replaces the existing `echo-auth` AuthPolicy. It keeps JWT authentication and adds an IP-based authorization rule that blocks a single IP:

```yaml
# 07-ip-restriction/auth-policy-ip-restriction.yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: echo-auth
  namespace: tutorial-app
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: echo
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: https://keycloak.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial
    authorization:
      ip-denylist:
        opa:
          rego: "allow = false"
        when:
          - predicate: >-
              request.headers['x-forwarded-for'].startsWith('$CLIENT_IP')
    response:
      unauthorized:
        headers:
          "content-type":
            value: application/json
        body:
          value: '{"error": "Forbidden", "message": "Your IP has been blocked"}'
```

Key points:
- **authentication** is unchanged — JWT validation still runs first
- **authorization.ip-denylist** is an OPA rule that returns `allow = false`
- **when** controls when the deny rule fires: only when the `x-forwarded-for` header starts with the blocked IP
- `$CLIENT_IP` is substituted from the environment variable you exported in Step 1

## Step 3: Apply the Policy (Verify 403)

Apply the policy using the `CLIENT_IP` from Step 1:

```shell
source export-cluster-env.sh

envsubst < 07-ip-restriction/auth-policy-ip-restriction.yaml | oc apply -f -
```

> Run Step 1 in the same shell session so `CLIENT_IP` is set, or re-export it before applying.

Wait for the policy to be enforced:

```shell
oc get authpolicy echo-auth -n tutorial-app -o jsonpath='{.status.conditions}' | python3 -m json.tool
# Accepted: True, Enforced: True
```

> **Note:** Envoy may take up to 60 seconds to pick up the updated policy. Wait before testing.

Now send an authenticated request:

```shell
export TOKEN=$(get_token)

curl -sk -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  "https://echo.$CLUSTER_DOMAIN/"
```

Expected: **HTTP 403 Forbidden** with the response body `{"error": "Forbidden", "message": "Your IP has been blocked"}`.

Requests without a token are still rejected with 401 — JWT authentication runs before authorization:

```shell
curl -sk -w "\nHTTP %{http_code}\n" "https://echo.$CLUSTER_DOMAIN/"
```

Expected: **HTTP 401 Unauthorized**.

## Step 4: Revert to the Original AuthPolicy

Restore the JWT-only AuthPolicy from Phase 06 so the cleanup section works as expected:

```shell
source export-cluster-env.sh
envsubst < 06-auth-policy/auth-policy.yaml | oc apply -f -
```

Verify the policy is back to its original state:

```shell
oc get authpolicy echo-auth -n tutorial-app -o jsonpath='{.status.conditions}' | python3 -m json.tool
# Accepted: True, Enforced: True
```

Send a request to confirm access is restored:

```shell
export TOKEN=$(get_token)

curl -sk -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  "https://echo.$CLUSTER_DOMAIN/"
```

Expected: **HTTP 200 OK**.

## Verify

- [ ] `x-forwarded-for` from echo response identifies the client IP
- [ ] Authenticated request after applying the denylist policy → HTTP 403
- [ ] Unauthenticated request (no JWT) → HTTP 401 (authentication runs before authorization)
- [ ] Original AuthPolicy restored and authenticated request → HTTP 200

---

Next: [08 — Rate Limit Policy](../08-rate-limit-policy/)
