# SOAP Example for RHCL

Simple SOAP hello service to expose via Red Hat Connectivity Link.

## Develop

```bash
quarkus dev
```

## Build

```bash
podman build -t soap-example .
```

## Local Endpoints

```bash
curl http://localhost:8080/soap/hello?wsdl
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
    http://localhost:8080/soap/hello
```



## Deploy to Kubernetes

Prerequisite: Steps 1-3 from Connectivity Link Tutorial are completed.
[https://github.com/nikolaus-lemberski/connectivity-link-tutorial](https://github.com/nikolaus-lemberski/connectivity-link-tutorial)

Then run the install script

```bash
./k8s/deploy.sh
```



## K8s Endpoints

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
```

```bash
curl http://soap-example.$CLUSTER_DOMAIN/soap/hello?wsdl
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
    http://soap-example.$CLUSTER_DOMAIN/soap/hello
```