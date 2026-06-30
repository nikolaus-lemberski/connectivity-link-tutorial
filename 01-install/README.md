# 01 — Install Red Hat Connectivity Link

Install the Red Hat Connectivity Link Operator and create the Kuadrant operand.

## What you'll learn

- Create the `kuadrant-system` namespace
- Install the RHCL Operator via OLM
- Create the Kuadrant custom resource to instantiate Connectivity Link

## Prerequisites

- Completed [00 — Prerequisites](../00-prerequisites/)

## Steps

### 1. Create the namespace

```bash
oc apply -f 01-install/namespace.yaml
```

<details>
<summary>namespace.yaml</summary>

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kuadrant-system
  labels:
    app.kubernetes.io/part-of: connectivity-link-tutorial
```
</details>

### 2. Create the GatewayClass

On OpenShift 4.19+, the Cluster Ingress Operator serves as the Gateway API controller. You must create a `GatewayClass` named `openshift-default` before Connectivity Link can operate:

```bash
oc apply -f 01-install/gateway-class.yaml
```

<details>
<summary>gateway-class.yaml</summary>

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
  labels:
    app.kubernetes.io/part-of: connectivity-link-tutorial
spec:
  controllerName: openshift.io/gateway-controller/v1
```
</details>

Verify the GatewayClass is created:

```bash
oc get gatewayclass openshift-default
# NAME                CONTROLLER                           ACCEPTED   AGE
# openshift-default   openshift.io/gateway-controller/v1   ...        ...
```

### 3. Install the Operator

Apply the OperatorGroup and Subscription to install the RHCL Operator from the `redhat-operators` catalog:

```bash
oc apply -f 01-install/subscription.yaml
```

<details>
<summary>subscription.yaml</summary>

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: kuadrant-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: rhcl-operator.v1.3.4
```
</details>

Wait for the Operator to install:

```shell
oc wait --for=jsonpath='{.status.installPlanRef.name}' subscription rhcl-operator -n kuadrant-system --timeout=120s
```

Then wait for the install plan to complete:

```shell
IP=$(oc get subscription rhcl-operator -n kuadrant-system -o jsonpath='{.status.installPlanRef.name}')
oc wait --for=condition=Installed installplan ${IP} -n kuadrant-system --timeout=180s
```

> **Version pin:** The subscription uses `startingCSV: rhcl-operator.v1.3.4` to install Red Hat Connectivity Link **1.3**. If a newer version is already installed, delete the existing subscription and CSV in `kuadrant-system`, then re-apply `subscription.yaml`.
>
> **Note:** RHCL may also install the Red Hat OpenShift Service Mesh operator as a dependency.

### 4. Verify the Operator

Confirm the RHCL Operator and its component operators are running:

```bash
oc get csv -n kuadrant-system
```

You should see the following operators with status `Succeeded`:

- **Red Hat Connectivity Link Operator** (`rhcl-operator`)
- **Limitador Operator** — rate limiting
- **Authorino Operator** — authentication and authorization
- **DNS Operator** — DNS management

### 5. Create the Kuadrant resource

Apply the Kuadrant custom resource to instantiate the operand:

```bash
oc apply -f 01-install/kuadrant.yaml
```

<details>
<summary>kuadrant.yaml</summary>

```yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
  labels:
    app.kubernetes.io/part-of: connectivity-link-tutorial
```
</details>

### 6. Wait for Kuadrant to become ready

```bash
oc wait kuadrant/kuadrant --for="condition=Ready=true" -n kuadrant-system --timeout=300s
# kuadrant.kuadrant.io/kuadrant condition met
```

> **Note:** If the Kuadrant CR reports `MissingDependency` for a gateway provider, ensure the `openshift-default` GatewayClass exists (step 2), then restart the operator pod:
> ```bash
> oc delete pod -n kuadrant-system -l app=kuadrant -l app.kubernetes.io/component=manager
> ```

## Verify

Confirm the Kuadrant resource is ready:

```bash
oc get kuadrant -n kuadrant-system
# NAME       STATUS   AGE
# kuadrant   True     ...
```

Check that all pods in the namespace are running:

```bash
oc get pods -n kuadrant-system
```

## Reference

- [Installing Connectivity Link (Red Hat docs)](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/installing_on_openshift_container_platform/rhcl-install-on-ocp)

## Next steps

Proceed to [02 — cert-manager Setup](../02-cert-manager/).
