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

- AKS cluster with OIDC issuer enabled and workload identity webhook installed
- Managed identity for Argo CD repo-server with read access to Azure DevOps repos
  (this module creates the federated credential - do NOT create it in WS1)
- Managed identity for ESO with secret and certificate read permissions on Key Vault
  (federated credential for ESO is managed by Argo CD after bootstrap)
- `azapi`, `helm`, and `kubernetes` Terraform providers configured
