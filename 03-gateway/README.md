# 03 — Create the Gateway

This step creates a Gateway API `Gateway` resource and exposes it through an OpenShift Route so that external traffic can reach it.

## Background

On OpenShift, the Cluster Ingress Operator implements Gateway API using a lightweight Istio control plane (Red Hat OpenShift Service Mesh). When you create a `Gateway`, the operator automatically provisions:

- An Envoy-based proxy deployment
- A `LoadBalancer`-type service

> [!NOTE]
> On bare-metal / on-premise clusters without a cloud load balancer (e.g., no MetalLB), the service remains in a `Pending` state. To work around this, we create an **OpenShift Route** that forwards traffic from the default router to the gateway service. The wildcard DNS (`*.apps.<cluster>`) already resolves to the node, so any hostname under that domain reaches the default router.
>  
> In production mode, you would use **DNSPolicy** from Connectivity Link or the LoadBalancer and not create a *Route*.

**Traffic flow:**

```
Client → *.apps DNS → Node → Default Router (HAProxy) → Route → Gateway Service → Envoy → Backend
```

## Prerequisites

- [01 — Install Connectivity Link](../01-install/) completed
- [02 — cert-manager Setup](../02-cert-manager/) completed

## Gateway namespace

All OpenShift documentation places the Gateway in the `openshift-ingress` namespace (where the Istio control plane runs). There is no need to create a separate namespace.

## Step 1 — Create the Gateway

```shell
oc apply -f 03-gateway/gateway.yaml
```

This creates a Gateway with an HTTP listener on port 80 that accepts HTTPRoutes from all namespaces. The HTTPS listener is added in [05 — TLS Policy](../05-tls-policy/).

Verify the Gateway is accepted:

```shell
oc get gateway -n openshift-ingress
# NAME          CLASS               ADDRESS   PROGRAMMED   AGE
# api-gateway   openshift-default             False        ...
```

> **Note:** `PROGRAMMED=False` is expected on bare-metal clusters without a load balancer controller. The Envoy proxy is running — it just has no external IP assigned.

Confirm the gateway deployment is running (may take 15–30 seconds after apply):

```shell
oc get pods -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=api-gateway
```

## Step 2 — Expose the Gateway via an OpenShift Route

The Route manifest uses `${CLUSTER_DOMAIN}` as a placeholder. Set the variable and apply with `envsubst`:

```shell
source export-cluster-env.sh
envsubst < 03-gateway/route.yaml | oc apply -f -
```

Verify the Route:

```shell
oc get route api-gateway -n openshift-ingress
# NAME          HOST/PORT                        PATH   SERVICES                        PORT   ...
# api-gateway   echo.apps.<cluster-domain>              api-gateway-openshift-default   http   ...
```

Test that traffic reaches the Envoy gateway (expect HTTP 404 — no HTTPRoutes exist yet):

```shell
for i in 1 2 3 4 5; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://echo.$CLUSTER_DOMAIN/)
  echo "Attempt $i: HTTP $CODE"
  [ "$CODE" = "404" ] && break
  sleep 5
done
# Should eventually show 404 (503 means the gateway pod is still starting)
```

A `404` from Envoy confirms the gateway is receiving traffic.

## Manifests

| File | Resource | Purpose |
|------|----------|---------|
| `gateway.yaml` | `Gateway` | HTTP listener on port 80, allows routes from all namespaces |
| `route.yaml` | `Route` | Exposes the gateway service through the default OpenShift router |

## Next steps

Proceed to [04 — Deploy Sample Application](../04-app/).
