# 10 — Connect an External SOAP Service

**What you'll learn:** Route traffic from your Connectivity Link gateway to an external SOAP service running on a separate OpenShift cluster, using an Istio `ServiceEntry` and Gateway API `HTTPRoute`.

## Overview

Connectivity Link can proxy requests to services that live outside the local cluster. This step demonstrates the pattern using a SOAP service deployed on a second OpenShift cluster (Cluster B). On the Connectivity Link cluster (Cluster A), you register the remote service with a `ServiceEntry` and create an `HTTPRoute` that rewrites the `Host` header to match the external Route.

> **Note:** A `Service` of `type: ExternalName` as an `HTTPRoute` `backendRef` is explicitly **not supported** by Gateway API implementations (including Istio). Instead, this uses Istio's `ServiceEntry` + `Hostname` backendRef.

## Prerequisites

- [00 — Prerequisites](../00-prerequisites/) through [03 — Create Gateway](../03-gateway/) completed on **Cluster A**
- A **second OpenShift cluster** (Cluster B) with `oc` access
- `CLUSTER_DOMAIN` environment variable set (Cluster A):

```shell
source export-cluster-env.sh
```

## Part 1 — Deploy the SOAP service on Cluster B

Log in to Cluster B and deploy the SOAP example application.

### Step 1 — Create the namespace and deployment

```shell
oc apply -f apps/soap-external-service/k8s/namespace.yaml
oc apply -f apps/soap-external-service/k8s/deployment.yaml
```

### Step 2 — Expose the service

```shell
oc project soap-example
oc expose deploy soap-example
oc expose svc soap-example
```

### Step 3 — Verify the SOAP service is accessible

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

## Part 2 — Register the external service on Cluster A

Switch back to Cluster A (where Connectivity Link is installed).

### Step 4 — Set the external host variable

Use the Route hostname from Cluster B:

```shell
export SOAP_EXTERNAL_HOST=<hostname-from-step-3>
```

### Step 5 — Create the namespace

```shell
oc apply -f 10-external-services/namespace.yaml
```

### Step 6 — Create the ServiceEntry

The `ServiceEntry` registers the external SOAP host in Istio's service registry so the Gateway can route traffic to it.

```shell
envsubst < 10-external-services/service-entry.yaml | oc apply -f -
```

### Step 7 — Create the HTTPRoute

The `HTTPRoute` matches requests on `/soap`, rewrites the `Host` header to the external hostname, and forwards traffic via the `ServiceEntry`.

```shell
envsubst < 10-external-services/httproute.yaml | oc apply -f -
```

### Step 8 — Expose via OpenShift Route

Since this tutorial does not use a cloud LoadBalancer, create an OpenShift Route to make the external service reachable through the Gateway:

```shell
envsubst < 10-external-services/route.yaml | oc apply -f -
```

## Verify

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

## Manifests

| File | Resource | Purpose |
|------|----------|---------|
| `namespace.yaml` | `Namespace` | `soap-external` namespace for the external service routing |
| `service-entry.yaml` | `ServiceEntry` | Registers the external SOAP host with Istio |
| `httproute.yaml` | `HTTPRoute` | Matches `/soap`, rewrites `Host` header, forwards to `ServiceEntry` |
| `route.yaml` | `Route` | Exposes `soap-external.${CLUSTER_DOMAIN}` through the OpenShift Router |

## Architecture

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

## Cleanup

To remove only this step's resources:

```shell
oc delete -n soap-external httproute soap-external
oc delete -n soap-external serviceentry soap-external
oc delete route soap-external -n openshift-ingress
oc delete namespace soap-external
```

## Next steps

Proceed to [11 — Cleanup](../11-cleanup/).
