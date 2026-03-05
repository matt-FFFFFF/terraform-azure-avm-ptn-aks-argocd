variable "tenant_id" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The Azure AD tenant ID. Written to the platform-identity Kubernetes secret
so that Argo CD managed resources (e.g. ESO ClusterSecretStore) can use it
for workload identity token exchange.
DESCRIPTION

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.tenant_id))
    error_message = "The tenant_id must be a valid UUID."
  }
}

variable "platform_keyvault_id" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The Azure resource ID of the platform Key Vault used for gateway TLS
certificates. This Key Vault is not managed by this module — it is created
in Workspace 1 alongside the AKS cluster and managed identities.

The vault name is derived from this resource ID and written to the
platform-identity Kubernetes secret so that the ESO ClusterSecretStore
can reference it.

Team workloads use their own Key Vaults; this one is strictly for
platform-level secrets (e.g. the wildcard TLS certificate).

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/kv-platform-tls`
DESCRIPTION

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+$", var.platform_keyvault_id))
    error_message = "The platform_keyvault_id must be a valid Azure resource ID for a Key Vault."
  }
}

variable "eso_identity_client_id" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The client ID of the managed identity used by External Secrets Operator (ESO)
to authenticate to Azure Key Vault. Written to the platform-identity Kubernetes
secret. ESO is deployed by Argo CD after bootstrap, not by this module.
DESCRIPTION

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.eso_identity_client_id))
    error_message = "The eso_identity_client_id must be a valid UUID."
  }
}

variable "eso_identity_resource_id" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The Azure resource ID of the managed identity used by External Secrets Operator.
This is the parent resource for the federated identity credential that this module
creates. The federated credential binds this identity to the ESO controller
Kubernetes service account, enabling workload identity authentication to Key Vault.

ESO is deployed by Argo CD after bootstrap, but the federated credential must
exist before ESO pods can authenticate. This module creates it because the
service account name is deterministic from the ESO Helm chart conventions.

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-eso`
DESCRIPTION

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.eso_identity_resource_id))
    error_message = "The eso_identity_resource_id must be a valid Azure resource ID for a user-assigned managed identity."
  }
}

variable "eso_namespace" {
  type        = string
  default     = "external-secrets"
  nullable    = false
  description = <<DESCRIPTION
The Kubernetes namespace where External Secrets Operator will be deployed by
Argo CD. Must match the destination namespace in the ESO Application manifest
in the platform-gitops repo. Used to construct the federated identity credential
subject.
DESCRIPTION

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.eso_namespace))
    error_message = "The eso_namespace must be a valid Kubernetes namespace name (lowercase alphanumeric and hyphens, max 63 characters)."
  }
}

variable "eso_service_account_name" {
  type        = string
  default     = "external-secrets"
  nullable    = false
  description = <<DESCRIPTION
The name of the Kubernetes service account created by the ESO Helm chart.
Must match the service account name that ESO's Helm chart creates, which
defaults to the release name. Used to construct the federated identity
credential subject.
DESCRIPTION
}

variable "argocd_repo_identity_client_id" {
  type        = string
  default     = null
  nullable    = true
  description = <<DESCRIPTION
The client ID of the managed identity used by the Argo CD repo-server to
authenticate to Azure DevOps via workload identity federation. This module
creates the federated identity credential binding this identity to the
Argo CD repo-server service account. The identity must have read access
to the Azure DevOps repositories.

Required when git_provider = "azuredevops".
DESCRIPTION

  validation {
    condition     = var.argocd_repo_identity_client_id == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.argocd_repo_identity_client_id))
    error_message = "The argocd_repo_identity_client_id must be a valid UUID."
  }
}

variable "argocd_repo_identity_resource_id" {
  type        = string
  default     = null
  nullable    = true
  description = <<DESCRIPTION
The Azure resource ID of the managed identity used by the Argo CD repo-server.
This is the parent resource for the federated identity credential that this
module creates. The federated credential binds this identity to the Argo CD
repo-server Kubernetes service account.

Required when git_provider = "azuredevops".

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-argocd-repo`
DESCRIPTION

  validation {
    condition     = var.argocd_repo_identity_resource_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.argocd_repo_identity_resource_id))
    error_message = "The argocd_repo_identity_resource_id must be a valid Azure resource ID for a user-assigned managed identity."
  }
}

variable "git_provider" {
  type        = string
  default     = "azuredevops"
  nullable    = false
  description = "The Git hosting provider. Determines the authentication strategy for ArgoCD repository access."

  validation {
    condition     = contains(["azuredevops", "github"], var.git_provider)
    error_message = "git_provider must be \"azuredevops\" or \"github\"."
  }
}

variable "github_app_id" {
  type        = string
  default     = null
  description = "The GitHub App ID for ArgoCD repository access. Required when git_provider = \"github\"."
}

variable "github_app_installation_id" {
  type        = string
  default     = null
  description = "The GitHub App installation ID. Required when git_provider = \"github\"."
}

variable "github_app_private_key_secret_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The name of the secret in var.platform_keyvault_id containing the GitHub App
PEM-encoded private key. Read at apply time via an ephemeral resource — the
value never appears in Terraform state or plan files.

Required when git_provider = "github".
DESCRIPTION
}

variable "github_enterprise_base_url" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The API base URL of a GitHub Enterprise Server instance, e.g.
`https://github.mycompany.com/api/v3`. Set this when using GitHub Enterprise
Server instead of github.com. When null (the default), ArgoCD authenticates
against the public GitHub API.

When set, this value is written as `githubAppEnterpriseBaseURL` in the ArgoCD
repo-creds secret, and the repo-creds URL prefix is derived from the
`platform_gitops_repo_url` hostname instead of assuming github.com.

Only used when git_provider = "github".
DESCRIPTION

  validation {
    condition     = var.github_enterprise_base_url == null || can(regex("^https://", var.github_enterprise_base_url))
    error_message = "github_enterprise_base_url must be an HTTPS URL (e.g. https://github.example.com/api/v3)."
  }
}

variable "aks_oidc_issuer_url" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The OIDC issuer URL of the AKS cluster. Used as the issuer in the federated
identity credential so that Azure AD trusts tokens issued by this cluster's
service accounts.
DESCRIPTION

  validation {
    condition     = can(regex("^https://", var.aks_oidc_issuer_url))
    error_message = "The aks_oidc_issuer_url must be an HTTPS URL."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = <<DESCRIPTION
A map of tags to apply to resources that support tagging. These are passed
as labels to Kubernetes resources created by this module.
DESCRIPTION
}
