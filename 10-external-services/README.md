# 10 — Connect External Services

**What you'll learn:** Route traffic from your Connectivity Link gateway to external services outside the cluster, using Istio `ServiceEntry` and Gateway API `HTTPRoute`.

There are also other options for that use case like **Red Hat Service Interconnect**. The right solution depends on the environment and what you want to achieve.

## Overview

Connectivity Link can proxy requests to services that live outside the local cluster. This step demonstrates two patterns:

1. **Part 1** — Route to a public REST API (`dummyjson.com`) from the same cluster. No additional infrastructure required.
2. **Part 2** — Route to a SOAP service running on a separate OpenShift cluster (Cluster B).

> [!NOTE] 
> A `Service` of `type: ExternalName` as an `HTTPRoute` `backendRef` is explicitly **not supported** by Gateway API implementations (including Istio). Instead, we use Istio's `ServiceEntry` + `Hostname` backendRef.

## Prerequisites

- [00 — Prerequisites](../00-prerequisites/) through [03 — Create Gateway](../03-gateway/) completed on **Cluster A**
- `CLUSTER_DOMAIN` environment variable set:

```shell
source export-cluster-env.sh
```

---

## Part 1 — External REST API (single cluster)

In this part you route requests through the Gateway to the public [DummyJSON](https://dummyjson.com) API — specifically the random quotes endpoint. No second cluster is needed.

### Step 1 — Create the namespace

```shell
oc apply -f 10-external-services/quotes-namespace.yaml
```

### Step 2 — Create the ServiceEntry

The `ServiceEntry` registers `dummyjson.com` in Istio's service registry so the Gateway can route traffic to it over HTTPS.

```shell
oc apply -f 10-external-services/quotes-service-entry.yaml
```

### Step 3 — Create the DestinationRule

The `DestinationRule` instructs the Envoy proxy to originate TLS when connecting to `dummyjson.com`. Without this, the Gateway would send plain HTTP to port 443.

```shell
oc apply -f 10-external-services/quotes-destination-rule.yaml
```

### Step 4 — Create the HTTPRoute

The `HTTPRoute` matches requests on `/quotes`, rewrites the `Host` header to `dummyjson.com`, and forwards traffic via the `ServiceEntry`.

```shell
oc apply -f 10-external-services/quotes-httproute.yaml
```

### Step 5 — Expose via OpenShift Route

> [!NOTE]
> Remember: We just use OpenShift Route as a workaround in our tutorial to simplify the requirements for our environment. In a production cluster we would use **LoadBalancer** or the Connectivity Link **DNSPolicy**.

Create an OpenShift Route so the external service is reachable through the Gateway:

```shell
envsubst < 10-external-services/quotes-route.yaml | oc apply -f -
```

### Verify Part 1

Send a request for a random quote through the Connectivity Link gateway:

```shell
curl http://quotes-external.$CLUSTER_DOMAIN/quotes/random
```

You should receive a JSON response like:

```json
{
  "id": 42,
  "quote": "The only way to do great work is to love what you do.",
  "author": "Steve Jobs"
}
```

The request flows: Client → OpenShift Router → Envoy Gateway → dummyjson.com (HTTPS).

### Architecture (Part 1)

```
Cluster A (Connectivity Link)                  Internet
┌──────────────────────────────────┐          ┌───────────────────┐
│                                  │          │                   │
│  Client                          │          │  dummyjson.com    │
│    │                             │          │  /quotes/random   │
│    ▼                             │          │                   │
│  OpenShift Router                │          └─────────▲─────────┘
│    │                             │                    │
│    ▼                             │                    │
│  Envoy Gateway                   │                    │
│  (api-gateway)                   │                    │
│    │                             │                    │
│    │ HTTPRoute + ServiceEntry    │  TLS origination   │
│    │ + DestinationRule           │  (HTTPS/443)       │
│    └─────────────────────────────┼────────────────────┘
│                                  │  Host: dummyjson.com
└──────────────────────────────────┘
```

---

## Part 2 — External SOAP Service (second cluster)

This part requires a **second OpenShift cluster** (Cluster B). If you don't have one, you can skip ahead to [11 — Cleanup](../11-cleanup/).

### Additional prerequisites

- A **second OpenShift cluster** (Cluster B) with `oc` access

### Step 6 — Deploy the SOAP service on Cluster B

Log in to Cluster B and deploy the SOAP example application.

#### 6a — Create the namespace and deployment

```shell
oc apply -f apps/soap-external-service/k8s/namespace.yaml
oc apply -f apps/soap-external-service/k8s/deployment.yaml
```

#### 6b — Expose the service

```shell
oc project soap-example
oc expose deploy soap-example
oc expose svc soap-example
```

#### 6c — Verify the SOAP service is accessible

Retrieve the Route hostname:

```shell
oc get route soap-example -n soap-example -o jsonpath='{.spec.host}'
```

Store it for later use:

```shell
export SOAP_EXTERNAL_HOST=$(oc get route soap-example -n soap-example -o jsonpath='{.spec.host}')
```

Test the service:

```shell
curl -X POST -H "Content-Type: text/xml;charset=UTF-8" \
    -d \
      '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <ns2:hello xmlns:ns2="http://soap.nlembers.redhat.com/">
            <arg0>World</arg0>
          </ns2:hello>
        </soap:Body>
       </soap:Envelope>' \
    http://$SOAP_EXTERNAL_HOST/soap/hello
# Should return: <soap:Envelope ...><return>Hello World!</return>...
```

### Step 7 — Register the external SOAP service on Cluster A

Switch back to Cluster A (where Connectivity Link is installed).

#### 7a — Set the external host variable

Use the Route hostname from Step 6c:

```shell
export SOAP_EXTERNAL_HOST=<hostname-from-step-6c>
```

#### 7b — Create the namespace

```shell
oc apply -f 10-external-services/namespace.yaml
```

#### 7c — Create the ServiceEntry

The `ServiceEntry` registers the external SOAP host in Istio's service registry so the Gateway can route traffic to it.

```shell
envsubst < 10-external-services/service-entry.yaml | oc apply -f -
```

#### 7d — Create the HTTPRoute

The `HTTPRoute` matches requests on `/soap`, rewrites the `Host` header to the external hostname, and forwards traffic via the `ServiceEntry`.

```shell
envsubst < 10-external-services/httproute.yaml | oc apply -f -
```

#### 7e — Expose via OpenShift Route

```shell
envsubst < 10-external-services/route.yaml | oc apply -f -
```

### Verify Part 2

Send a SOAP request through the Connectivity Link gateway on Cluster A:

```shell
curl -X POST -H "Content-Type: text/xml;charset=UTF-8" \
    -d \
      '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <ns2:hello xmlns:ns2="http://soap.nlembers.redhat.com/">
            <arg0>World</arg0>
          </ns2:hello>
        </soap:Body>
       </soap:Envelope>' \
    http://soap-external.$CLUSTER_DOMAIN/soap/hello
# Should return: <soap:Envelope ...><return>Hello World!</return>...
```

The request flows: Client → OpenShift Router → Envoy Gateway (Cluster A) → External SOAP Service (Cluster B).

### Architecture (Part 2)

```
Cluster A (Connectivity Link)            Cluster B (SOAP Service)
┌──────────────────────────────┐        ┌─────────────────────────┐
│                              │        │                         │
│  Client                      │        │  soap-example namespace │
│    │                         │        │  ┌───────────────────┐  │
│    ▼                         │        │  │ Deployment        │  │
│  OpenShift Router            │        │  │ soap-example:8080 │  │
│    │                         │        │  └────────┬──────────┘  │
│    ▼                         │        │           │             │
│  Envoy Gateway               │        │  Service ─┘             │
│  (api-gateway)               │        │           │             │
│    │                         │        │  OpenShift Route        │
│    │ HTTPRoute + ServiceEntry│        │  (soap-example.apps...) │
│    │                         │        └───────────┬─────────────┘
│    └─────────────────────────┼────────────────────┘
│                              │    HTTP (Host rewrite)
└──────────────────────────────┘
```

---

## Manifests

| File | Resource | Purpose |
|------|----------|---------|
| `quotes-namespace.yaml` | `Namespace` | `quotes-external` namespace for the REST external service routing |
| `quotes-service-entry.yaml` | `ServiceEntry` | Registers `dummyjson.com` with Istio |
| `quotes-destination-rule.yaml` | `DestinationRule` | TLS origination for HTTPS connection to `dummyjson.com` |
| `quotes-httproute.yaml` | `HTTPRoute` | Matches `/quotes`, rewrites `Host` header, forwards to `ServiceEntry` |
| `quotes-route.yaml` | `Route` | Exposes `quotes-external.${CLUSTER_DOMAIN}` through the OpenShift Router |
| `namespace.yaml` | `Namespace` | `soap-external` namespace for the SOAP external service routing |
| `service-entry.yaml` | `ServiceEntry` | Registers the external SOAP host with Istio |
| `httproute.yaml` | `HTTPRoute` | Matches `/soap`, rewrites `Host` header, forwards to `ServiceEntry` |
| `route.yaml` | `Route` | Exposes `soap-external.${CLUSTER_DOMAIN}` through the OpenShift Router |

## Cleanup

To remove only this step's resources:

```shell
# Part 1 (REST)
oc delete -n quotes-external httproute quotes-external
oc delete -n quotes-external destinationrule dummyjson-external
oc delete -n quotes-external serviceentry dummyjson-external
oc delete route quotes-external -n openshift-ingress
oc delete namespace quotes-external

# Part 2 (SOAP)
oc delete -n soap-external httproute soap-external
oc delete -n soap-external serviceentry soap-external
oc delete route soap-external -n openshift-ingress
oc delete namespace soap-external
```

## Next steps

Proceed to [11 — Cleanup](../11-cleanup/).
