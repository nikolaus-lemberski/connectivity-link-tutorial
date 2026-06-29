# 02 — cert-manager Setup

Configure a certificate issuer for TLS certificate management with Connectivity Link.

## What you'll learn

- Verify the cert-manager Operator is installed
- Create a ClusterIssuer for automated TLS certificate provisioning

## Prerequisites

- Completed [01 — Install Connectivity Link](../01-install/)
- cert-manager Operator for Red Hat OpenShift 1.18+ installed

## Steps

### 1. Verify cert-manager is running

Confirm the cert-manager Operator is installed and healthy:

```bash
oc get csv -A | grep cert-manager
# Should show "Succeeded"
```

Check that cert-manager pods are running:

```bash
oc get pods -n cert-manager
```

### 2. Create a ClusterIssuer

For this tutorial, we use a **self-signed** ClusterIssuer for simplicity. This allows Connectivity Link's TLSPolicy to automatically provision certificates without requiring a cloud DNS provider or external CA.

```bash
oc apply -f 02-cert-manager/cluster-issuer.yaml
```

<details>
<summary>cluster-issuer.yaml</summary>

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-cluster-issuer
  labels:
    app.kubernetes.io/part-of: connectivity-link-tutorial
spec:
  selfSigned: {}
```
</details>

> **Production note:** For production environments, use an ACME issuer (such as Let's Encrypt) with DNS-01 or HTTP-01 challenge solvers. See the [cert-manager ACME issuer documentation](https://docs.redhat.com/en/documentation/cert-manager_operator_for_red_hat_openshift/1.18/html/configuring_and_managing_cloud_credentials_and_tls_certificates/cert-manager-acme-issuer) for details.

## Verify

Confirm the ClusterIssuer is ready:

```bash
oc get clusterissuer selfsigned-cluster-issuer
# NAME                        READY   AGE
# selfsigned-cluster-issuer   True    ...
```

## Reference

- [cert-manager Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/cert-manager_operator_for_red_hat_openshift/1.18)
- [Configuring an ACME issuer](https://docs.redhat.com/en/documentation/cert-manager_operator_for_red_hat_openshift/1.18/html/configuring_and_managing_cloud_credentials_and_tls_certificates/cert-manager-acme-issuer)

## Next steps

Proceed to [03 — Create Gateway](../03-gateway/).
