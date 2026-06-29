# 04 — Deploy Sample Application

This step deploys an HTTP echo service and routes traffic to it through the Gateway created in the previous step.

## What we're deploying

| Component | Details |
|-----------|---------|
| Image | `quay.io/nlembers/rest-echo-service:latest` |
| Description | REST echo service — responds with method, path, status, and headers as JSON |
| Port | 8080 (non-root, OpenShift-compatible) |
| Namespace | `tutorial-app` |
| Source | [`apps/rest-echo-service/`](../apps/rest-echo-service/) |

The echo service is useful for verifying that traffic flows correctly through the Gateway and that policies (auth, rate limiting) are applied in later steps.

## Prerequisites

- [03 — Create Gateway](../03-gateway/) completed
- `CLUSTER_DOMAIN` environment variable set:

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
```

## Step 1 — Create the application namespace

```bash
oc apply -f 04-app/namespace.yaml
```

## Step 2 — Deploy the echo service

```bash
oc apply -f 04-app/deployment.yaml
oc apply -f 04-app/service.yaml
```

Wait for the pod to be ready:

```bash
oc wait -n tutorial-app deployment/echo --for=condition=Available --timeout=120s
```

## Step 3 — Create the HTTPRoute

The HTTPRoute attaches to the Gateway in `openshift-ingress` and routes traffic for `echo.${CLUSTER_DOMAIN}` to the echo service.

```bash
envsubst < 04-app/httproute.yaml | oc apply -f -
```

Verify the HTTPRoute is accepted:

```bash
oc get httproute -n tutorial-app
# NAME   HOSTNAMES                                                 AGE
# echo   ["echo.apps.<cluster-domain>"]                            ...
```

Check the route status:

```bash
oc get httproute echo -n tutorial-app -o jsonpath='{.status.parents[0].conditions}' | python3 -m json.tool
# Should show Accepted: True, ResolvedRefs: True
```

## Step 4 — Verify end-to-end traffic

Send a request through the Gateway:

```bash
curl -s http://echo.$CLUSTER_DOMAIN/ | python3 -m json.tool
```

You should see a JSON response containing request details:

```json
{
  "method": "GET",
  "path": "/",
  "status": 200,
  "headers": {
    "host": "echo.apps.<cluster-domain>",
    "x-envoy-external-address": "...",
    "x-request-id": "...",
    "x-forwarded-proto": "http"
  },
  "tracing_headers": {
    "x-request-id": "..."
  }
}
```

Key indicators that traffic flows through the Envoy gateway:

- `x-envoy-external-address` — client IP as seen by Envoy
- `x-request-id` — unique request ID added by Envoy
- `tracing_headers` — distributed tracing headers extracted for visibility

Test with a POST request:

```bash
curl -s -X POST -H "Content-Type: application/json" \
    -d '{"message":"hello from tutorial"}' \
    http://echo.${CLUSTER_DOMAIN}/api/test | python3 -m json.tool
```

## Manifests

| File | Resource | Purpose |
|------|----------|---------|
| `namespace.yaml` | `Namespace` | `tutorial-app` namespace for the application |
| `deployment.yaml` | `Deployment` | Echo server (1 replica, non-root) |
| `service.yaml` | `Service` | ClusterIP service on port 80 → container port 8080 |
| `httproute.yaml` | `HTTPRoute` | Routes `echo.${CLUSTER_DOMAIN}` through the Gateway to the echo service |

## Architecture

```
                  *.apps DNS
                      │
                      ▼
              ┌───────────────┐
              │  Default Router│  (HAProxy, HostNetwork)
              │  Port 80/443  │
              └───────┬───────┘
                      │ OpenShift Route
                      ▼
              ┌───────────────┐
              │  Envoy Gateway │  (api-gateway-openshift-default)
              │  openshift-    │
              │  ingress       │
              └───────┬───────┘
                      │ HTTPRoute
                      ▼
              ┌───────────────┐
              │  Echo Service  │  (tutorial-app namespace)
              │  Port 80→8080 │
              └───────────────┘
```

## Next steps

Proceed to [05 — TLS Policy](../05-tls-policy/).
