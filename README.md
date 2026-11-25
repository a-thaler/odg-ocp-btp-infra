# ODG GitOps Infrastructure

Control plane infrastructure for Open Delivery Gear (ODG) environments, packaged as a
single Helm chart, published as a signed OCI artifact, and deployed by Flux. One chart
(`charts/odg-infra`) renders all BTP and Gardener resources; landscape-specific values
are supplied out-of-band from the gitignored `secrets/values.yaml`.

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
secrets/                            # gitignored; never committed
└── values.yaml                     # landscape overrides -> applied as odg-infra-values ConfigMap
.github/workflows/
└── build.yaml                      # package, push, cosign-sign, attest the chart
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
| **IAS** | Identity Authentication Service (additional-tenant plan; disabled by default) |
| **Gardener ProviderConfig + RBAC** | Lets the Crossplane kubernetes provider manage Shoots and read BTP resources |
| **Shared audit resources** | One `audit-policy` ConfigMap + `auditlog-credentials` Secret in the garden namespace |
| **Gardener Shoot** | Kubernetes cluster on OpenStack (cilium networking) |

## Values

All landscape-specific configuration is supplied through `secrets/values.yaml`
(gitignored), overriding the chart defaults in `charts/odg-infra/values.yaml`. Required
fields (empty `""` in defaults): `btp.cliServerUrl`, `btp.globalAccountId`,
`subaccount.guid`, `subaccount.displayName`, `subaccount.subdomain`, `subaccount.region`,
`gardener.gardenNamespace`, `auditlog.serviceUrl`.

Shoots are declared as a list; each entry needs only a `name`, with optional
`kubernetes.version`, `purpose`, and `worker.{machineType,min,max}` overrides. Everything
else comes from `shootDefaults`:

```yaml
shoots:
  - name: provisioner
  - name: dev-1
```

Audit Log Viewer access is a list of `{name, email}` under `auditlog.viewers`; each entry
renders one `RoleCollectionAssignment` for the `Auditlog Viewer` role collection.

IAS (`ias.enabled`) is `false` by default. The `additional-tenant` plan requires a manual
global-account entitlement before it can be enabled.

## Secrets (out-of-band)

These must exist in the `manual-secrets` namespace before the chart reconciles:

| Secret | Key | Purpose |
|--------|-----|---------|
| `cis-provider-secret` | `data` | CIS credentials for the BTP provider |
| `sa-provider-secret` | `credentials` | Service account credentials for the BTP provider |
| `gardener-kubeconfig` | `kubeconfig` | Service account kubeconfig for the Gardener API (garden namespace) |

## Rendering and validation

```bash
# Lint
helm lint charts/odg-infra -f secrets/values.yaml

# Render the dev landscape
helm template odg-infra charts/odg-infra -f secrets/values.yaml

# Server-side dry-run against the control plane
helm template odg-infra charts/odg-infra -f secrets/values.yaml \
  | kubectl apply --dry-run=server -f -
```

## Flux deployment

The chart is published as a signed OCI artifact at
`ghcr.io/a-thaler/odg/charts/odg-infra`. Flux pulls it with an `OCIRepository` and
installs it with a `HelmRelease`, both in `flux/` (committed). Landscape values are
layered via the HelmRelease `valuesFrom`, applied out-of-band (NOT committed):
a ConfigMap `odg-infra-values` for non-secret config (source: gitignored
`secrets/values.yaml`), plus an optional Secret `odg-infra-secret-values` merged on
top for any sensitive values. Later sources override earlier ones on key collisions.
Flux is assumed already running in `flux-system`.

Deploy order:

```bash
# 1. GHCR pull secret (the package is private). Use a PAT or the gh token with
#    read:packages. Skip this step if you make the GHCR package public.
kubectl -n flux-system create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=a-thaler \
  --docker-password="$(gh auth token)"

# 2. Landscape values as a ConfigMap, from the gitignored override file.
#    This is WHERE the custom values.yaml gets deployed; the HelmRelease reads it
#    via valuesFrom. It holds only identifiers/config, so a ConfigMap is correct.
kubectl -n flux-system create configmap odg-infra-values \
  --from-file=values.yaml=secrets/values.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# 2b. (optional) Sensitive overrides merged on top. Only needed if some values
#     are actually secret (e.g. an inlined client secret). Omit otherwise.
# kubectl -n flux-system create secret generic odg-infra-secret-values \
#   --from-file=values.yaml=secrets/secret-values.yaml \
#   --dry-run=client -o yaml | kubectl apply -f -

# 3. The committed Flux resources (OCIRepository + HelmRelease).
kubectl apply -k flux

# 4. Watch reconciliation.
flux get ocirepository odg-infra
flux get helmrelease odg-infra
```

Updating landscape values later: edit `secrets/values.yaml`, re-run step 2, then
`flux reconcile helmrelease odg-infra`. Publishing a new chart version: bump the
`ref.tag` in `flux/ocirepository.yaml` to the new published tag.

## Signing and verification

The publish workflow (`.github/workflows/build.yaml`) signs the pushed chart with
**cosign keyless** (GitHub Actions OIDC, Sigstore Fulcio/Rekor). `flux/ocirepository.yaml`
enforces that signature via `verify.provider: cosign` and `matchOIDCIdentity`, pinned to
this repo's build workflow:

```
issuer:  https://token.actions.githubusercontent.com
subject: ^https://github\.com/a-thaler/odg-ocp-btp-infra/\.github/workflows/build\.yaml@refs/.*$
```

If verification fails, Flux refuses to pull the chart and the HelmRelease does not
reconcile. Consequences to know:

- A chart version is only verifiable if it was published **after** the cosign step
  existed. Point `ref.tag` at such a version; earlier tags have no cosign signature and
  will be rejected.
- The `actions/attest` provenance (also produced) is SLSA build provenance, verified
  separately with `gh attestation verify`. Flux does NOT consume it; only the cosign
  signature gates reconciliation.
- Keyless verify requires the control plane to reach Sigstore (Fulcio roots + Rekor).
  If the cluster is network-restricted, switch to key-based cosign: sign with a private
  key in CI and set `verify.secretRef` to a Secret holding `cosign.pub`.

Manual check of a published chart:

```bash
cosign verify ghcr.io/a-thaler/odg/charts/odg-infra:<tag> \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='^https://github.com/a-thaler/odg-ocp-btp-infra/.github/workflows/build.yaml@refs/.*$'
```

## Accessing audit logs

1. BTP Cockpit → Subaccount → Services → Instances and Subscriptions.
2. Open "Audit Log Viewer" → "Go to Application".
3. Requires the `Auditlog Viewer` role collection (assigned via `auditlog.viewers`).

## Adding a shoot

Append an entry to `shoots` in `secrets/values.yaml`, then re-apply the values Secret
(step 2 above) and `flux reconcile helmrelease odg-infra`:

```yaml
shoots:
  - name: my-shoot
    # optional overrides:
    # kubernetes:
    #   version: "1.36.5"
    # worker:
    #   machineType: g_c16_m64
```

The shared `audit-policy` ConfigMap and `auditlog-credentials` Secret are reused by every
shoot, so no per-shoot audit resources are needed.
