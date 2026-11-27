# Preparing the subaccount and landscape

Manual, one-time setup a human must complete **before** Flux reconciles the `odg-infra`
chart. The chart adopts a pre-existing BTP subaccount and consumes resources that are
provisioned out-of-band here (IAS tenant, provider credentials, some BTP entitlements). The
chart itself is documented in the [README](../README.md).

Do these in order:

1. [Provider credential secrets](#provider-credential-secrets)
2. [SAP Cloud Identity Services (IAS) tenant](#sap-cloud-identity-services-ias-tenant)
3. [Cloud Logging OpenSearch Dashboards SSO (IAS SAML 2.0)](#cloud-logging-opensearch-dashboards-sso-ias-saml-20)
4. [Shoot cluster access via IAS OIDC](#shoot-cluster-access-via-ias-oidc)
5. [PostgreSQL entitlements and manual instances](#postgresql-entitlements-and-manual-instances)

## Provider credential secrets

Create these in the `manual-secrets` namespace on the control plane. They hold the
credentials the Crossplane providers use and are managed out-of-band (never in git):

| Secret | Key | Purpose |
|--------|-----|---------|
| `cis-provider-secret` | `data` | CIS credentials for the BTP provider |
| `sa-provider-secret` | `credentials` | Service account credentials for the BTP provider |
| `gardener-kubeconfig` | `kubeconfig` | Service account kubeconfig for the Gardener API (garden namespace) |

## SAP Cloud Identity Services (IAS) tenant

The IAS tenant is managed manually (not by the chart). Enter the tenant host once under
`ias.tenantHost` (e.g. `afxpmzrgq.accounts400.ondemand.com`); it is the single source of
truth for the IAS-backed features below, which derive their URLs from it:

- SAML IdP metadata URL = `https://<ias.tenantHost>/saml2/metadata`
- SAML IdP entity ID = `https://<ias.tenantHost>`
- OIDC issuer = `https://<ias.tenantHost>/`

Each feature can override its URL explicitly (`cloudLogging.saml.idp.metadataUrl` /
`.entityId`, `shootOidc.issuerUrl`) if a landscape is unusual, but normally you only set
`ias.tenantHost` plus the per-application identifiers.

Request the tenant once per landscape: in the BTP cockpit or SAP for Me go to Services >
Service Marketplace > Cloud Identity Services > `additional-tenant` plan > Create, as a
**named administrator** (a human request triggers the activation email that makes that user
the tenant's initial administrator). Activate from the email, then put the tenant host in
`ias.tenantHost`.

## Cloud Logging OpenSearch Dashboards SSO (IAS SAML 2.0)

OpenSearch Dashboards can use IAS SAML 2.0 single sign-on. The IAS tenant and the SAML
application are set up **manually**; the chart only writes the resulting `saml` parameters
onto the Cloud Logging instance. This uses SAML **OPTION 2** (no request signing), so **no
secret is involved**: every value is non-secret and lives in the `odg-infra-values`
ConfigMap.

Manual setup (once per landscape):

1. Create a SAML 2.0 application in the IAS tenant. Note its `Entity ID` (this is
   `cloudLogging.saml.spEntityId`).
2. Configure the application: define a self-asserted `groups` user attribute so group
   membership is emitted (maps to `roles_key: groups`), set Default Name ID Format = Email.
3. Set the Assertion Consumer Service endpoint to
   `https://<dashboards-endpoint>/_opendistro/_security/saml/acs` and the Single Logout
   endpoint (HTTP-Redirect) to `https://<dashboards-endpoint>` (no trailing path). Read
   `<dashboards-endpoint>` from the `cloud-logging-credentials` secret (`dashboards-endpoint`
   key). This step can only be done after the Cloud Logging instance exists.
4. Create the admin group (`cloudLogging.saml.admin_group`, default `CLS_Admin`) and assign
   the users who should get OpenSearch Dashboards `all_access`.

Chart configuration: set `cloudLogging.saml.enabled: true` and fill in the `saml` block
under `cloudLogging.saml` (`initiated`, `roles_key`, `admin_group`, `spEntityId`). The IdP
URLs come from `ias.tenantHost`. The chart passes the `saml` block to the Cloud Logging
instance parameters. No Secret and no `parameterSecretRefs` are created.

## Shoot cluster access via IAS OIDC

Set `shootOidc.enabled: true` to let users authenticate to the shoots' kube-apiserver with
tokens from the manual IAS tenant, with an IAS group driving Kubernetes group membership.
The chart uses Kubernetes Structured Authentication (k8s >= 1.30): for each shoot it renders
an `AuthenticationConfiguration` ConfigMap into the garden namespace and sets
`spec.kubernetes.kubeAPIServer.structuredAuthentication.configMapName` on the shoot to
reference it. No secret is involved; the kube-apiserver only validates tokens.

Manual IAS setup (once per landscape):

1. In the IAS tenant, create an **OpenID Connect application** for shoot access. Note the
   client id (this is the token `audiences` value). The issuer is `https://<ias.tenantHost>/`
   and must match the token `iss` claim (including trailing slash).
2. Add a self-defined `groups` attribute to the application so group membership is emitted
   in the token, and set the subject/Name ID to email.
3. Create the IAS group (e.g. `Shoot-Admin`) and assign the users who should get access.
4. Users authenticate with an OIDC `kubectl` plugin (e.g. `kubectl oidc-login` /
   `kubelogin`) against the IAS issuer and client id.

Chart configuration: set `shootOidc.enabled: true` and supply `clientID` (and optionally the
claim names/prefixes). The issuer is derived from `ias.tenantHost`. With the defaults, an IAS
user `jane@sap.com` in group `Shoot-Admin` is seen by the shoot apiserver as username
`ias:jane@sap.com` in group `ias:Shoot-Admin`.

Manual RBAC (once per shoot): the OIDC config only authenticates; it grants no permissions.
Bind the prefixed group to a role in each shoot cluster, for example:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ias-shoot-admins
subjects:
  - kind: Group
    name: "ias:Shoot-Admin"      # groupsPrefix + IAS group name
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin           # or a narrower role
  apiGroup: rbac.authorization.k8s.io
```

Apply it with a shoot `adminkubeconfig` (see Gardener docs). Changing the ConfigMap later is
picked up on the next shoot reconciliation, which is not automatically triggered.

## PostgreSQL entitlements and manual instances

The chart can provision a database per shoot (`postgres.enabled: true`, see the README). The
BTP-side entitlements and any manually created instances are prepared here.

### Entitlements (two SKUs)

PostgreSQL on SAP BTP (hyperscaler option, SCI regions) requires **two** entitlements per the
SAP sizing table, not one:

- the **compute** SKU, the chosen plan (`standard` or `premium`)
- a separate **storage** SKU (`storage`, or `storage_ha` for multi-AZ)

Units are counted **per instance**, not by disk GB (disk is an in-instance parameter set in
5 GB blocks via `storageGB`). Compute units scale with RAM: for `standard`, each instance
consumes `memory / 2` compute units (2 GB RAM -> 1, 4 GB RAM -> 2). Multi-AZ doubles the
compute SKU and switches the storage SKU to `storage_ha`. The storage SKU is 1 unit per
instance.

Example: two single-AZ `standard` instances at 2 GB RAM need `standard: 2` and `storage: 2`.

The chart's `postgres.yaml` renders both `Entitlement` objects with these amounts derived
from `shoots`, `postgres.memory`, `postgres.plan`, and `postgres.multiAz`. The **global
account** must hold enough quota of each SKU to assign to the subaccount, otherwise the
`Entitlement` fails to sync with a quota error (`Code 30009`). Request global-account quota
for both the compute and storage SKUs before enabling postgres.

### Manually created instances (access control)

When creating a PostgreSQL instance by hand (cockpit or CF), two instance parameters control
reachability:

- `public_access` (boolean, default `true`): whether the instance has a public endpoint.
- `allow_access` (string): comma-separated source IPs and CF landscape domains allowed to
  connect. **Empty blocks all public access.** The broker rejects `allow_access` unless
  `public_access: true` is also set (`Must set public_access to true if allow_access is
  provided`).

Gardener shoots are **not** Cloud Foundry, so the default CF-landscape-domain allowance does
not cover them. You must list each shoot's **egress IP** (the source IP the database
observes) in `allow_access`, together with `public_access: true`.

Read each shoot's egress CIDR from its `Shoot` status (Gardener surfaces
`status.networking.egressCIDRs`). From the control plane, via the Crossplane `Object`:

```bash
kubectl get object.kubernetes.crossplane.io shoot-<name> -o json \
  | jq -r '.status.atProvider.manifest.status.networking.egressCIDRs[]'
```

Enter the bare IPs comma-separated, e.g. `allow_access: 10.190.102.96,10.190.101.247`.

Caveat: the correct value is the source IP **as the database sees it**. If shoot-to-database
traffic leaves via a public NAT, the database observes that public NAT IP, not the private
`egressCIDRs`, and a private-IP allowlist would block the shoots. Confirm by connecting from
inside a shoot (e.g. `curl ifconfig.me` from a pod) and use whichever IP the database
actually receives. `egressCIDRs` can also change if a shoot's infrastructure is recreated.
