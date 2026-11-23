# ODG GitOps Infrastructure

Infrastructure resources for Open Delivery Gear environments, managed via GitOps.

## Structure

```
environments/
└── dev/
    ├── kustomization.yaml
    ├── btp-subaccount/        # BTP Subaccount and core services
    │   ├── providerconfig.yaml
    │   ├── subaccount.yaml
    │   ├── entitlements.yaml
    │   ├── servicemanager.yaml
    │   └── cloudmanagement.yaml
    ├── btp-services/          # BTP service instances
    │   ├── entitlements.yaml
    │   ├── cloud-logging.yaml
    │   ├── cloud-logging-shoot-dummy.yaml  # Per-shoot binding
    │   ├── auditlog.yaml
    │   ├── auditlog-viewer.yaml
    │   └── ias.yaml
    ├── gardener/              # Gardener API resources
    │   ├── provider-config.yaml
    │   ├── provider-kubernetes-rbac.yaml
    │   ├── audit-policy-object.yaml
    │   └── auditlog-credentials-object.yaml
    └── shoots/                # Gardener Shoot clusters
        ├── dummy.yaml                        # Shoot definition
        ├── dummy-providerconfig.yaml         # ProviderConfig for shoot access
        ├── dummy-cloud-logging-namespace.yaml # Namespace in shoot
        └── dummy-cloud-logging-secret.yaml   # Credentials in shoot
```

## Resources

| Resource | Purpose |
|----------|---------|
| **BTP Subaccount** | Pre-existing subaccount (infra-odg-dev-sap) |
| **ServiceManager** | Required for provisioning BTP services |
| **CloudManagement** | Required for subscriptions |
| **Cloud Logging** | Centralized logging (OpenTelemetry enabled) |
| **Cloud Logging Binding (per shoot)** | Shoot-specific credentials for log shipping |
| **Audit Log Service** | Kubernetes API audit logs |
| **Audit Log Viewer** | UI to view audit logs |
| **IAS** | Identity Authentication Service (OIDC) |
| **Gardener Shoot** | Kubernetes cluster on OpenStack |

## Gardener Integration

The `gardener/` folder contains:

- **provider-config.yaml**: Kubernetes ProviderConfig pointing to Gardener API
- **provider-kubernetes-rbac.yaml**: RBAC for the Kubernetes provider to read BTP resources
- **audit-policy-object.yaml**: Creates ConfigMap in garden-odgdev namespace
- **auditlog-credentials-object.yaml**: Injects BTP auditlog credentials to Gardener

The shoot references these resources for audit logging:
- Audit policy ConfigMap: `shoot-dummy-audit-policy`
- Auditlog credentials Secret: `shoot-dummy-auditlog-credentials`

## Cloud Logging Integration

Each shoot gets its own Cloud Logging ServiceBinding for log shipping credentials.
The credentials are injected into the shoot cluster as a Secret.

**Files per shoot:**
- `btp-services/cloud-logging-shoot-<name>.yaml` - BTP ServiceBinding
- `shoots/<name>-providerconfig.yaml` - ProviderConfig to access shoot
- `shoots/<name>-cloud-logging-namespace.yaml` - Creates namespace in shoot
- `shoots/<name>-cloud-logging-secret.yaml` - Injects credentials into shoot

**⚠️ Network Limitation:** The control plane may not have direct network access
to the shoot API server. If Objects targeting the shoot fail with timeout errors,
consider:

1. **Flux on shoot**: Bootstrap Flux on the shoot to pull from an apps GitOps repo
2. **Initial setup script**: Use a one-time script to create the namespace and secret
3. **Gardener extensions**: Deploy via shoot extensions through Gardener's internal connectivity

## Secrets (out-of-band)

These secrets must be created manually before applying:

| Secret | Namespace | Purpose | How to create |
|--------|-----------|---------|---------------|
| `gardener-kubeconfig` | default | Service account token for Gardener API | See below |
| `shoot-dummy-kubeconfig` | default | Admin kubeconfig for shoot dummy | See below |
| `ias-provider-credentials` | default | IAS technical user credentials | See `btp-services/ias.yaml` |

### Gardener Kubeconfig Secret

```bash
kubectl create secret generic gardener-kubeconfig \
  --from-literal=kubeconfig='<kubeconfig-yaml>'
```

The kubeconfig should contain a service account token for the `garden-odgdev` namespace.

### Shoot Kubeconfig Secret

Get a short-lived admin kubeconfig via AdminKubeconfigRequest:

```bash
# Get kubeconfig from Gardener
KUBECONFIG_JSON=$(kubectl --kubeconfig=<gardener-kc> create --raw \
  '/apis/core.gardener.cloud/v1beta1/namespaces/garden-odgdev/shoots/dummy/adminkubeconfig' \
  -f '{"apiVersion":"authentication.gardener.cloud/v1alpha1","kind":"AdminKubeconfigRequest","spec":{"expirationSeconds":86400}}')

# Extract and create secret
SHOOT_KC=$(echo "$KUBECONFIG_JSON" | jq -r '.status.kubeconfig' | base64 -d)
kubectl create secret generic shoot-dummy-kubeconfig --from-literal=kubeconfig="$SHOOT_KC"
```

For automated rotation, install the `gardener-auth` provider. See `shoots/dummy-providerconfig.yaml` for details.

## Applying

```bash
# Apply all resources
kubectl apply -k environments/dev

# Or apply individually
kubectl apply -f environments/dev/btp-services/auditlog.yaml
kubectl apply -f environments/dev/shoots/dummy.yaml
```

## Flux Bootstrap (optional)

```bash
# Create git credentials secret
kubectl -n flux-system create secret generic odg-gitops-infra-auth \
  --from-file=identity=~/.ssh/odg-gitops-infra-deploy \
  --from-file=identity.pub=~/.ssh/odg-gitops-infra-deploy.pub \
  --from-literal=known_hosts="$(ssh-keyscan github.tools.sap 2>/dev/null)"

# Apply Flux sync resources
kubectl apply -f flux-sync.yaml
```

## Accessing Audit Logs

1. Go to BTP Cockpit → Subaccount (infra-odg-dev-sap)
2. Services → Instances and Subscriptions
3. Find "Audit Log Viewer" → "Go to Application"

**Note:** You need the `Auditlog_Viewer` role collection assigned to view logs.

## Adding a New Shoot

1. Copy `environments/dev/shoots/dummy.yaml` → `shoots/<name>.yaml`
2. Update in the shoot manifest:
   - `metadata.name`: `shoot-<name>`
   - `spec.forProvider.manifest.metadata.name`: `<name>`
   - `tenantID` and `serviceURL` in auditlog extension
3. Create Gardener Objects in `gardener/`:
   - `audit-policy-object.yaml` → update name references
   - `auditlog-credentials-object.yaml` → update name references
4. Create Cloud Logging binding: `btp-services/cloud-logging-shoot-<name>.yaml`
5. Create shoot access files in `shoots/`:
   - `<name>-providerconfig.yaml`
   - `<name>-cloud-logging-namespace.yaml`
   - `<name>-cloud-logging-secret.yaml`
6. Add all files to `kustomization.yaml`
7. Create secret: `shoot-<name>-kubeconfig`
