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
| **IAS** | Identity Authentication Service (additional-tenant plan; disabled by default) |
| **Gardener ProviderConfig + RBAC** | Lets the Crossplane kubernetes provider manage Shoots and read BTP resources |
| **Shared audit resources** | One `audit-policy` ConfigMap + `auditlog-credentials` Secret in the garden namespace |
| **Gardener Shoot** | Kubernetes cluster on OpenStack (cilium networking) |

## Values

Landscape-specific configuration is an override on top of the chart defaults in
`charts/odg-infra/values.yaml`. Copy `examples/values.example.yaml`, fill it in, and
supply it as the `odg-infra-values` ConfigMap (see Prerequisites / Flux deployment).

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
| `odg-infra-values` | ConfigMap | The landscape override the HelmRelease reads via `valuesFrom` |

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
