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
| Tracing (optional) | Red Hat build of OpenTelemetry / Tempo + Distributed Tracing UI Plugin |
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
│   ├── namespace.yaml                 # keycloak namespace
│   ├── subscription.yaml             # RHBK operator subscription + OperatorGroup
│   ├── postgres.yaml                  # PostgreSQL backend (Secret, PVC, Deployment, Service)
│   ├── keycloak.yaml                  # Keycloak CR + OpenShift Route (re-encrypt)
│   └── keycloak-realm.yaml            # KeycloakRealmImport (realm, OIDC client, test user)
├── 07-auth-policy/
│   ├── README.md                      # Protect APIs with AuthPolicy + OIDC
│   └── auth-policy.yaml              # AuthPolicy CR (JWT via Keycloak, envsubst)
├── 08-rate-limit-policy/
│   ├── README.md                      # Rate limit protection
│   └── rate-limit-policy.yaml         # RateLimitPolicy CR
├── 09-observability/
│   ├── 09a-metrics-monitoring/
│   │   ├── README.md                      # Metrics & monitoring walkthrough
│   │   ├── user-workload-monitoring.yaml  # Enable user workload monitoring
│   │   └── kuadrant-observability.yaml    # Kuadrant CR with observability enabled
│   ├── 09b-dashboards/
│   │   ├── README.md                      # COO & Perses dashboards walkthrough
│   │   ├── coo-subscription.yaml          # Cluster Observability Operator
│   │   ├── ui-plugin.yaml                 # UIPlugin with Perses enabled
│   │   ├── datasource.yaml                # PersesGlobalDatasource (Thanos)
│   │   └── dashboard.yaml                 # PersesDashboard CR for RHCL metrics
│   └── 09c-tracing/                       # Optional tracing config
│       ├── README.md                      # Tracing setup walkthrough
│       ├── tempo-subscription.yaml        # Tempo Operator subscription
│       ├── otel-subscription.yaml         # Red Hat build of OpenTelemetry Operator
│       ├── tempo-bucket-claim.yaml        # ODF ObjectBucketClaim for TempoStack storage
│       ├── tempo-stack.yaml               # Multi-tenant TempoStack + RBAC
│       ├── otel-collector.yaml            # OpenTelemetryCollector CR (trace forwarding)
│       ├── envoy-tracing-filter.yaml      # EnvoyFilter for Envoy proxy tracing
│       ├── kuadrant-tracing.yaml          # Kuadrant CR with tracing config
│       └── tracing-ui-plugin.yaml        # Distributed Tracing console plugin
└── 10-cleanup/
    └── README.md                      # Cleanup and teardown instructions
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
1. Create `keycloak` namespace
2. Install Red Hat build of Keycloak operator via OLM (`rhbk-operator`, channel `stable-v26.4`)
3. Deploy PostgreSQL backend (Secret, PVC, Deployment, Service)
4. Create a Keycloak CR instance (single-node, PostgreSQL, service-CA TLS, `ingress.enabled: false`)
5. Create an OpenShift Route (re-encrypt) at `sso.${CLUSTER_DOMAIN}`
6. Create a `KeycloakRealmImport` for the `connectivity-link-tutorial` realm containing:
   - OIDC Client `tutorial-app` (confidential, secret: `tutorial-app-secret`, direct access grants enabled)
   - Test user `testuser` / `testuser` with `user` realm role
   - Realm roles: `user`, `admin`
7. Verify: obtain a token via `curl` to `https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial/protocol/openid-connect/token`

**07 - AuthPolicy**
1. Create an AuthPolicy (`echo-auth`) in `tutorial-app` namespace targeting the `echo` HTTPRoute
   - Uses JWT authentication with `issuerUrl` pointing to `https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial`
   - Authorino auto-discovers JWKS keys from Keycloak's OIDC discovery endpoint
2. Verify:
   - Request without token → 401 Unauthorized
   - Request with invalid token → 401 Unauthorized
   - Obtain token from Keycloak, send request with `Authorization: Bearer <token>` → 200 OK

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
1. Install Tempo Operator and Red Hat build of OpenTelemetry Operator via OLM
2. Create an `ObjectBucketClaim` (via OpenShift Data Foundation) for TempoStack object storage
   - Assumes ODF is already installed on the cluster
   - The OBC provisions a bucket → ODF creates a Secret with S3 credentials
3. Deploy a multi-tenant TempoStack with gateway enabled and RBAC for trace read/write
4. Deploy an OpenTelemetry Collector that authenticates with the Tempo gateway and forwards traces with the correct tenant header
5. Configure Envoy proxy tracing via an EnvoyFilter (workaround for the managed Istio CR)
6. Configure data-plane tracing in the Kuadrant CR pointing to the OTel Collector:
   ```yaml
   spec:
     observability:
       dataPlane:
         httpHeaderIdentifier: x-request-id
       tracing:
         defaultEndpoint: rpc://otel-collector.tempo.svc.cluster.local:4317
         insecure: true
   ```
7. Enable the Distributed Tracing Console UI Plugin:
   ```yaml
   apiVersion: observability.openshift.io/v1alpha1
   kind: UIPlugin
   metadata:
     name: distributed-tracing
   spec:
     type: DistributedTracing
   ```
8. Verify: see traces from envoy-gateway, authorino, limitador, and wasm-shim in the OpenShift console via Observe → Traces

**09d - Access Logs**
1. Configure Envoy access logs via Istio Telemetry CR (if using OpenShift Service Mesh)
2. Enable request correlation with `x-request-id`
3. Demonstrate correlating logs → traces → metrics for a rate-limited or auth-denied request

### Phase 5: Wrap-up (Section 10)

**10 - Cleanup**
1. Cleanup instructions for tearing down all tutorial resources in reverse order
2. Delete namespaces, operator subscriptions, CRDs, and cluster-scoped resources

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
