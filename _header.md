# terraform-azure-avm-ptn-aks-argocd

This module bootstraps Argo CD on an existing AKS cluster and configures it to
self-manage from a platform-gitops repository, using either **Azure DevOps** or
**GitHub** for Git hosting. Authentication is handled via workload identity
federation (Azure DevOps) or native GitHub App auth (GitHub) — no static secrets
in either case.

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
| `azapi_resource` (federated credential) | Binds the Argo CD repo-server managed identity to its Kubernetes service account (ADO only) |
| `kubernetes_namespace` | The Argo CD namespace |
| `kubernetes_secret` (platform-identity) | Bridges WS1 identity values (ESO client ID, Key Vault name, tenant ID) into Kubernetes |
| `kubernetes_secret` (repo-creds) | Azure DevOps credential template (ADO) or GitHub App credential template (GitHub) |
| `kubernetes_config_map` (git-askpass) | Shell script that acquires Azure AD tokens via workload identity federation (ADO only) |
| `helm_release` (argo-cd) | Argo CD installation with auth config and self-manage Application |

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
├── Managed identity: argocd-repo (read access to Azure DevOps) [ADO only]
├── Managed identity: eso (Key Vault access)
├── Azure Key Vault (+ GitHub App private key for GitHub provider)
└── Outputs: identity resource IDs, client IDs, tenant ID, KV name, OIDC issuer URL
        │
        ▼
Terraform WS2 (This Module)
├── var.git_provider selects authentication strategy
│
├── [ADO path]
│   ├── Creates: federated identity credential (argocd-repo identity → K8s SA)
│   ├── Creates: repo-creds K8s secret (Azure DevOps credential template)
│   └── Creates: git-askpass ConfigMap (workload identity token script)
│
├── [GitHub path]
│   ├── Reads: GitHub App private key from Key Vault (ephemeral — never in state)
│   └── Creates: repo-creds K8s secret (GitHub App auth, private key via data_wo)
│
├── [Both paths]
│   ├── Creates: argocd namespace
│   ├── Creates: platform-identity K8s secret (ESO client ID, KV name, tenant ID)
│   ├── Creates: Argo CD Helm release + platform-root Application
│   └── Creates: ESO federated identity credential
└── Hands off to Argo CD
        │
        ▼
Argo CD (Self-Managing from platform-gitops repo)
├── Sync wave 0: ESO Helm chart
├── Sync wave 1: ClusterSecretStore
├── Sync wave 2: Gateway, TLS ExternalSecret, namespaces, AppProjects
└── Sync wave 3: Team ApplicationSets → team repos
```

## Azure DevOps Authentication (default)

When `git_provider = "azuredevops"` (the default), this module configures Argo CD
to authenticate to Azure DevOps using workload identity federation via a
`GIT_ASKPASS` script. The flow:

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

## GitHub Authentication

Set `git_provider = "github"` to use ArgoCD's native GitHub App authentication.
This works with both **github.com** and **GitHub Enterprise Server** instances.
The flow:

1. You create a GitHub App, install it on your organization, and store the
   PEM-encoded private key in the platform Azure Key Vault.
2. This module reads the private key at apply time via an **ephemeral resource**
   (`ephemeral "azurerm_key_vault_secret"`). The value is never written to
   Terraform state or plan files.
3. The private key is written to a Kubernetes secret using the `data_wo`
   (write-only) attribute on `kubernetes_secret_v1`, ensuring it also never
   appears in Terraform state.
4. ArgoCD uses the GitHub App ID, Installation ID, and private key to obtain
   installation tokens for Git operations.

A credential template (`repo-creds`) is created so that **all repositories**
accessible to the GitHub App installation use this authentication method. No
per-repo secrets are needed.

### GitHub Prerequisites

| Prerequisite | Details |
|---|---|
| **GitHub App** | Create a GitHub App with read-only access to repository contents. |
| **App Installation** | Install the app on the target GitHub organization (or specific repos). |
| **Private Key in Key Vault** | Store the PEM-encoded private key as a secret in the platform Key Vault (`var.platform_keyvault_id`). |

### GitHub Usage

```hcl
module "aks_argocd_bootstrap" {
  source = "Azure/avm-ptn-aks-argocd/azurerm"

  git_provider                       = "github"
  github_app_id                      = "123456"
  github_app_installation_id         = "78901234"
  github_app_private_key_secret_name = "github-app-private-key"

  tenant_id            = var.tenant_id
  platform_keyvault_id = var.platform_keyvault_id
  aks_oidc_issuer_url  = var.aks_oidc_issuer_url

  eso_identity_client_id   = var.eso_identity_client_id
  eso_identity_resource_id = var.eso_identity_resource_id

  platform_gitops_repo_url      = "https://github.com/org/platform-gitops"
  platform_gitops_repo_path     = "argocd"
  platform_gitops_repo_revision = "main"
}
```

> **Note:** When using `git_provider = "github"`, the `argocd_repo_identity_client_id`
> and `argocd_repo_identity_resource_id` variables are not required (they default
> to `null`). The `azurerm` provider must be configured in your root module.

### GitHub Enterprise Server

For GitHub Enterprise Server, set `github_enterprise_base_url` to the API base
URL of your instance (e.g. `https://github.mycompany.com/api/v3`). This tells
ArgoCD to authenticate against your GHE API instead of the public GitHub API.

The module automatically derives the repo-creds URL prefix from
`platform_gitops_repo_url`, so no special URL handling is needed — just use
your GHE URLs directly.

```hcl
module "aks_argocd_bootstrap" {
  source = "Azure/avm-ptn-aks-argocd/azurerm"

  git_provider                       = "github"
  github_app_id                      = "123456"
  github_app_installation_id         = "78901234"
  github_app_private_key_secret_name = "github-app-private-key"
  github_enterprise_base_url         = "https://github.mycompany.com/api/v3"

  tenant_id            = var.tenant_id
  platform_keyvault_id = var.platform_keyvault_id
  aks_oidc_issuer_url  = var.aks_oidc_issuer_url

  eso_identity_client_id   = var.eso_identity_client_id
  eso_identity_resource_id = var.eso_identity_resource_id

  platform_gitops_repo_url      = "https://github.mycompany.com/org/platform-gitops"
  platform_gitops_repo_path     = "argocd"
  platform_gitops_repo_revision = "main"
}
```

## Prerequisites

### Tools

| Tool | Version | Purpose |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `>= 1.10, < 2.0` | Infrastructure as Code runtime |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | Latest | Authentication to Azure for the `azapi` provider |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Latest | Optional: port-forwarding to Argo CD server, cluster debugging |

### Terraform Providers

The following providers must be configured in your root module. See the
[default example](examples/default/) for a complete provider configuration.

| Provider | Source | Version Constraint | Purpose |
|---|---|---|---|
| `azapi` | `Azure/azapi` | `~> 2.4` | Creates federated identity credentials on managed identities |
| `azurerm` | `hashicorp/azurerm` | `~> 4.0` | Reads GitHub App private key from Key Vault (GitHub provider only) |
| `helm` | `hashicorp/helm` | `~> 2.17` | Installs the Argo CD Helm chart |
| `kubernetes` | `hashicorp/kubernetes` | `~> 2.36` | Creates namespaces, secrets, and ConfigMaps on the AKS cluster |

The `modtm` and `random` providers are used internally for AVM telemetry and do
not require explicit configuration.

### Azure Resources (Workspace 1)

The following resources must exist **before** running this module. They are
typically created in a separate Terraform workspace (Workspace 1) that manages
core infrastructure:

| Resource | Requirements |
|---|---|
| **AKS cluster** | OIDC issuer enabled (`oidc_issuer_enabled = true`), workload identity webhook installed (`workload_identity_enabled = true`) |
| **Managed identity: Argo CD repo-server** | Must have **read access** to Azure DevOps Git repositories. Do **not** create the federated credential in WS1 -- this module creates it. Only required when `git_provider = "azuredevops"`. |
| **Managed identity: ESO** | Must have **Secret Get** and **Certificate Get** permissions on the platform Key Vault. This module creates the federated credential binding. |
| **Azure Key Vault** | Stores platform-level secrets (e.g. wildcard TLS certificate). When `git_provider = "github"`, must also contain the GitHub App PEM-encoded private key as a secret. Team workloads use their own Key Vaults. |

### Azure Permissions

The identity running Terraform must have:

- **Write access** to create federated identity credentials on both managed
  identities (`Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write`)
- **Kubernetes cluster access** via client certificate, `az aks get-credentials`,
  or another supported authentication method for the `helm` and `kubernetes` providers
- *(GitHub only)* **Secret Get** permission on the platform Key Vault, so the
  `azurerm` provider can read the GitHub App private key via the ephemeral resource

### Azure DevOps (when `git_provider = "azuredevops"`)

- A **platform-gitops repository** that contains Argo CD Application manifests,
  platform component definitions, and team configuration. See
  [`examples/platform-gitops/`](examples/platform-gitops/) for a reference
  structure.
- The Argo CD repo-server managed identity must be granted read access to all
  Git repositories it needs to sync (at the Azure DevOps organization or project
  level).

### GitHub (when `git_provider = "github"`)

- A **GitHub App** with read-only access to repository contents, created in the
  target GitHub organization.
- The app must be **installed** on the organization (or on specific repositories
  that Argo CD needs to sync).
- The app's PEM-encoded **private key** must be stored as a secret in the
  platform Key Vault (`var.platform_keyvault_id`).
- A **platform-gitops repository** on GitHub with the same structure as described
  above for Azure DevOps.

### Workspace 1 Outputs

This module consumes the following outputs from your infrastructure workspace:

| Output | Maps to Variable | Required |
|---|---|---|
| Tenant ID | `tenant_id` | Always |
| Platform Key Vault resource ID | `platform_keyvault_id` | Always |
| ESO managed identity client ID | `eso_identity_client_id` | Always |
| ESO managed identity resource ID | `eso_identity_resource_id` | Always |
| AKS OIDC issuer URL | `aks_oidc_issuer_url` | Always |
| Argo CD repo-server managed identity client ID | `argocd_repo_identity_client_id` | ADO only |
| Argo CD repo-server managed identity resource ID | `argocd_repo_identity_resource_id` | ADO only |
| GitHub App ID | `github_app_id` | GitHub only |
| GitHub App installation ID | `github_app_installation_id` | GitHub only |
| GitHub App private key secret name (in Key Vault) | `github_app_private_key_secret_name` | GitHub only |
| GitHub Enterprise API base URL | `github_enterprise_base_url` | GHE only |

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
