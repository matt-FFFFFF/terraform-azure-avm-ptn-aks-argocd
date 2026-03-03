# terraform-azure-avm-ptn-aks-argocd

This module bootstraps Argo CD on an existing AKS cluster and configures it to
self-manage from a platform-gitops repository in Azure DevOps, using workload
identity federation for authentication (no static secrets).

## Purpose

This module is designed to be used as **Terraform Workspace 2** in a two-workspace
AKS deployment pattern:

- **Workspace 1 (Infrastructure):** Creates the AKS cluster, managed identities,
  Key Vault, and networking.
- **Workspace 2 (Bootstrap - this module):** Creates the federated identity
  credentials, installs Argo CD, seeds the workload identity configuration, and
  creates a self-manage Application that points to a platform-gitops repository.
  After first sync, Argo CD manages itself and all cluster components.

## What This Module Creates

| Resource | Purpose |
|---|---|
| `azapi_resource` (federated credential) | Binds the Argo CD repo-server managed identity to its Kubernetes service account |
| `kubernetes_namespace` | The Argo CD namespace |
| `kubernetes_secret` (platform-identity) | Bridges WS1 identity values (ESO client ID, Key Vault name, tenant ID) into Kubernetes |
| `kubernetes_secret` (repo-creds) | Azure DevOps credential template - enables workload identity auth for all repos under the org |
| `kubernetes_config_map` (git-askpass) | Shell script that acquires Azure AD tokens via workload identity federation |
| `helm_release` (argo-cd) | Argo CD installation with workload identity config and self-manage Application |

## What Argo CD Manages After Bootstrap

After the module runs and Argo CD syncs the platform-gitops repo, Argo CD takes
over management of:

- Its own configuration (self-managing Helm chart)
- External Secrets Operator (sync wave 0)
- ClusterSecretStore for Azure Key Vault (sync wave 1)
- Istio Gateway and TLS certificates via ESO (sync wave 2)
- Team namespaces, AppProjects, and ApplicationSets (sync wave 2+)

## Architecture

```
Terraform WS1 (Infrastructure)
├── AKS cluster (OIDC issuer enabled)
├── Managed identity: argocd-repo (read access to Azure DevOps)
├── Managed identity: eso (Key Vault access)
├── Azure Key Vault
└── Outputs: identity resource IDs, client IDs, tenant ID, KV name, OIDC issuer URL
        │
        ▼
Terraform WS2 (This Module)
├── Creates: federated identity credential (argocd-repo identity → K8s SA)
├── Creates: argocd namespace
├── Creates: platform-identity K8s secret (ESO client ID, KV name, tenant ID)
├── Creates: repo-creds K8s secret (Azure DevOps credential template)
├── Creates: git-askpass ConfigMap (workload identity token script)
├── Creates: Argo CD Helm release + platform-root Application
└── Hands off to Argo CD
        │
        ▼
Argo CD (Self-Managing from platform-gitops repo)
├── Sync wave 0: ESO Helm chart
├── Sync wave 1: ClusterSecretStore
├── Sync wave 2: Gateway, TLS ExternalSecret, namespaces, AppProjects
└── Sync wave 3: Team ApplicationSets → team repos
```

## Azure DevOps Authentication

This module configures Argo CD to authenticate to Azure DevOps using workload
identity federation via a `GIT_ASKPASS` script. The flow:

1. This module creates a federated identity credential that binds the managed
   identity to the Argo CD repo-server Kubernetes service account.
2. The repo-server pod runs with a service account annotated with the managed
   identity client ID.
3. Azure Workload Identity webhook injects a federated token into the pod.
4. When Git needs credentials, the `GIT_ASKPASS` script exchanges the federated
   token for an Azure AD access token scoped to Azure DevOps.
5. The token is used as the password with `x-access-token` as the username.

A credential template (`repo-creds`) is created so that **all repositories**
under the Azure DevOps organization use this authentication method. No per-repo
secrets are needed.

## Prerequisites

### Tools

| Tool | Version | Purpose |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `>= 1.9, < 2.0` | Infrastructure as Code runtime |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | Latest | Authentication to Azure for the `azapi` provider |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Latest | Optional: port-forwarding to Argo CD server, cluster debugging |

### Terraform Providers

The following providers must be configured in your root module. See the
[default example](examples/default/) for a complete provider configuration.

| Provider | Source | Version Constraint | Purpose |
|---|---|---|---|
| `azapi` | `Azure/azapi` | `~> 2.4` | Creates federated identity credentials on managed identities |
| `helm` | `hashicorp/helm` | `~> 2.17` | Installs the Argo CD Helm chart |
| `kubernetes` | `hashicorp/kubernetes` | `~> 2.35` | Creates namespaces, secrets, and ConfigMaps on the AKS cluster |

The `modtm` and `random` providers are used internally for AVM telemetry and do
not require explicit configuration.

### Azure Resources (Workspace 1)

The following resources must exist **before** running this module. They are
typically created in a separate Terraform workspace (Workspace 1) that manages
core infrastructure:

| Resource | Requirements |
|---|---|
| **AKS cluster** | OIDC issuer enabled (`oidc_issuer_enabled = true`), workload identity webhook installed (`workload_identity_enabled = true`) |
| **Managed identity: Argo CD repo-server** | Must have **read access** to Azure DevOps Git repositories. Do **not** create the federated credential in WS1 -- this module creates it. |
| **Managed identity: ESO** | Must have **Secret Get** and **Certificate Get** permissions on the platform Key Vault. This module creates the federated credential binding. |
| **Azure Key Vault** | Stores platform-level secrets (e.g. wildcard TLS certificate). Team workloads use their own Key Vaults. |

### Azure Permissions

The identity running Terraform must have:

- **Write access** to create federated identity credentials on both managed
  identities (`Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write`)
- **Kubernetes cluster access** via client certificate, `az aks get-credentials`,
  or another supported authentication method for the `helm` and `kubernetes` providers

### Azure DevOps

- A **platform-gitops repository** that contains Argo CD Application manifests,
  platform component definitions, and team configuration. See
  [`examples/platform-gitops/`](examples/platform-gitops/) for a reference
  structure.
- The Argo CD repo-server managed identity must be granted read access to all
  Git repositories it needs to sync (at the Azure DevOps organization or project
  level).

### Workspace 1 Outputs

This module consumes the following outputs from your infrastructure workspace:

| Output | Maps to Variable |
|---|---|
| Tenant ID | `tenant_id` |
| Platform Key Vault resource ID | `platform_keyvault_id` |
| ESO managed identity client ID | `eso_identity_client_id` |
| ESO managed identity resource ID | `eso_identity_resource_id` |
| Argo CD repo-server managed identity client ID | `argocd_repo_identity_client_id` |
| Argo CD repo-server managed identity resource ID | `argocd_repo_identity_resource_id` |
| AKS OIDC issuer URL | `aks_oidc_issuer_url` |

## Usage

```hcl
module "aks_argocd_bootstrap" {
  source  = "Azure/avm-ptn-aks-argocd/azurerm"
  version = "~> 0.1"

  # Core identity values from Workspace 1 outputs
  tenant_id                        = var.tenant_id
  platform_keyvault_id             = var.platform_keyvault_id
  eso_identity_client_id           = var.eso_identity_client_id
  eso_identity_resource_id         = var.eso_identity_resource_id
  argocd_repo_identity_client_id   = var.argocd_repo_identity_client_id
  argocd_repo_identity_resource_id = var.argocd_repo_identity_resource_id

  # AKS OIDC issuer URL for federated identity credentials
  aks_oidc_issuer_url = var.aks_oidc_issuer_url

  # Platform GitOps repo in Azure DevOps
  platform_gitops_repo_url      = "https://dev.azure.com/org/project/_git/platform-gitops"
  platform_gitops_repo_path     = "argocd"
  platform_gitops_repo_revision = "main"
}
```

### Accessing the Argo CD UI

After applying, port-forward to the Argo CD server:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Retrieve the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```
