<!-- BEGIN_TF_DOCS -->
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

## Requirements

The following requirements are needed by this module:

- <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) (>= 1.9, < 2.0)

- <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) (~> 2.4)

- <a name="requirement_helm"></a> [helm](#requirement\_helm) (~> 2.17)

- <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) (~> 2.35)

- <a name="requirement_modtm"></a> [modtm](#requirement\_modtm) (~> 0.3)

- <a name="requirement_random"></a> [random](#requirement\_random) (~> 3.6)

## Providers

The following providers are used by this module:

- <a name="provider_azapi"></a> [azapi](#provider\_azapi) (2.8.0)

- <a name="provider_helm"></a> [helm](#provider\_helm) (2.17.0)

- <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) (2.38.0)

- <a name="provider_modtm"></a> [modtm](#provider\_modtm) (0.3.5)

- <a name="provider_random"></a> [random](#provider\_random) (3.8.1)

## Modules

No modules.

## Resources

The following resources are used by this module:

- [azapi_resource.argocd_repo_federated_credential](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) (resource)
- [azapi_resource.eso_federated_credential](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) (resource)
- [helm_release.argocd](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) (resource)
- [kubernetes_config_map.git_askpass](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map) (resource)
- [kubernetes_namespace.argocd](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) (resource)
- [kubernetes_secret.argocd_repo_creds](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) (resource)
- [kubernetes_secret.platform_identity](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) (resource)
- [modtm_telemetry.this](https://registry.terraform.io/providers/azure/modtm/latest/docs/resources/telemetry) (resource)
- [random_uuid.telemetry](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/uuid) (resource)

## Required Inputs

The following input variables are required:

### <a name="input_aks_oidc_issuer_url"></a> [aks\_oidc\_issuer\_url](#input\_aks\_oidc\_issuer\_url)

Description: The OIDC issuer URL of the AKS cluster. Used as the issuer in the federated  
identity credential so that Azure AD trusts tokens issued by this cluster's  
service accounts.

Type: `string`

### <a name="input_argocd_repo_identity_client_id"></a> [argocd\_repo\_identity\_client\_id](#input\_argocd\_repo\_identity\_client\_id)

Description: The client ID of the managed identity used by the Argo CD repo-server to  
authenticate to Azure DevOps via workload identity federation. This module  
creates the federated identity credential binding this identity to the  
Argo CD repo-server service account. The identity must have read access  
to the Azure DevOps repositories.

Type: `string`

### <a name="input_argocd_repo_identity_resource_id"></a> [argocd\_repo\_identity\_resource\_id](#input\_argocd\_repo\_identity\_resource\_id)

Description: The Azure resource ID of the managed identity used by the Argo CD repo-server.  
This is the parent resource for the federated identity credential that this  
module creates. The federated credential binds this identity to the Argo CD  
repo-server Kubernetes service account.

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-argocd-repo`

Type: `string`

### <a name="input_eso_identity_client_id"></a> [eso\_identity\_client\_id](#input\_eso\_identity\_client\_id)

Description: The client ID of the managed identity used by External Secrets Operator (ESO)  
to authenticate to Azure Key Vault. Written to the platform-identity Kubernetes  
secret. ESO is deployed by Argo CD after bootstrap, not by this module.

Type: `string`

### <a name="input_eso_identity_resource_id"></a> [eso\_identity\_resource\_id](#input\_eso\_identity\_resource\_id)

Description: The Azure resource ID of the managed identity used by External Secrets Operator.  
This is the parent resource for the federated identity credential that this module  
creates. The federated credential binds this identity to the ESO controller  
Kubernetes service account, enabling workload identity authentication to Key Vault.

ESO is deployed by Argo CD after bootstrap, but the federated credential must  
exist before ESO pods can authenticate. This module creates it because the  
service account name is deterministic from the ESO Helm chart conventions.

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-eso`

Type: `string`

### <a name="input_platform_gitops_repo_url"></a> [platform\_gitops\_repo\_url](#input\_platform\_gitops\_repo\_url)

Description: The Git repository URL for the platform-gitops repository. This is the repo  
that Argo CD will sync to self-manage its own configuration and deploy  
platform components (ESO, Gateway, namespaces, AppProjects, etc.).

Example: `https://dev.azure.com/org/project/_git/platform-gitops`

Type: `string`

### <a name="input_platform_keyvault_id"></a> [platform\_keyvault\_id](#input\_platform\_keyvault\_id)

Description: The Azure resource ID of the platform Key Vault used for gateway TLS  
certificates. This Key Vault is not managed by this module — it is created  
in Workspace 1 alongside the AKS cluster and managed identities.

The vault name is derived from this resource ID and written to the  
platform-identity Kubernetes secret so that the ESO ClusterSecretStore  
can reference it.

Team workloads use their own Key Vaults; this one is strictly for  
platform-level secrets (e.g. the wildcard TLS certificate).

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/kv-platform-tls`

Type: `string`

### <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id)

Description: The Azure AD tenant ID. Written to the platform-identity Kubernetes secret  
so that Argo CD managed resources (e.g. ESO ClusterSecretStore) can use it  
for workload identity token exchange.

Type: `string`

## Optional Inputs

The following input variables are optional (have default values):

### <a name="input_argocd_additional_helm_values"></a> [argocd\_additional\_helm\_values](#input\_argocd\_additional\_helm\_values)

Description: Additional Helm values to pass to the Argo CD chart as a list of YAML strings.  
These are deep-merged on top of the module's base values by the Helm provider,  
so you can safely override individual nested keys without losing the workload  
identity configuration.

Example:
```hcl
argocd_additional_helm_values = [
  yamlencode({
    server = {
      replicas = 2
    }
  })
]
```

Type: `list(string)`

Default: `[]`

### <a name="input_argocd_helm_version"></a> [argocd\_helm\_version](#input\_argocd\_helm\_version)

Description: The version of the Argo CD Helm chart to install. This is the chart version,  
not the Argo CD application version. See https://github.com/argoproj/argo-helm  
for available versions.

Type: `string`

Default: `"7.8.8"`

### <a name="input_argocd_namespace"></a> [argocd\_namespace](#input\_argocd\_namespace)

Description: The Kubernetes namespace in which to install Argo CD. The namespace is created  
by this module if it does not already exist.

Type: `string`

Default: `"argocd"`

### <a name="input_argocd_repo_creds_url"></a> [argocd\_repo\_creds\_url](#input\_argocd\_repo\_creds\_url)

Description: The base URL for the Argo CD repository credential template. All Git repos  
whose URL starts with this prefix will use the workload identity authentication  
configured by this module (via GIT\_ASKPASS).

If not set, defaults to the Azure DevOps organization-level URL derived from
`var.platform_gitops_repo_url`. For example, if the platform repo URL is
`https://dev.azure.com/org/project/_git/platform-gitops`, the default base  
URL will be `https://dev.azure.com/org/`.

Set this to a more specific URL to restrict which repos use these credentials,  
or to a broader URL if your repos span multiple organizations.

Type: `string`

Default: `null`

### <a name="input_argocd_server_service_type"></a> [argocd\_server\_service\_type](#input\_argocd\_server\_service\_type)

Description: The Kubernetes service type for the Argo CD server. Use `ClusterIP` for internal  
access (recommended when using an Istio Gateway or ingress controller), or
`LoadBalancer` for direct external access.

Type: `string`

Default: `"ClusterIP"`

### <a name="input_enable_telemetry"></a> [enable\_telemetry](#input\_enable\_telemetry)

Description: Controls whether or not telemetry is enabled for the module.  
For more information see <https://aka.ms/avm/telemetryinfo>.  
If it is set to false, then no telemetry will be collected.

Type: `bool`

Default: `true`

### <a name="input_eso_namespace"></a> [eso\_namespace](#input\_eso\_namespace)

Description: The Kubernetes namespace where External Secrets Operator will be deployed by  
Argo CD. Must match the destination namespace in the ESO Application manifest  
in the platform-gitops repo. Used to construct the federated identity credential  
subject.

Type: `string`

Default: `"external-secrets"`

### <a name="input_eso_service_account_name"></a> [eso\_service\_account\_name](#input\_eso\_service\_account\_name)

Description: The name of the Kubernetes service account created by the ESO Helm chart.  
Must match the service account name that ESO's Helm chart creates, which  
defaults to the release name. Used to construct the federated identity  
credential subject.

Type: `string`

Default: `"external-secrets"`

### <a name="input_platform_gitops_repo_path"></a> [platform\_gitops\_repo\_path](#input\_platform\_gitops\_repo\_path)

Description: The path within the platform-gitops repository where the Argo CD self-management  
configuration is located. This is the path that the platform-root Application  
will sync from.

Type: `string`

Default: `"argocd"`

### <a name="input_platform_gitops_repo_revision"></a> [platform\_gitops\_repo\_revision](#input\_platform\_gitops\_repo\_revision)

Description: The Git revision (branch, tag, or commit SHA) of the platform-gitops repository  
to sync. Defaults to `main`.

Type: `string`

Default: `"main"`

### <a name="input_tags"></a> [tags](#input\_tags)

Description: A map of tags to apply to resources that support tagging. These are passed  
as labels to Kubernetes resources created by this module.

Type: `map(string)`

Default: `{}`

## Outputs

The following outputs are exported:

### <a name="output_argocd_namespace"></a> [argocd\_namespace](#output\_argocd\_namespace)

Description: The Kubernetes namespace where Argo CD is installed.

### <a name="output_argocd_repo_federated_credential_id"></a> [argocd\_repo\_federated\_credential\_id](#output\_argocd\_repo\_federated\_credential\_id)

Description: The Azure resource ID of the federated identity credential for the Argo CD repo-server.

### <a name="output_argocd_repo_server_service_account"></a> [argocd\_repo\_server\_service\_account](#output\_argocd\_repo\_server\_service\_account)

Description: The name of the Kubernetes service account used by the Argo CD repo-server.  
This is the service account that the federated identity credential is bound to.

### <a name="output_argocd_server_service_name"></a> [argocd\_server\_service\_name](#output\_argocd\_server\_service\_name)

Description: The name of the Argo CD server Kubernetes service. Use this for port-forwarding  
or configuring ingress/gateway routes:

  kubectl port-forward svc/argocd-server -n <namespace> 8080:443

### <a name="output_eso_federated_credential_id"></a> [eso\_federated\_credential\_id](#output\_eso\_federated\_credential\_id)

Description: The Azure resource ID of the federated identity credential for the External Secrets Operator.

### <a name="output_eso_service_account_name"></a> [eso\_service\_account\_name](#output\_eso\_service\_account\_name)

Description: The name of the Kubernetes service account that the ESO federated identity  
credential is bound to. The ESO Helm chart must create a service account  
with this exact name for workload identity to function.

### <a name="output_helm_release_name"></a> [helm\_release\_name](#output\_helm\_release\_name)

Description: The name of the Argo CD Helm release.

### <a name="output_helm_release_version"></a> [helm\_release\_version](#output\_helm\_release\_version)

Description: The version of the Argo CD Helm chart that was deployed.

### <a name="output_platform_identity_secret_name"></a> [platform\_identity\_secret\_name](#output\_platform\_identity\_secret\_name)

Description: The name of the Kubernetes secret containing platform identity values
(ESO client ID, Key Vault name, tenant ID). Reference this in the  
platform-gitops repo when configuring the ESO ClusterSecretStore.

### <a name="output_repo_creds_url"></a> [repo\_creds\_url](#output\_repo\_creds\_url)

Description: The base URL used for the Argo CD repository credential template. All Git  
repositories whose URL starts with this prefix will use workload identity  
authentication via GIT\_ASKPASS.

## Data Collection

The software may collect information about you and your use of the software and send it to Microsoft. Microsoft may use this information to provide services and improve our products and services. You may turn off the telemetry as described in the repository. There are also some features in the software that may enable you and Microsoft to collect data from users of your applications. If you use these features, you must comply with applicable law, including providing appropriate notices to users of your applications together with a copy of Microsoft's privacy statement. Our privacy statement is located at <https://go.microsoft.com/fwlink/?LinkID=824704>. You can learn more about data collection and use in the help documentation and our privacy statement. Your use of the software operates as your consent to these practices.
<!-- END_TF_DOCS -->