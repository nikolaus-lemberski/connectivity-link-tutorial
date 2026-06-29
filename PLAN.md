# Red Hat Connectivity Link 1.3 Tutorial — Implementation Plan

## Overview

A hands-on tutorial demonstrating how to secure, protect, and observe APIs using Red Hat Connectivity Link 1.3 on OpenShift. The tutorial targets platform engineers and application developers who want to learn Gateway API-based policy management.

## Target Environment

| Component | Version/Details |
|-----------|----------------|
| OpenShift Container Platform | 4.19+ |
| Red Hat Connectivity Link | 1.3 |
| cert-manager Operator for Red Hat OpenShift | 1.18 |
| Gateway controller | OpenShift Cluster Ingress Operator |
| Identity provider | Red Hat build of Keycloak 26.4 (OIDC) |
| Observability dashboards | Perses via Cluster Observability Operator (COO) 1.4+ |
| Tracing (optional) | Red Hat build of OpenTelemetry / Tempo |
| Rate limit storage | In-memory (single cluster, no Redis needed) |

## Directory Structure

```
connectivity-link-tutorial/
├── PLAN.md
├── README.md                          # Top-level overview and prerequisites
├── 00-prerequisites/
│   └── README.md                      # Cluster access, CLI tools, subscriptions
├── 01-install/
│   ├── README.md                      # Installation walkthrough
│   ├── namespace.yaml                 # kuadrant-system namespace
│   ├── gateway-class.yaml             # GatewayClass for OCP Cluster Ingress Operator
│   ├── subscription.yaml              # RHCL operator subscription + OperatorGroup
│   └── kuadrant.yaml                  # Kuadrant CR
├── 02-cert-manager/
│   ├── README.md                      # cert-manager setup for TLS
│   └── cluster-issuer.yaml            # ClusterIssuer (self-signed or ACME)
├── 03-gateway/
│   ├── README.md                      # Gateway setup + traffic routing
│   ├── gateway.yaml                   # Gateway resource (openshift-ingress namespace)
│   └── route.yaml                     # OpenShift Route to expose gateway (envsubst)
├── 04-app/
│   ├── README.md                      # Deploy sample echo application
│   ├── namespace.yaml                 # tutorial-app namespace
│   ├── deployment.yaml                # Echo server (quay.io/nlembers/rest-echo-service)
│   ├── service.yaml                   # ClusterIP service
│   └── httproute.yaml                 # HTTPRoute attaching to gateway (envsubst)
├── 05-tls-policy/
│   ├── README.md                      # Secure the gateway with TLS
│   ├── tls-policy.yaml               # TLSPolicy CR
│   └── route-tls.yaml                # OpenShift Route with TLS passthrough (envsubst)
├── 06-keycloak/
│   ├── README.md                      # Install and configure Keycloak
│   ├── subscription.yaml             # Keycloak operator subscription
│   ├── keycloak.yaml                  # Keycloak CR instance
│   ├── keycloak-realm.yaml            # Realm configuration
│   └── keycloak-client.yaml           # OIDC client for the tutorial app
├── 07-auth-policy/
│   ├── README.md                      # Protect APIs with AuthPolicy + OIDC
│   └── auth-policy.yaml              # AuthPolicy CR (OIDC via Keycloak)
├── 08-rate-limit-policy/
│   ├── README.md                      # Rate limit protection
│   └── rate-limit-policy.yaml         # RateLimitPolicy CR
├── 09-observability/
│   ├── README.md                      # Observability overview
│   ├── user-workload-monitoring.yaml  # Enable user workload monitoring
│   ├── kuadrant-observability.yaml    # Kuadrant CR with observability enabled
│   ├── coo-subscription.yaml         # Cluster Observability Operator
│   ├── ui-plugin.yaml                # UIPlugin with Perses enabled
│   ├── datasource.yaml               # PersesGlobalDatasource (Thanos)
│   ├── dashboard.yaml                # PersesDashboard CR for RHCL metrics
│   └── tracing/                       # Optional tracing config
│       ├── tempo-datasource.yaml      # PersesGlobalDatasource (Tempo)
│       └── kuadrant-tracing.yaml      # Kuadrant CR tracing config
└── 10-testing/
    └── README.md                      # End-to-end verification steps
```

## Implementation Phases

### Phase 1: Foundation (Sections 00–03)

**00 - Prerequisites**
- OpenShift 4.19+ cluster with `cluster-admin` access
- `oc` CLI installed and authenticated
- Red Hat subscription with Connectivity Link entitlement

**01 - Install Connectivity Link**
1. Create `kuadrant-system` namespace
2. Apply Subscription + OperatorGroup for `rhcl-operator` from `redhat-operators` catalog
3. Wait for operator install to complete
4. Apply Kuadrant CR to instantiate the operand
5. Verify: `oc wait kuadrant/kuadrant --for="condition=Ready=true"`

**02 - cert-manager Setup**
1. Verify cert-manager Operator for Red Hat OpenShift is installed (v1.18)
2. Create a ClusterIssuer (self-signed for tutorial simplicity, with a note on ACME for production)
3. Verify: `oc get clusterissuer`

**03 - Create Gateway**
1. Gateway is created in `openshift-ingress` namespace (required by OCP Ingress Operator)
2. Create a Gateway resource using Gateway API v1
   - Listener on port 80 (HTTP) with `allowedRoutes.namespaces.from: All`
   - HTTPS listener added later in Phase 05 (TLSPolicy)
3. On bare-metal without MetalLB, the gateway's LoadBalancer service stays Pending
4. Create an OpenShift Route to expose the gateway through the default router
5. Verify: `curl` through the Route returns HTTP 404 (no HTTPRoutes yet)

### Phase 2: Application (Section 04)

**04 - Deploy Sample Application**
1. Create `tutorial-app` namespace
2. Deploy `quay.io/nlembers/rest-echo-service:latest` (non-root, OpenShift-compatible REST echo service)
3. Create a ClusterIP Service (port 80 → container 8080)
4. Create an HTTPRoute that attaches to the Gateway and routes `echo.${CLUSTER_DOMAIN}` to the Service
5. Verify: `curl http://echo.${CLUSTER_DOMAIN}/` returns JSON with request details and Envoy headers

### Phase 3: Policies (Sections 05–08)

**05 - TLSPolicy**
1. Update the Gateway to add an HTTPS listener (port 443) with `tls.mode: Terminate` and `certificateRefs`
2. Create a TLSPolicy targeting the Gateway, referencing `selfsigned-cluster-issuer`
3. TLSPolicy creates a cert-manager Certificate → cert-manager issues cert → Secret mounted in Envoy
4. Replace Phase 03 HTTP Route with a TLS passthrough Route (HAProxy passes TLS to Envoy)
5. Verify: `curl -sk https://echo.${CLUSTER_DOMAIN}/` returns echo JSON, `oc get certificates` shows READY

**06 - Keycloak Setup**
1. Install Red Hat build of Keycloak operator via OLM (Subscription + OperatorGroup)
2. Create a Keycloak CR instance (minimal, single-node for tutorial)
3. Create a Realm (e.g., `connectivity-link-tutorial`)
4. Create an OIDC Client for the tutorial application
   - Client ID: `tutorial-app`
   - Access type: confidential
   - Valid redirect URIs matching the gateway host
5. Create a test user in the realm
6. Verify: obtain a token via `curl` to the Keycloak token endpoint

**07 - AuthPolicy**
1. Create an AuthPolicy targeting the HTTPRoute
   - Uses OIDC authentication with Keycloak as the identity provider
   - References the Keycloak issuer URL (`https://<keycloak-host>/realms/<realm>`)
2. Verify:
   - Request without token → 401 Unauthorized
   - Request with expired/invalid token → 401 Unauthorized
   - Obtain token from Keycloak, send request with Bearer token → 200 OK
3. (Optional: show authorization rules based on JWT claims/roles)

**08 - RateLimitPolicy**
1. Create a RateLimitPolicy targeting the HTTPRoute
   - Example: 5 requests per 10 seconds
2. Verify:
   - Send rapid authenticated requests → first succeed, then 429 Too Many Requests
   - Show rate limit headers in response
3. Note: single-cluster uses in-memory counters (no Redis required)
4. (Optional: show authenticated rate limiting — different limits per user/claim)

### Phase 4: Observability (Section 09)

**09 - Observability**

The observability section covers metrics, tracing, access logs, and dashboards using OpenShift-native tooling with Perses (via Cluster Observability Operator) instead of Grafana.

**09a - Metrics & Monitoring**
1. Ensure user workload monitoring is enabled in OpenShift
2. Enable observability in the Kuadrant CR:
   ```yaml
   spec:
     observability:
       enable: true
   ```
3. Verify ServiceMonitors/PodMonitors are created:
   `oc get servicemonitor,podmonitor -A -l kuadrant.io/observability=true`

**09b - Cluster Observability Operator & Perses Dashboards**
1. Install Cluster Observability Operator (COO) via OLM — this automatically deploys the Perses Operator
2. Enable the monitoring UIPlugin with Perses enabled:
   ```yaml
   apiVersion: observability.openshift.io/v1alpha1
   kind: UIPlugin
   metadata:
     name: monitoring
   spec:
     monitoring:
       perses:
         enabled: true
   ```
3. Create a PersesGlobalDatasource pointing to Thanos Querier for metrics
4. Create PersesDashboard CRs for Connectivity Link monitoring (migrate/adapt from Kuadrant Grafana dashboard JSON using Perses import or `percli migrate`)
5. Verify: access Observe > Dashboards (Perses) in the OpenShift web console

**09c - Tracing (Optional)**
1. Install Red Hat build of OpenTelemetry (Tempo) if distributed tracing is desired
2. Configure data-plane tracing in the Kuadrant CR:
   ```yaml
   spec:
     observability:
       dataPlane:
         httpHeaderIdentifier: x-request-id
       tracing:
         defaultEndpoint: rpc://tempo.tempo.svc.cluster.local:4317
         insecure: true
   ```
3. Create a PersesGlobalDatasource for Tempo
4. Verify: see traces in Perses Trace Table / Trace Gantt Chart panels

**09d - Access Logs**
1. Configure Envoy access logs via Istio Telemetry CR (if using OpenShift Service Mesh)
2. Enable request correlation with `x-request-id`
3. Demonstrate correlating logs → traces → metrics for a rate-limited or auth-denied request

### Phase 5: Wrap-up (Section 10)

**10 - Testing & Verification**
1. End-to-end test script:
   - Hit endpoint without auth → 401
   - Hit endpoint with auth → 200
   - Hit endpoint rapidly → 429
   - Verify TLS certificate is valid
2. Cleanup instructions

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Gateway controller | OpenShift Cluster Ingress Operator (Istio-based) | Default for RHCL on OCP 4.19+; deploys Envoy as the data plane |
| Gateway namespace | `openshift-ingress` | Required by OCP Ingress Operator; Gateway lives alongside Istio control plane |
| Traffic routing (bare-metal) | OpenShift Route → Gateway Service | No MetalLB needed; uses existing default router and wildcard DNS |
| Echo service image | `quay.io/nlembers/rest-echo-service:latest` | Non-root, OpenShift-compatible REST echo service; source in `apps/rest-echo-service/` |
| TLS issuer | Self-signed ClusterIssuer | Tutorial simplicity; production note for ACME/Let's Encrypt |
| Auth method | OIDC via Red Hat build of Keycloak 26.4 | Production-realistic; demonstrates JWT-based auth with a supported IdP |
| Rate limit storage | In-memory | Single cluster, no Redis dependency |
| Identity provider | Red Hat build of Keycloak via Operator (OLM) | Supported config for RHCL 1.3; installed via Operator per user preference |
| DNS | Skip DNSPolicy | Requires cloud DNS provider; not essential for core demo |
| Dashboards | Perses via Cluster Observability Operator (not Grafana) | Kubernetes-native, dashboard-as-code CRDs, integrated in OCP console |
| Observability | OpenShift user workload monitoring + Perses + optional Tempo tracing | Modern OpenShift-native stack |
| App deployment | Operators + plain manifests | User preference; Helm only if needed (e.g., Postgres later) |

## References

- [Red Hat Connectivity Link 1.3 Docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/)
- [Installing Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/installing_connectivity_link)
- [Deploying (Policies)](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/deploying_red_hat_connectivity_link)
- [Observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability)
- [Kuadrant upstream docs](https://docs.kuadrant.io/latest/)
- [Gateway API spec](https://gateway-api.sigs.k8s.io/)
