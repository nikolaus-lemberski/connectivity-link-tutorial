# 09b — Cluster Observability Operator & Perses Dashboards

**What you'll learn:** Install the Cluster Observability Operator, enable Perses-based dashboards in the OpenShift console, connect Perses to the platform Thanos Querier, and deploy a Connectivity Link monitoring dashboard — all managed as Kubernetes custom resources.

**Prerequisites:** Section 09a completed (user workload monitoring enabled, Kuadrant observability enabled, metrics flowing).

## Overview

[Perses](https://perses.dev/) is a cloud-native dashboard tool that ships with the Cluster Observability Operator (COO). Unlike Grafana, Perses dashboards are Kubernetes CRDs — you manage them with `oc apply`, store them in Git, and control access via standard RBAC.

```
┌─────────────────────────────────────────────────────────────────┐
│  Cluster Observability Operator (COO)                           │
│                                                                 │
│  ┌─────────────────┐    ┌──────────────────────────────────┐    │
│  │ Perses Operator │    │ UIPlugin (Monitoring)            │    │
│  │                 │    │  → Perses UI in OpenShift console│    │
│  │  Reconciles:    │    │  → Perses server instance        │    │
│  │  - Dashboards   │    └──────────────────────────────────┘    │
│  │  - Datasources  │                                            │
│  └─────────────────┘                                            │
│                                                                 │
│  CRDs:                                                          │
│  ┌──────────────────┐ ┌────────────────┐ ┌───────────────────┐  │
│  │ PersesDashboard  │ │PersesDatasource│ │PersesGlobal       │  │
│  │ (namespaced)     │ │ (namespaced)   │ │  Datasource       │  │
│  └──────────────────┘ └────────────────┘ └───────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Step 1: Install the Cluster Observability Operator

Install COO via OLM. This automatically deploys the Perses Operator and registers the Perses CRDs.

```bash
oc apply -f 09-observability/09b-dashboards/coo-subscription.yaml
```

<details>
<summary>coo-subscription.yaml</summary>

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-observability-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```
</details>

Wait for the operator to install:

```bash
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown \
  subscription/cluster-observability-operator \
  -n openshift-cluster-observability-operator --timeout=120s
```

Verify the CSV succeeded and the Perses CRDs are registered:

```bash
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability
# cluster-observability-operator.v1.5.0   Cluster Observability Operator   1.5.0   Succeeded

oc get crds | grep perses
# persesdashboards.perses.dev
# persesdatasources.perses.dev
# persesglobaldatasources.perses.dev
```

Confirm the operators are running:

```bash
oc get pods -n openshift-cluster-observability-operator
# NAME                                    READY   STATUS    RESTARTS   AGE
# observability-operator-...              1/1     Running   0          ...
# perses-operator-...                     1/1     Running   0          ...
```

## Step 2: Enable the Monitoring UIPlugin with Perses

Create a `UIPlugin` resource to enable the Perses UI in the OpenShift web console. This triggers creation of a Perses server instance and adds the **Observe → Dashboards (Perses)** menu item.

```bash
oc apply -f 09-observability/09b-dashboards/ui-plugin.yaml
```

<details>
<summary>ui-plugin.yaml</summary>

```yaml
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
```
</details>

Verify the UIPlugin is reconciled and the Perses server is running:

```bash
oc get uiplugin monitoring -o jsonpath='{.status.conditions[0].message}'
# Plugin reconciled successfully

oc get pods -n openshift-cluster-observability-operator -l app.kubernetes.io/name=perses
# NAME       READY   STATUS    RESTARTS   AGE
# perses-0   1/1     Running   0          ...
```

> **Note:** After enabling the plugin, it may take a few minutes for the **Dashboards (Perses)** menu to appear in the OpenShift web console. A console refresh may be needed.

## Step 3: Create a Global Thanos Querier Datasource

Connect Perses to the platform Thanos Querier so dashboards can query Prometheus metrics cluster-wide. This uses Kubernetes-native authentication — the Perses server's ServiceAccount authenticates to Thanos Querier using its projected token.

The manifest includes a `ClusterRoleBinding` that grants the Perses ServiceAccount the `cluster-monitoring-view` role, and a `PersesGlobalDatasource` that configures the connection.

```bash
oc apply -f 09-observability/09b-dashboards/datasource.yaml
```

<details>
<summary>datasource.yaml</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: perses-sa-cluster-monitoring-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: perses-sa
    namespace: openshift-cluster-observability-operator
---
apiVersion: perses.dev/v1alpha2
kind: PersesGlobalDatasource
metadata:
  name: thanos-querier-datasource
spec:
  config:
    display:
      name: "Thanos Querier"
    default: true
    plugin:
      kind: "PrometheusDatasource"
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            secret: thanos-querier-datasource-secret
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  client:
    kubernetesAuth:
      enable: true
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
```
</details>

Key configuration:

- `proxy.spec.secret` — references the Perses GlobalSecret (auto-created by the operator from the `client` section) that carries the TLS configuration for outbound proxy connections to Thanos Querier. Without this reference, the proxy ignores the TLS settings and fails with certificate errors.
- `client.kubernetesAuth.enable: true` — the Perses server uses its projected ServiceAccount token as a Bearer token when proxying requests to Thanos
- `client.tls.caCert` — points to the OpenShift service CA certificate mounted in the Perses pod, used to verify the Thanos Querier TLS certificate
- `config.default: true` — makes this the default metrics datasource for all dashboards
- The `ClusterRoleBinding` grants the `perses-sa` ServiceAccount read access to monitoring data

Verify:

```bash
oc get persesglobaldatasources
# NAME                        AGE
# thanos-querier-datasource   ...
```

## Step 4: Deploy the Connectivity Link Dashboard

Apply a `PersesDashboard` CR that visualises Connectivity Link metrics. The dashboard is namespace-scoped and deployed to `kuadrant-system`.

```bash
oc apply -f 09-observability/09b-dashboards/dashboard.yaml
```

<details>
<summary>dashboard.yaml — panels and layout</summary>

The dashboard includes four sections:

**Summary** — Stat panels showing total hits, allowed, denied, and errors at a glance.

**Request Traffic** — Time series charts for:
- `sum(rate(kuadrant_hits[$interval]))` — total request rate through the policy engine
- `sum(rate(kuadrant_allowed[$interval]))` vs `sum(rate(kuadrant_denied[$interval]))` — allowed vs denied breakdown

**Rate Limiting** — Time series chart for Limitador decisions:
- `sum(rate(authorized_calls[$interval]))` — requests that passed rate limiting
- `sum(rate(limited_calls[$interval]))` — requests that were rate-limited (429)

**Gateway & Components** — Table of Gateway API resources and a time series of component readiness.

A `$interval` variable (1m / 5m / 15m) controls the rate window for all panels.
</details>

Verify:

```bash
oc get persesdashboards -n kuadrant-system
# NAME                         AGE
# connectivity-link-overview   ...
```

## Step 5: Access the Dashboard

1. Open the OpenShift web console
2. Navigate to **Observe → Dashboards (Perses)**
3. Select the **kuadrant-system** project from the namespace dropdown
4. Click **Connectivity Link Overview**

> **Tip:** If the dashboard shows no data, generate traffic by sending requests through the gateway:
>
> ```bash
> TOKEN=$(curl -sk "https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial/protocol/openid-connect/token" \
>   -d "grant_type=password&client_id=tutorial-app&client_secret=tutorial-app-secret&username=testuser&password=testuser" \
>   | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
>
> for i in $(seq 1 10); do
>   curl -sk "https://echo.${CLUSTER_DOMAIN}/" -H "Authorization: Bearer $TOKEN"
> done
> ```
>
> Wait 1–2 minutes for Prometheus to scrape the new metrics, then refresh the dashboard.

## Customising the Dashboard

Since the dashboard is a Kubernetes CR, you can edit it directly:

```bash
# Export the current dashboard
oc get persesdashboard connectivity-link-overview -n kuadrant-system -o yaml > my-dashboard.yaml

# Edit, then re-apply
oc apply -f my-dashboard.yaml
```

You can also edit dashboards interactively in the OpenShift console — changes are saved back to the `PersesDashboard` resource.

### Importing Grafana Dashboards

The Kuadrant upstream project provides Grafana dashboards on [grafana.com](https://grafana.com/grafana/dashboards/) (IDs: 21538, 20981, 20982). You can import these into Perses:

1. Navigate to **Observe → Dashboards (Perses)**
2. Click **Create** → **Import**
3. Paste the Grafana dashboard JSON
4. Review and adjust datasource references
5. Click **Import**

> **Note:** Not all Grafana panel types convert automatically. Review imported dashboards and adjust as needed.

## Verify

- [ ] COO CSV shows `Succeeded` in `openshift-cluster-observability-operator`
- [ ] `oc get crds | grep perses` shows `persesdashboards`, `persesdatasources`, `persesglobaldatasources`
- [ ] `oc get uiplugin monitoring` shows `Plugin reconciled successfully`
- [ ] `oc get pods -n openshift-cluster-observability-operator` shows `perses-0` and `perses-operator` running
- [ ] `oc get persesglobaldatasources` shows `thanos-querier-datasource`
- [ ] `oc get persesdashboards -n kuadrant-system` shows `connectivity-link-overview`
- [ ] Dashboard is visible in the OpenShift console under **Observe → Dashboards (Perses)**

---

Previous: [09a — Metrics & Monitoring](../09a-metrics-monitoring/README.md)
Next: [09c — Tracing (Optional)](../09c-tracing/README.md)
