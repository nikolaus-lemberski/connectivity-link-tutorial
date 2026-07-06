# Running as "External Service" for Connectivity Link

Create 2 cluster. In cluster A, install Connectivity Link (tutorial steps 1-3). In cluster B, install this SOAP example.

## Cluster B (SOAP service)

```bash
oc create -f k8s/namespace.yaml
oc create -f k8s/deployment.yaml
oc project soap-example
oc expose deploy soap-example
oc expose svc soap-example
oc get route
```

Test if it works:

```bash
export ROUTE=<the-route>
```

```bash
curl -v -X POST -H "Content-Type: text/xml;charset=UTF-8" \
    -d \
      '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
        <soap:Body>
          <ns2:hello xmlns:ns2="http://soap.nlembers.redhat.com/">
            <arg0>World</arg0>
          </ns2:hello>
        </soap:Body>
       </soap:Envelope>' \
    http://$ROUTE/soap/hello
```

## Cluster A (RHCL)

> **Note:** A `Service` of `type: ExternalName` as an `HTTPRoute` `backendRef`
> is explicitly **not supported** by Gateway API implementations (including
> Istio). Instead, this uses Istio's `ServiceEntry` + `Hostname` backendRef.

## Manifests

| File | Resource | Purpose |
|------|----------|---------|
| `namespace.yaml` | `Namespace` | Isolated namespace for the experiment |
| `service-entry.yaml` | `ServiceEntry` (`networking.istio.io/v1`) | Registers the external SOAP host with Istio |
| `httproute.yaml` | `HTTPRoute` | Matches `/soap`, rewrites the `Host` header, forwards to the `ServiceEntry` |

## Run it

```shell
export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export SOAP_EXTERNAL_HOST=soap-example-soap-example.apps.cluster-d8t7s.dynamic2.redhatworkshops.io

oc apply -f namespace.yaml
envsubst < service-entry.yaml | oc apply -f -
envsubst < httproute.yaml | oc apply -f -
```

Call the SOAP service through Connectivity Link:

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
    http://echo.$CLUSTER_DOMAIN/soap/hello
# Should return: <soap:Envelope ...><return>Hello World!</return>...
```

## Cleanup

```shell
oc delete -n soap-experiment httproute soap-external
oc delete -n soap-experiment serviceentry soap-external
oc delete namespace soap-experiment
```

