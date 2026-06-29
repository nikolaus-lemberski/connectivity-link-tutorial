# 06 — Keycloak Setup (OIDC Identity Provider)

**What you'll learn:** Install the Red Hat build of Keycloak operator, deploy a Keycloak instance with PostgreSQL, and configure an OIDC realm with a client and test user for API authentication.

**Prerequisites:** Phases 00–05 completed (Gateway with TLS, echo app running).

## Architecture

Keycloak provides the OIDC identity provider that AuthPolicy (Phase 07) will use to validate JWT tokens:

```
┌────────────┐  1. get token  ┌───────────┐  2. request + Bearer token  ┌──────────────┐
│   Client   │ ──────────────►│ Keycloak  │                             │   Gateway    │
│            │◄──────────────┐│  (OIDC)   │                             │   (Envoy)    │
│            │  access_token ││           │    3. verify JWT (JWKS)     │              │
│            │               │└───────────┘◄────────────────────────────│  AuthPolicy  │
│            │               │                                          │              │
│            │───────────────┼─────────────────────────────────────────►│              │
│            │               │                                          │              │
└────────────┘               │                                          └──────┬───────┘
                             │                                                 │
                             │                                                 ▼
                             │                                          ┌──────────────┐
                             │                                          │  echo Service│
                             └──────────────────────────────────────────└──────────────┘
```

## Step 1: Create the Keycloak Namespace

```bash
oc apply -f 06-keycloak/namespace.yaml
```

## Step 2: Install the Red Hat build of Keycloak Operator

The operator is installed from the `redhat-operators` catalog on the `stable-v26.4` channel:

```bash
oc apply -f 06-keycloak/subscription.yaml
```

Wait for the operator to install:

```bash
oc wait csv -n keycloak -l operators.coreos.com/rhbk-operator.keycloak --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Step 3: Deploy PostgreSQL for Keycloak

Keycloak requires a database backend. Deploy a PostgreSQL instance with persistent storage:

```bash
export KEYCLOAK_DB_PASSWORD=$(openssl rand -base64 12)
envsubst < 06-keycloak/postgres.yaml | oc apply -f -
```

> **Note:** Save `KEYCLOAK_DB_PASSWORD` if you need to recreate the secret later.

Wait for PostgreSQL to become ready:

```bash
oc rollout status deployment/keycloak-pgsql -n keycloak --timeout=120s
```

## Step 4: Deploy Keycloak

The Keycloak CR creates a single-instance server with:
- PostgreSQL backend (from Step 3)
- TLS via OpenShift service-serving certificates
- Ingress disabled (we use an OpenShift Route instead)

The manifest also creates a re-encrypt Route so the OpenShift router terminates external TLS and re-encrypts to the Keycloak pod:

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

envsubst < 06-keycloak/keycloak.yaml | oc apply -f -
```

Wait for Keycloak to become ready:

```bash
oc wait keycloak/keycloak -n keycloak --for=condition=Ready --timeout=300s
```

Verify the Keycloak Route:

```bash
oc get route keycloak -n keycloak
```

Test access to the Keycloak admin console:

```bash
curl -sk -o /dev/null -w "%{http_code}" https://sso.${CLUSTER_DOMAIN}/
# Should return 200
```

## Step 5: Retrieve the Keycloak Admin Credentials

The operator generates initial admin credentials in a Secret:

```bash
oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d && echo
```

You can use these to log in to the Keycloak admin console at `https://sso.${CLUSTER_DOMAIN}/admin`.

## Step 6: Create the Tutorial Realm

The `KeycloakRealmImport` CR creates everything the tutorial needs in one shot:

- **Realm:** `connectivity-link-tutorial`
- **OIDC Client:** `tutorial-app` (confidential, client secret: `tutorial-app-secret`)
- **Test User:** `testuser` / `testuser` (password) with the `user` realm role

```bash
oc apply -f 06-keycloak/keycloak-realm.yaml
```

Wait for the realm import to complete:

```bash
oc wait keycloakrealmimport/connectivity-link-tutorial -n keycloak \
  --for=jsonpath='{.status.conditions[?(@.type=="Done")].status}'=True \
  --timeout=120s
```

## Step 7: Verify OIDC Token Retrieval

Test the OIDC token endpoint using the Resource Owner Password Credentials grant:

```bash
export KEYCLOAK_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')

curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/connectivity-link-tutorial/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=tutorial-app" \
  -d "client_secret=tutorial-app-secret" \
  -d "username=testuser" \
  -d "password=testuser"
```

You should receive a JSON response with an `access_token`. Save it for testing:

```bash
export TOKEN=$(curl -sk -X POST "https://${KEYCLOAK_HOST}/realms/connectivity-link-tutorial/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=tutorial-app&client_secret=tutorial-app-secret&username=testuser&password=testuser" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "$TOKEN"
```

> **OIDC Discovery URL** (needed for AuthPolicy in Phase 07):
> `https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial`

## OIDC Configuration Reference

| Parameter | Value |
|-----------|-------|
| Issuer URL | `https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial` |
| Token endpoint | `https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial/protocol/openid-connect/token` |
| JWKS URI | `https://sso.${CLUSTER_DOMAIN}/realms/connectivity-link-tutorial/protocol/openid-connect/certs` |
| Client ID | `tutorial-app` |
| Client secret | `tutorial-app-secret` |
| Test user | `testuser` / `testuser` |

## Verify

- [ ] `oc get keycloak -n keycloak` shows `Ready: True`
- [ ] `oc get keycloakrealmimport -n keycloak` shows `Done: True` for `connectivity-link-tutorial`
- [ ] Token endpoint returns a valid JWT with `iss`, `azp`, and `realm_access.roles` claims

---

Next: [07 — AuthPolicy](../07-auth-policy/)
