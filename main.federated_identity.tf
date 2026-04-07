# Federated identity credential for the Argo CD repo-server service account.
# This binds the managed identity (created in WS1) to the Kubernetes service
# account created by the Argo CD Helm chart, enabling workload identity
# federation for Azure DevOps repository access.
#
# The subject is derived from the Helm release name and namespace, ensuring
# that changes to either are automatically reflected in the credential.
resource "azapi_resource" "argocd_repo_federated_credential" {
  count     = var.git_provider == "azuredevops" ? 1 : 0
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  name      = "fc-argocd-repo-server"
  parent_id = var.argocd_repo_identity_resource_id

  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = var.aks_oidc_issuer_url
      subject   = local.argocd_repo_server_federated_subject
    }
  }

  lifecycle {
    precondition {
      condition     = var.argocd_repo_identity_client_id != null
      error_message = "argocd_repo_identity_client_id is required when git_provider = \"azuredevops\"."
    }
    precondition {
      condition     = var.argocd_repo_identity_resource_id != null
      error_message = "argocd_repo_identity_resource_id is required when git_provider = \"azuredevops\"."
    }
  }
}

# Federated identity credential for the ExternalDNS service account.
# ExternalDNS is deployed by Argo CD (sync wave 2), but the FIC must exist
# before ExternalDNS pods can authenticate to Azure DNS via workload identity.
# The identity must have DNS Zone Contributor on the target Azure DNS zone.
resource "azapi_resource" "external_dns_federated_credential" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  name      = "fc-external-dns"
  parent_id = var.external_dns_identity_resource_id

  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = var.aks_oidc_issuer_url
      subject   = local.external_dns_federated_subject
    }
  }
}

# Federated identity credential for the External Secrets Operator service account.
# ESO is deployed by Argo CD (sync wave 0), but the FIC must exist before ESO
# pods can authenticate to Azure Key Vault via workload identity. This module
# creates it because the service account name is deterministic from the ESO
# Helm chart conventions.
#
# The subject is derived from var.eso_namespace and var.eso_service_account_name,
# which must match the ESO Application spec in the platform-gitops repo.
resource "azapi_resource" "eso_federated_credential" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  name      = "fc-external-secrets"
  parent_id = var.eso_identity_resource_id

  body = {
    properties = {
      audiences = ["api://AzureADTokenExchange"]
      issuer    = var.aks_oidc_issuer_url
      subject   = local.eso_federated_subject
    }
  }
}
