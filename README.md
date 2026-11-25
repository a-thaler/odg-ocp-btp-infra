# ODG GitOps Infrastructure

Control plane infrastructure for Open Delivery Gear (ODG) environments, packaged as a
single Helm chart and deployed by Flux. One chart (`charts/odg-infra`) renders all
BTP and Gardener resources; landscape-specific values live in `clusters/<landscape>/values.yaml`.

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
clusters/
└── dev/
    ├── kustomization.yaml          # GitRepository + HelmRelease + odg-infra-values ConfigMap
    ├── flux-system.yaml            # Flux GitRepository source
    ├── odg-infra-release.yaml      # Flux HelmRelease (reads values from odg-infra-values ConfigMap)
    └── values.yaml                 # Dev landscape overrides (rendered into the ConfigMap)
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

All landscape-specific configuration is supplied through `clusters/<landscape>/values.yaml`,
overriding the chart defaults in `charts/odg-infra/values.yaml`. Required fields (empty `""`
in defaults): `btp.globalAccountId`, `subaccount.guid`, `subaccount.displayName`,
`subaccount.subdomain`, `gardener.gardenNamespace`.

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
helm lint charts/odg-infra -f clusters/dev/values.yaml

# Render the dev landscape
helm template odg-infra charts/odg-infra -f clusters/dev/values.yaml

# Server-side dry-run against the control plane
helm template odg-infra charts/odg-infra -f clusters/dev/values.yaml \
  | kubectl apply --dry-run=server -f -
```

## Flux deployment

Flux reconciles `clusters/dev`: the kustomization renders the `odg-infra-values` ConfigMap
from `values.yaml`, and the `odg-infra` HelmRelease installs `charts/odg-infra` with those
values into the `default` namespace.

```bash
# Git credentials secret (deploy key)
kubectl -n flux-system create secret generic odg-gitops-infra-auth \
  --from-file=identity=~/.ssh/odg-gitops-infra-deploy \
  --from-file=identity.pub=~/.ssh/odg-gitops-infra-deploy.pub \
  --from-literal=known_hosts="$(ssh-keyscan github.tools.sap 2>/dev/null)"

# Point Flux at this cluster path
kubectl apply -k clusters/dev
```

## Accessing audit logs

1. BTP Cockpit → Subaccount → Services → Instances and Subscriptions.
2. Open "Audit Log Viewer" → "Go to Application".
3. Requires the `Auditlog Viewer` role collection (assigned via `auditlog.viewers`).

## Adding a shoot

Append an entry to `shoots` in `clusters/<landscape>/values.yaml`:

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
