# 00 — Prerequisites

Before starting this tutorial, ensure you have the following in place.

## What you'll need

| Requirement | Details |
|-------------|---------|
| OpenShift Container Platform | 4.19 or later |
| Cluster access | `cluster-admin` privileges |
| `oc` CLI | Installed and logged in to the cluster |
| Red Hat subscription | Includes Red Hat Connectivity Link entitlement |
| cert-manager Operator | cert-manager Operator for Red Hat OpenShift 1.18+ installed |

## Verify your environment

Confirm you are logged in with cluster-admin access:

```bash
oc whoami
admin

oc version
# Should show OCP 4.19+
```

Confirm cert-manager Operator is installed:

```bash
oc get csv -A | grep cert-manager
# Should show cert-manager-operator with status "Succeeded"
```

Confirm the `rhcl-operator` package is available in the catalog:

```bash
oc get packagemanifest rhcl-operator -n openshift-marketplace
# NAME            CATALOG           AGE
# rhcl-operator   Red Hat Operators ...
```

## Cluster domain

Several steps in this tutorial reference the cluster's apps domain. Retrieve it now for later use:

```bash
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
# Example: apps.cluster-xxxxx.example.com
```

Store it as an environment variable for convenience:

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo $CLUSTER_DOMAIN
```

## Next steps

Proceed to [01 — Install Connectivity Link](../01-install/).
