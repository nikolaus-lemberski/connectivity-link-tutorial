# 00 — Prerequisites

Before starting this tutorial, ensure you have the following in place.

## What you'll need

| Requirement | Details |
|-------------|---------|
| OpenShift Container Platform | 4.19 or later |
| Cluster access | `cluster-admin` privileges |
| `oc` CLI | Installed and logged in to the cluster |
| `envsubst` | GNU gettext (`brew install gettext` on macOS) |
| `python3` | Used in verification steps |
| Red Hat subscription | Includes Red Hat Connectivity Link entitlement |
| cert-manager Operator | cert-manager Operator for Red Hat OpenShift 1.18+ installed |

## Verify your environment

Confirm you are logged in with cluster-admin access:

```shell
oc whoami
# admin

oc version
# Should show OCP 4.19+
```

Confirm cert-manager Operator is installed:

```shell
oc get csv -A | grep cert-manager
# Should show cert-manager-operator with status "Succeeded"
```

Confirm the `rhcl-operator` package is available in the catalog:

```shell
oc get packagemanifest rhcl-operator -n openshift-marketplace
# NAME            CATALOG           AGE
# rhcl-operator   Red Hat Operators ...
```

## Cluster domain

Several steps in this tutorial reference the cluster's apps domain. Retrieve it now for later use:

```shell
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
# Example: apps.cluster-xxxxx.example.com
```

Store common variables for convenience:

```shell
source export-cluster-env.sh
```

This sets `CLUSTER_DOMAIN` and `KEYCLOAK_HOST` for all subsequent sections.

## Re-running the tutorial

If you ran the tutorial before on the same cluster:

- Use [11 — Cleanup](../11-cleanup/) before starting again, or delete leftover PVCs (especially Keycloak PostgreSQL) manually.
- If Keycloak PostgreSQL already exists in `tutorial-keycloak`, reuse the same `KEYCLOAK_DB_PASSWORD` or delete the PVC before re-applying `06-auth-policy/keycloak/postgres.yaml`.
- The tutorial deploys its own Keycloak in the `tutorial-keycloak` namespace and does **not** modify the `keycloak` namespace or `sso.${CLUSTER_DOMAIN}` hostname used for OpenShift console login.

## Next steps

Proceed to [01 — Install Connectivity Link](../01-install/).
