# Keycloak Manual Installation (OIDC Identity Provider)

This guide walks through the manual installation of the Red Hat build of Keycloak for the Connectivity Link tutorial. It deploys Keycloak with PostgreSQL and configures an OIDC realm with a client and test user for API authentication.

> **Prefer the automated setup?** Run `./06-auth-policy/setup-keycloak.sh` from the repository root — it performs all the steps below in one go.

> **Important:** This tutorial deploys its own Keycloak in a dedicated `tutorial-keycloak` namespace. Many workshop clusters already have a Keycloak instance in the `keycloak` namespace at `sso.${CLUSTER_DOMAIN}` for OpenShift console login. The tutorial deliberately uses a **separate namespace and hostname** to avoid interfering with the cluster's authentication.

## Architecture

Keycloak provides the OIDC identity provider that AuthPolicy will use to validate JWT tokens:

```
  ┌──────────┐  1. token request   ┌───────────┐
  │  Client  │ ───────────────────►│ Keycloak  │
  │          │◄────────────────────│  (OIDC)   │
  └────┬─────┘  2. access_token    └─────▲─────┘
       │                                  │ JWKS
       │ 3. GET / + Bearer token          │
       ▼                                  │
  ┌──────────────────────────────────────┴─────┐
  │              Gateway (Envoy)               │
  │              + AuthPolicy                  │
  └────────────────────┬───────────────────────┘
                       │ 4. authenticated request
                       ▼
                ┌──────────────┐
                │ echo Service │
                └──────────────┘
```

## Step 1: Create the Keycloak Namespace

```shell
oc apply -f 06-auth-policy/keycloak/namespace.yaml
```

## Step 2: Install the Red Hat build of Keycloak Operator

The operator is installed from the `redhat-operators` catalog on the `stable-v26.4` channel:

```shell
oc apply -f 06-auth-policy/keycloak/subscription.yaml
```

Wait for the operator to install:

```shell
oc wait csv -n tutorial-keycloak -l operators.coreos.com/rhbk-operator.tutorial-keycloak --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Step 3: Deploy PostgreSQL for Keycloak

Keycloak requires a database backend. Deploy a PostgreSQL instance with persistent storage:

```shell
export KEYCLOAK_DB_PASSWORD=$(openssl rand -base64 12)
envsubst < 06-auth-policy/keycloak/postgres.yaml | oc apply -f -
```

> **Re-run note:** If `keycloak-pgsql-data` PVC already exists from a previous run, either delete the PVC and secret first, or reuse the same `KEYCLOAK_DB_PASSWORD`. A new random password with an existing PVC causes realm import failures.

Wait for PostgreSQL to become ready:

```shell
oc rollout status deployment/keycloak-pgsql -n tutorial-keycloak --timeout=120s
```

## Step 4: Deploy Keycloak

The Keycloak CR creates a single-instance server with:

- PostgreSQL backend (from Step 3)
- TLS via OpenShift service-serving certificates
- Ingress disabled (we use an OpenShift Route instead)
- External hostname `keycloak.${CLUSTER_DOMAIN}`

```shell
source export-cluster-env.sh
envsubst < 06-auth-policy/keycloak/keycloak.yaml | oc apply -f -
```

The RHBK operator creates a service but does not add the OpenShift service-serving certificate annotation. Wait for the operator to create the service, then annotate it to generate the TLS secret:

```shell
until oc get svc tutorial-keycloak-service -n tutorial-keycloak >/dev/null 2>&1; do sleep 3; done

oc annotate service tutorial-keycloak-service -n tutorial-keycloak \
  service.beta.openshift.io/serving-cert-secret-name=tutorial-keycloak-tls

until oc get secret tutorial-keycloak-tls -n tutorial-keycloak >/dev/null 2>&1; do sleep 3; done
```

> **Note:** If you annotate before the service exists, the command fails silently from the tutorial's perspective and Keycloak stays in `ContainerCreating` waiting for the missing `tutorial-keycloak-tls` secret.

Wait for Keycloak to become ready:

```shell
oc wait keycloak/tutorial-keycloak -n tutorial-keycloak --for=condition=Ready --timeout=300s
```

Verify the Keycloak Route:

```shell
oc get route tutorial-keycloak -n tutorial-keycloak
# HOST: keycloak.apps.<cluster-domain>
```

Test access to the Keycloak admin console:

```shell
curl -sk -o /dev/null -w "%{http_code}" https://keycloak.$CLUSTER_DOMAIN/
# Should return 302 (redirect to login page)
```

## Step 5: Retrieve the Keycloak Admin Credentials

The operator generates initial admin credentials in a Secret:

```shell
oc get secret tutorial-keycloak-initial-admin -n tutorial-keycloak -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret tutorial-keycloak-initial-admin -n tutorial-keycloak -o jsonpath='{.data.password}' | base64 -d && echo
```

You can use these to log in to the Keycloak admin console at `https://keycloak.${CLUSTER_DOMAIN}/admin`.

## Step 6: Create the Tutorial Realm

The `KeycloakRealmImport` CR creates everything the tutorial needs in one shot:

- **Realm:** `connectivity-link-tutorial`
- **OIDC Client:** `tutorial-app` (confidential, client secret: `tutorial-app-secret`)
- **Test User:** `testuser` / `testuser` (password) with the `user` realm role

```shell
oc apply -f 06-auth-policy/keycloak/keycloak-realm.yaml
```

Wait for the realm import to complete:

```shell
oc wait keycloakrealmimport/connectivity-link-tutorial -n tutorial-keycloak \
  --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True \
  --timeout=180s
```

## Step 7: Verify OIDC Token Retrieval

Test the OIDC token endpoint using the Resource Owner Password Credentials grant:

```shell
source export-cluster-env.sh
export TOKEN=$(get_token)
echo "$TOKEN"
```

## Verify

- [ ] `oc get keycloak -n tutorial-keycloak` shows `Ready: True`
- [ ] `oc get keycloakrealmimport -n tutorial-keycloak` shows `Done: True` for `connectivity-link-tutorial`
- [ ] Token endpoint returns a valid JWT with `iss`, `azp`, and `realm_access.roles` claims
