# 11 — Cleanup

Remove all tutorial resources from your OpenShift cluster.

## Run the cleanup script

```shell
./11-cleanup/cleanup.sh
```

The script shows a warning, asks for confirmation, then removes resources in reverse order (observability → policies → app → gateway → operators). It is safe to run more than once.

> ![WARNING]
> The cleanup script might also remove resources that have been installed prior to this tutorial. Be careful and never use on clusters with real workloads. In doubt, do not use and uninstall the components by yourself.

## What is NOT removed

- **OpenShift Data Foundation (ODF)** — only the ObjectBucketClaim is deleted, not the operator
- **cert-manager Operator** — only the ClusterIssuer is deleted
- **Pre-existing Keycloak** in the `keycloak` namespace — the tutorial uses a separate `tutorial-keycloak` namespace

## Stuck namespaces

A namespace stuck in `Terminating` usually means a resource still has finalizers. The cleanup script handles this automatically, but if needed you can fix it manually:

```shell
oc get all,tempostack,objectbucketclaim,csv -n tempo
oc patch tempostack tempostack -n tempo -p '{"metadata":{"finalizers":null}}' --type=merge
oc delete tempostack tempostack -n tempo --grace-period=0 --force
oc patch namespace tempo --type=json -p='[{"op":"replace","path":"/spec/finalizers","value":[]}]'
```

Re-run the cleanup script after manual fixes.
