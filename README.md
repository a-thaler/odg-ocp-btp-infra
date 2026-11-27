# ODG GitOps Infrastructure

Control plane infrastructure for Open Delivery Gear (ODG), as a single Helm chart
(`charts/odg-infra`) published as a signed OCI artifact and deployed by Flux. The chart
renders all BTP and Gardener resources; landscape-specific values are an override delivered
as a ConfigMap, kept out of git.

One-time manual subaccount preparation (provider secrets, IAS tenant and applications,
PostgreSQL entitlements) is in [docs/SUBACCOUNT.md](docs/SUBACCOUNT.md). This README covers
the chart.

## Structure

```
charts/odg-infra/
├── Chart.yaml
├── values.yaml                 # defaults + required ("") fields
└── templates/
    ├── _helpers.tpl
    ├── btp-subaccount/         # ProviderConfig, Subaccount, Entitlements, ServiceManager, CloudManagement
    ├── btp-services/           # Cloud Logging, Audit Log (+ Viewer), role assignments, PostgreSQL
    ├── gardener/               # Kubernetes ProviderConfig, RBAC, audit policy + credentials Objects
    └── shoots/                 # Gardener Shoot Objects (one per shoots[] entry)
flux/                           # committed OCIRepository + HelmRelease + kustomization
examples/values.example.yaml   # template landscape override (copy, fill, keep out of git)
docs/SUBACCOUNT.md              # one-time manual subaccount preparation
.github/workflows/              # ci.yaml -> build.yaml (package, push, cosign key-sign)
```

## Resources

| Resource | Purpose |
|----------|---------|
| BTP Subaccount | Pre-existing, adopted (`deletionPolicy: Orphan`) |
| ServiceManager / CloudManagement | Provisioning BTP services / subscriptions |
| Cloud Logging | Centralized logging (OpenTelemetry ingest) |
| Audit Log (+ Viewer) | Kubernetes API audit logs to BTP; UI + per-user role assignments |
| Gardener ProviderConfig + RBAC | Lets the Crossplane kubernetes provider manage Shoots |
| Shared audit resources | `audit-policy` ConfigMap + `auditlog-credentials` Secret in the garden namespace |
| Gardener Shoot | Kubernetes cluster on OpenStack (cilium) |
| Cloud Logging SAML SSO | Optional (`cloudLogging.saml.enabled`); IAS tenant/app manual |
| Shoot OIDC access | Optional (`shootOidc.enabled`); IAS app + RBAC manual |
| PostgreSQL per shoot | Optional (`postgres.enabled`); per-shoot instance + binding, plus entitlements |

## Values

Override the chart defaults (`charts/odg-infra/values.yaml`): copy
`examples/values.example.yaml`, fill it in, deliver it as the `odg-infra-values` ConfigMap
(see Deployment). Notes on the optional features:

- **IAS features** (`cloudLogging.saml`, `shootOidc`): set `ias.tenantHost` once; the chart
  derives SAML/OIDC URLs and writes parameters only. It creates no IAS objects or secrets
  (SAML OPTION 2). Tenant, applications, and per-shoot RBAC are set up manually, see
  [docs/SUBACCOUNT.md](docs/SUBACCOUNT.md).
- **PostgreSQL** (`postgres.enabled`): renders per-shoot `postgresql-db` ServiceInstance +
  ServiceBinding (connection secret `postgres-<shoot>-credentials`) plus the compute and
  storage entitlements. `createInstances: false` renders entitlements only. Instance params
  (`memory`, `storageGB`, `allow_access` from each shoot's egress IP, etc.) and the
  entitlement model are documented in `values.yaml` and
  [docs/SUBACCOUNT.md](docs/SUBACCOUNT.md#postgresql-entitlements-and-manual-instances).

## Prerequisites (control plane)

Flux (source + helm controllers) already running in `flux-system`, plus:

- Provider credential secrets in `manual-secrets` (`cis-provider-secret`,
  `sa-provider-secret`, `gardener-kubeconfig`), see [docs/SUBACCOUNT.md](docs/SUBACCOUNT.md).
- In `flux-system`: `ghcr-pull` (private GHCR pull secret), `cosign-pub` (chart verify key),
  `odg-infra-values` ConfigMap (landscape override), optional `odg-infra-secret-values`
  Secret (sensitive values, merged on top).

## Deployment

The chart is published to `ghcr.io/a-thaler/odg/charts/odg-infra`; Flux pulls it via the
committed `OCIRepository` + `HelmRelease` in `flux/`, reading the override via `valuesFrom`.

```bash
# my-values.yaml = filled-in copy of examples/values.example.yaml.
helm lint charts/odg-infra -f my-values.yaml
helm template odg-infra charts/odg-infra -f my-values.yaml | kubectl apply --dry-run=server -f -

# GHCR pull secret (skip if package is public)
kubectl -n flux-system create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=a-thaler \
  --docker-password='<ghcr-pat-with-read:packages>'

# cosign verify key
kubectl -n flux-system create secret generic cosign-pub \
  --from-file=cosign.pub=cosign.pub --dry-run=client -o yaml | kubectl apply -f -

# landscape override (+ optional sensitive overrides)
kubectl -n flux-system create configmap odg-infra-values \
  --from-file=values.yaml=my-values.yaml --dry-run=client -o yaml | kubectl apply -f -

# committed Flux resources, then watch
kubectl apply -k flux
flux get ocirepository odg-infra && flux get helmrelease odg-infra
```

Update values later: re-run the ConfigMap step, then
`flux reconcile helmrelease odg-infra`. New chart version: bump `ref.tag` in
`flux/ocirepository.yaml` to the published tag.

## Signing

`build.yaml` signs each pushed chart with **cosign key-based signing**
(`--key env://COSIGN_KEY --tlog-upload=false`, no `id-token`, no Fulcio);
`flux/ocirepository.yaml` enforces `verify.provider: cosign` with `cosign-pub`. Key-based
(not keyless) is required because the managed `source-controller` is read-only with
`HOME=/`, so keyless verify cannot write the Sigstore TUF root.

Setup: repo secrets `COSIGN_KEY` + `COSIGN_PASSWORD` (`ci.yaml` forwards via
`secrets: inherit`); cluster secret `cosign-pub`. Generate with
`cosign generate-key-pair`. Only tags published after key-signing was added are verifiable.

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog \
  ghcr.io/a-thaler/odg/charts/odg-infra:<tag>
```
