# 05 — Secure the Gateway with TLSPolicy

**What you'll learn:** Use Kuadrant's TLSPolicy to automatically provision TLS certificates for your Gateway using cert-manager, and expose the Gateway over HTTPS.

**Prerequisites:** Phases 00–04 completed (Gateway running, echo app responding over HTTP).

## How TLSPolicy Works

TLSPolicy is a Kuadrant CRD that automates TLS certificate lifecycle management for Gateway API Gateways. When attached to a Gateway, it:

1. Discovers HTTPS listeners with `tls.certificateRefs`
2. Creates cert-manager `Certificate` resources for each listener hostname
3. cert-manager issues the certificate using the referenced `ClusterIssuer`
4. The resulting TLS secret is mounted into the Envoy data plane

```
┌─────────────┐     creates     ┌─────────────┐     issues     ┌───────────┐
│  TLSPolicy  │ ──────────────► │ Certificate │ ──────────────►│  Secret   │
│             │                 │  (cert-mgr) │                │ (TLS key) │
└──────┬──────┘                 └─────────────┘                └─────┬─────┘
       │ targets                                                     │
       │                                                             │ mounted
       ▼                                                             ▼
┌─────────────┐              Envoy data plane ◄─────────────────────┘
│   Gateway   │
│ (HTTPS:443) │
└─────────────┘
```

## Traffic Flow with TLS

After this phase, HTTPS traffic flows through TLS passthrough on the OpenShift Route:

```
Client ──► HAProxy (passthrough) ──► Envoy Gateway (TLS termination) ──► echo Service
  HTTPS          SNI routing              decrypts TLS                    plain HTTP
```

The plain HTTP Route from Phase 03 is replaced by the HTTPS passthrough Route in this phase.

## Step 1: Add HTTPS Listener to the Gateway

The Gateway needs an HTTPS listener for TLSPolicy to manage. The listener references a Secret that TLSPolicy will create via cert-manager.

Apply the updated Gateway (adds the HTTPS listener):

```shell
source export-cluster-env.sh
envsubst < 05-tls-policy/gateway.yaml | oc apply -f -
```

The HTTPS listener will show as **not Programmed** initially — this is expected because the TLS secret does not exist yet:

```bash
oc get gateway api-gateway -n openshift-ingress
```

## Step 2: Create the TLSPolicy

The TLSPolicy targets the Gateway and references the `selfsigned-cluster-issuer` from Phase 02:

```yaml
# 05-tls-policy/tls-policy.yaml
apiVersion: kuadrant.io/v1
kind: TLSPolicy
metadata:
  name: api-gateway-tls
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: api-gateway
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-cluster-issuer
```

Apply:

```bash
oc apply -f 05-tls-policy/tls-policy.yaml
```

## Step 3: Verify Certificate Issuance

Wait for the TLSPolicy to be accepted and enforced:

```bash
oc get tlspolicy api-gateway-tls -n openshift-ingress
```

Check that a Certificate was created and issued:

```shell
oc get certificates -n openshift-ingress
```

You should see a Certificate named `api-gateway-https` with `READY: True`. Verify the TLS secret exists:

```bash
oc get secret api-gateway-tls -n openshift-ingress
```

The HTTPS listener on the Gateway should now be Programmed:

```bash
oc get gateway api-gateway -n openshift-ingress
```

## Step 4: Replace HTTP Route with TLS Passthrough Route

OpenShift doesn't allow an unsecured Route and a passthrough Route on the same hostname. Delete the HTTP Route from Phase 03 and create a TLS passthrough Route so HTTPS traffic reaches Envoy directly:

```bash
oc delete route api-gateway -n openshift-ingress
```

Now create the passthrough Route:

```yaml
# 05-tls-policy/route-tls.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: api-gateway-tls
  namespace: openshift-ingress
spec:
  host: echo.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: api-gateway-openshift-default
    weight: 100
  port:
    targetPort: https
  tls:
    termination: passthrough
  wildcardPolicy: None
```

Apply:

```bash
envsubst < 05-tls-policy/route-tls.yaml | oc apply -f -
```

Verify the Route is admitted:

```bash
oc get route -n openshift-ingress -l app.kubernetes.io/part-of=connectivity-link-tutorial
```

## Step 5: Verify HTTPS Access

Test HTTPS access to the echo service (use `-k` because we're using a self-signed certificate):

```bash
curl -sk https://echo.$CLUSTER_DOMAIN/
```

You should see the echo service's JSON response with request details.

Inspect the certificate:

```bash
echo | openssl s_client -connect echo.${CLUSTER_DOMAIN}:443 -servername echo.${CLUSTER_DOMAIN} 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

> **Production note:** Replace `selfsigned-cluster-issuer` with an ACME ClusterIssuer (e.g., Let's Encrypt) for trusted certificates. See the [cert-manager ACME docs](https://cert-manager.io/docs/configuration/acme/).

## Verify

- [ ] `oc get tlspolicy -n openshift-ingress` shows `Accepted` and `Enforced`
- [ ] `oc get certificates -n openshift-ingress` shows `READY: True`
- [ ] `curl -sk https://echo.${CLUSTER_DOMAIN}/` returns the echo JSON response

---

Next: [06 — Keycloak Setup](../06-keycloak/)
