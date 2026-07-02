# 10 — Cleanup

## What you'll do

Remove all resources created by this tutorial from your OpenShift cluster.

## Prerequisites

- `oc` CLI authenticated with `cluster-admin` access
- Completed (or partially completed) the tutorial sections

## Cleanup

Run the cleanup script:

```shell
./10-cleanup/cleanup.sh
```

The script will:

1. Show a warning listing all components that will be removed
2. Ask for explicit confirmation before proceeding
3. Remove resources in reverse order (observability → policies → app → gateway → operators)

## What gets removed

| Component | Action |
|-----------|--------|
| Access log Telemetry CR | Deleted |
| Distributed Tracing UI Plugin | Deleted |
| EnvoyFilter, OTel Collectors, Instrumentation | Deleted |
| TempoStack + ObjectBucketClaim | Deleted |
| Tempo Operator | Uninstalled |
| Red Hat build of OpenTelemetry Operator | Uninstalled |
| Cluster Observability Operator + dashboards | Uninstalled |
| User workload monitoring ConfigMap | Deleted (reverts to default) |
| RateLimitPolicy, AuthPolicy | Deleted |
| Keycloak + RHBK Operator (`tutorial-keycloak` namespace) | Uninstalled |
| TLSPolicy, certificates, TLS route | Deleted |
| Tutorial application (`tutorial-app` namespace) | Deleted |
| Gateway and OpenShift Routes | Deleted |
| ClusterIssuer (`selfsigned-cluster-issuer`) | Deleted |
| Red Hat Connectivity Link Operator | Uninstalled |
| `kuadrant-system` namespace | Deleted |

## What is NOT removed

- **OpenShift Data Foundation (ODF)** — only the ObjectBucketClaim is deleted, not the operator
- **cert-manager Operator for Red Hat OpenShift** — only the ClusterIssuer is deleted
- **Pre-existing Keycloak** in the `keycloak` namespace (workshop SSO) — the tutorial uses a separate `tutorial-keycloak` namespace
- **OpenShift cluster** itself

## OpenShift console login

This tutorial deploys Keycloak in its own `tutorial-keycloak` namespace and does **not** touch the `keycloak` namespace or the `sso.${CLUSTER_DOMAIN}` hostname used for OpenShift console login.

If console login is broken after an earlier tutorial run (prior to this fix) that modified the `keycloak` namespace:

1. Restore the Keycloak hostname: `oc patch keycloak keycloak -n keycloak --type=merge -p '{"spec":{"hostname":{"hostname":"sso.<your-cluster-domain>"}}}'`
2. Restore the route: `oc patch route keycloak -n keycloak --type=merge -p '{"spec":{"host":"sso.<your-cluster-domain>"}}'`
3. Wait for Keycloak to reconcile: `oc wait keycloak/keycloak -n keycloak --for=condition=Ready --timeout=120s`

## Stuck namespaces

A namespace stuck in `Terminating` usually means a resource still has finalizers. Common blockers:

| Namespace | Typical blocker |
|-----------|-----------------|
| `tempo` | `TempoStack`, `ObjectBucketClaim`, or OLM CSV |
| `tutorial-keycloak` | `Keycloak` or `KeycloakRealmImport` CR |
| `kuadrant-system` | `Kuadrant` CR or OLM CSV |

The cleanup script waits for deletions, clears finalizers on stuck resources, and force-cleans remaining objects before removing namespace finalizers.

### Manual recovery

```shell
oc get all,tempostack,objectbucketclaim,csv -n tempo
oc patch tempostack tempostack -n tempo -p '{"metadata":{"finalizers":null}}' --type=merge
oc delete tempostack tempostack -n tempo --grace-period=0 --force
oc patch namespace tempo --type=json -p='[{"op":"replace","path":"/spec/finalizers","value":[]}]'
```

Re-run the cleanup script after manual fixes — it is safe to run more than once.

