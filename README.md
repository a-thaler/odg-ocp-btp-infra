# ODG GitOps Infrastructure

Control plane infrastructure for Open Delivery Gear (ODG) environments, packaged as a
single Helm chart, published as a signed OCI artifact, and deployed by Flux. One chart
(`charts/odg-infra`) renders all BTP and Gardener resources; landscape-specific values
are supplied as an override (see `examples/values.example.yaml`) delivered to the chart
as a ConfigMap, kept out of git.

## Structure

```
charts/
└── odg-infra/
    ├── Chart.yaml
    ├── values.yaml                 # Defaults + documented required (empty "") fields
    └── templates/
        ├── _helpers.tpl
        ├── btp-subaccount/         # ProviderConfig, Subaccount, Entitlements, ServiceManager, CloudManagement
        ├── btp-services/           # Cloud Logging, Audit Log, Audit Log Viewer, role assignments, IAS
        ├── gardener/               # Kubernetes ProviderConfig, RBAC, audit policy + auditlog credentials Objects
        └── shoots/                 # Gardener Shoot Objects (one per shoots[] entry)
flux/                               # committed Flux resources
├── ocirepository.yaml              # OCIRepository: pulls signed chart from GHCR + cosign verify
├── helmrelease.yaml                # HelmRelease: installs chart, reads values via valuesFrom
└── kustomization.yaml              # bundles the two above
examples/
└── values.example.yaml            # template landscape override (copy, fill in, keep out of git)
.github/workflows/
├── ci.yaml                         # entrypoint: compute version, call build.yaml (secrets: inherit)
└── build.yaml                      # package, push, cosign key-sign the chart
```

## Resources

| Resource | Purpose |
|----------|---------|
| **BTP Subaccount** | Pre-existing subaccount (adopted, `deletionPolicy: Orphan`) |
| **ServiceManager** | Required for provisioning BTP services |
| **CloudManagement** | Required for subscriptions (Audit Log Viewer) |
| **Cloud Logging** | Centralized logging (OpenTelemetry ingest enabled) |
| **Audit Log Service** | Kubernetes API audit logs streamed to BTP |
| **Audit Log Viewer** | UI + per-user `Auditlog Viewer` role collection assignments |
| **Cloud Logging SAML SSO** | Optional (`cloudLogging.saml.enabled`): sets SAML 2.0 parameters on the Cloud Logging instance so OpenSearch Dashboards use IAS single sign-on. The IAS tenant and SAML application are created manually; see below |
| **Gardener ProviderConfig + RBAC** | Lets the Crossplane kubernetes provider manage Shoots and read BTP resources |
| **Shared audit resources** | One `audit-policy` ConfigMap + `auditlog-credentials` Secret in the garden namespace |
| **Gardener Shoot** | Kubernetes cluster on OpenStack (cilium networking) |
| **Shoot OIDC access** | Optional (`shootOidc.enabled`): per-shoot Structured Authentication ConfigMap trusting the IAS tenant, so users access the kube-apiserver with IAS tokens; RBAC applied manually; see below |
| **PostgreSQL per shoot** | Optional (`postgres.enabled`): one `postgresql-db` (SCI) ServiceInstance + ServiceBinding per shoot, plus the subaccount entitlement (scaled by shoot count). Connection secret `postgres-<shoot>-credentials`; see below |

## Values

Landscape-specific configuration is an override on top of the chart defaults in
`charts/odg-infra/values.yaml`. Copy `examples/values.example.yaml`, fill it in, and
supply it as the `odg-infra-values` ConfigMap (see Prerequisites / Flux deployment).

## SAP Cloud Identity Services (IAS)

The IAS tenant is managed manually (not by the chart). Enter the tenant host once under
`ias.tenantHost` (e.g. `afxpmzrgq.accounts400.ondemand.com`); it is the single source of
truth for the IAS-backed features below. They derive their URLs from it:

- SAML IdP metadata URL = `https://<ias.tenantHost>/saml2/metadata`
- SAML IdP entity ID = `https://<ias.tenantHost>`
- OIDC issuer = `https://<ias.tenantHost>/`

Each feature can still override its URL explicitly (`cloudLogging.saml.idp.metadataUrl` /
`.entityId`, `shootOidc.issuerUrl`) if a landscape is unusual, but normally you only set
`ias.tenantHost` plus the per-application identifiers.

## Cloud Logging OpenSearch Dashboards SSO (IAS SAML 2.0)

OpenSearch Dashboards can use IAS SAML 2.0 single sign-on. The IAS tenant and the SAML
application are set up **manually**; the chart only writes the resulting `saml` parameters
onto the Cloud Logging instance. This uses SAML **OPTION 2** (no request signing), so **no
secret is involved**, every value is non-secret and lives in the `odg-infra-values`
ConfigMap.

**Manual setup (once per landscape):**

1. Request the IAS `additional-tenant` as a **named administrator** via the BTP cockpit or
   SAP for Me (Services > Service Marketplace > Cloud Identity Services > `additional-tenant`
   plan > Create). Only a request made by a human user triggers an activation email, making
   that user the tenant's initial administrator. Activate your account from the email. Put
   the tenant host in `ias.tenantHost`.
2. Create a SAML 2.0 application in IAS. Note its `Entity ID` (this is `cloudLogging.saml.spEntityId`).
3. Configure the application: define a self-asserted `groups` user attribute so group
   membership is emitted (maps to `roles_key: groups`), set Default Name ID Format = Email.
4. Set the Assertion Consumer Service endpoint to
   `https://<dashboards-endpoint>/_opendistro/_security/saml/acs` and the Single Logout
   endpoint (HTTP-Redirect) to `https://<dashboards-endpoint>` (no trailing path). Read
   `<dashboards-endpoint>` from the `cloud-logging-credentials` secret (`dashboards-endpoint`
   key). This step can only be done after the Cloud Logging instance exists.
5. Create the admin group (`cloudLogging.saml.admin_group`, default `CLS_Admin`) and assign
   the users who should get OpenSearch Dashboards `all_access`.

**Chart configuration:** set `cloudLogging.saml.enabled: true` and fill in the `saml` block
under `cloudLogging.saml` (`initiated`, `roles_key`, `admin_group`, `spEntityId`). The IdP
URLs come from `ias.tenantHost`. The chart passes the `saml` block to the Cloud Logging
instance parameters. No Secret and no `parameterSecretRefs` are created.

## Shoot cluster access via IAS OIDC (Structured Authentication)

Set `shootOidc.enabled: true` to let users authenticate to the shoots' kube-apiserver with
tokens from the manual IAS tenant, with an IAS group driving Kubernetes group membership.
The chart uses Kubernetes Structured Authentication (k8s >= 1.30): for each shoot it renders
an `AuthenticationConfiguration` ConfigMap into the garden namespace and sets
`spec.kubernetes.kubeAPIServer.structuredAuthentication.configMapName` on the shoot to
reference it. No secret is involved, the kube-apiserver only validates tokens.

**Manual IAS setup (once per landscape):**

1. In the IAS tenant, create an **OpenID Connect application** for shoot access. Note the
   client id (this is the token `audiences` value). The issuer is `https://<ias.tenantHost>/`
   and must match the token `iss` claim (including trailing slash).
2. Add a self-defined `groups` attribute to the application so group membership is emitted
   in the token, and set the subject/Name ID to email.
3. Create the IAS group (e.g. `Shoot-Admin`) and assign the users who should get access.
4. Users authenticate with an OIDC `kubectl` plugin (e.g. `kubectl oidc-login` /
   `kubelogin`) against the IAS issuer and client id.

**Chart configuration:** set `shootOidc.enabled: true` and supply `clientID` (and optionally
the claim names/prefixes). The issuer is derived from `ias.tenantHost`. With the defaults, an
IAS user `jane@sap.com` in group `Shoot-Admin` is seen by the shoot apiserver as username
`ias:jane@sap.com` in group `ias:Shoot-Admin`.

**Manual RBAC (once per shoot):** the OIDC config only authenticates; it grants no
permissions. Bind the prefixed group to a role in each shoot cluster, for example:

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

Apply it with a shoot `adminkubeconfig` (see Gardener docs). Changing the ConfigMap later
is picked up on the next shoot reconciliation, which is not automatically triggered.

## PostgreSQL database per shoot

Set `postgres.enabled: true` to provision one PostgreSQL database (`postgresql-db`,
hyperscaler option, SCI) for every entry in `shoots`. For each shoot the chart renders a
`ServiceInstance` named `postgres-<shoot>` and a `ServiceBinding` that writes the
connection details (host, port, user, password, database, TLS) to the Secret
`postgres-<shoot>-credentials` in `secrets.outputNamespace`. Applications on that shoot
consume the secret (replicate it into the shoot, or read it from the control plane).

The chart also requests the subaccount compute **entitlement** for the plan
`postgres.plan` (`standard`), amount = number of shoots (doubled when
`postgres.multiAz: true`). This landscape's `postgresql-db` offering exposes only the
`standard` plan; storage is set through the `storageGB` instance parameter, not a separate
entitlement SKU.

The global account must have quota for the plan. `postgres.enabled: true` with an empty
`shoots` list fails rendering on purpose (nothing to attach a database to).

Provisioning parameters map to the SAP service: `memory` (GB, standard allows 2 or 4),
`storageGB` (multiple of 5), `engineVersion` (SCI: 15 or 17), `multiAz`, and
`backupRetentionDays` (SCI range 0 to 14). SCI does not support engine-version upgrades or
single-AZ to multi-AZ conversion after creation.

## Prerequisites (control plane)

These must exist on the control plane before Flux reconciles the chart. Flux (source +
helm controllers) is assumed already running in `flux-system`.

Manual secrets in the `manual-secrets` namespace (credentials for the Crossplane providers,
managed out-of-band):

| Secret | Key | Purpose |
|--------|-----|---------|
| `cis-provider-secret` | `data` | CIS credentials for the BTP provider |
| `sa-provider-secret` | `credentials` | Service account credentials for the BTP provider |
| `gardener-kubeconfig` | `kubeconfig` | Service account kubeconfig for the Gardener API (garden namespace) |

Objects in `flux-system` that the OCIRepository / HelmRelease depend on (created by the
deploy steps below):

| Object | Kind | Purpose |
|--------|------|---------|
| `ghcr-pull` | Secret (dockerconfigjson) | Pulls the chart from the private GHCR package |
| `cosign-pub` | Secret | Public key for the OCIRepository cosign verify; missing → `SourceVerified=False` |
| `odg-infra-values` | ConfigMap | Non-secret landscape override the HelmRelease reads via `valuesFrom` |
| `odg-infra-secret-values` | Secret (optional) | Any sensitive landscape values, merged on top of the ConfigMap. Not needed for the SAML OPTION 2 SSO, which has no secret |

When `cloudLogging.saml.enabled` is set, the IAS tenant and SAML application must already
exist and their values be supplied (see "Cloud Logging OpenSearch Dashboards SSO" above).
The chart does not create them.

## Rendering and validation

```bash
# Replace my-values.yaml with your landscape override (copy of examples/values.example.yaml).

# Lint
helm lint charts/odg-infra -f my-values.yaml

# Render
helm template odg-infra charts/odg-infra -f my-values.yaml

# Server-side dry-run against the control plane
helm template odg-infra charts/odg-infra -f my-values.yaml \
  | kubectl apply --dry-run=server -f -
```

## Flux deployment

The chart is published as a signed OCI artifact at
`ghcr.io/a-thaler/odg/charts/odg-infra`. Flux pulls it with an `OCIRepository` and
installs it with a `HelmRelease`, both in `flux/` (committed). The landscape override is
delivered as the `odg-infra-values` ConfigMap, read by the HelmRelease via `valuesFrom`
(an optional `odg-infra-secret-values` Secret can be layered on top for any sensitive
values; later sources win on key collisions).

Deploy order (prerequisites from the section above; `my-values.yaml` is your landscape
override, a filled-in copy of `examples/values.example.yaml`):

```bash
# 1. GHCR pull secret (the package is private). Skip if you make the package public.
kubectl -n flux-system create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=a-thaler \
  --docker-password='<ghcr-pat-with-read:packages>'

# 2. Cosign public key secret for the OCIRepository verify block.
kubectl -n flux-system create secret generic cosign-pub \
  --from-file=cosign.pub=cosign.pub \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Landscape override as a ConfigMap (the HelmRelease reads it via valuesFrom).
kubectl -n flux-system create configmap odg-infra-values \
  --from-file=values.yaml=my-values.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# 3b. OPTIONAL: any sensitive landscape values as a Secret, kept out of the ConfigMap.
#     my-secret-values.yaml is a minimal values file with only the sensitive keys.
#     The SAML OPTION 2 SSO needs no secret, so skip this unless you have other sensitive
#     overrides.
kubectl -n flux-system create secret generic odg-infra-secret-values \
  --from-file=values.yaml=my-secret-values.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. The committed Flux resources (OCIRepository + HelmRelease).
kubectl apply -k flux

# 5. Watch reconciliation.
flux get ocirepository odg-infra
flux get helmrelease odg-infra
```

Updating landscape values later: edit your override, re-run step 3, then
`flux reconcile helmrelease odg-infra`. Publishing a new chart version: bump the
`ref.tag` in `flux/ocirepository.yaml` to the new published tag.

## Signing and verification

The publish workflow (`.github/workflows/build.yaml`) signs the pushed chart with
**cosign key-based signing** (`cosign sign --key env://COSIGN_KEY --tlog-upload=false`).
The job intentionally has **no `id-token` permission**, so cosign has no ambient GitHub
OIDC and produces a pure key signature (no Fulcio certificate). `flux/ocirepository.yaml`
enforces it with `verify.provider: cosign` + `secretRef: cosign-pub`.

Key-based (not keyless) is required because the managed Flux `source-controller` runs
read-only with `HOME=/`, so keyless verify cannot write the Sigstore TUF trust root.
Key-based verify is a local public-key check: no Sigstore/Rekor/TUF, no writable HOME.

Setup:

- **CI secrets** on the repo: `COSIGN_KEY` (private key PEM, raw), `COSIGN_PASSWORD`.
  `ci.yaml` forwards them to the reusable `build.yaml` via `secrets: inherit` (reusable
  workflows do NOT inherit secrets automatically).
- **Cluster secret** `cosign-pub` in `flux-system`, holding the public key (see
  Prerequisites). Generate the pair with `cosign generate-key-pair`; keep the private
  key out of git.

If verification fails, Flux sets `SourceVerified=False` and refuses to pull the chart, so
the HelmRelease does not reconcile. Only tags published after the key-signing step exists
are verifiable; point `ref.tag` at such a tag.

Manual check of a published chart (key signature carries no tlog entry):

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog \
  ghcr.io/a-thaler/odg/charts/odg-infra:<tag>
```
