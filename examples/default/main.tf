# This example demonstrates bootstrapping Argo CD on an AKS cluster with
# workload identity authentication to Azure DevOps.
#
# Prerequisites (created by Terraform Workspace 1 - Infrastructure):
# - AKS cluster with OIDC issuer enabled
# - Managed identity for Argo CD repo-server (this module creates the federated credential)
# - Managed identity for ESO with Key Vault access
# - Azure Key Vault
# - The Argo CD repo-server identity must have read access to your Azure DevOps repos

module "aks_argocd_bootstrap" {
  source = "../../"

  # Core identity values from Workspace 1 outputs
  tenant_id                        = var.tenant_id
  platform_keyvault_id             = var.platform_keyvault_id
  eso_identity_client_id           = var.eso_identity_client_id
  eso_identity_resource_id         = var.eso_identity_resource_id
  argocd_repo_identity_client_id   = var.argocd_repo_identity_client_id
  argocd_repo_identity_resource_id = var.argocd_repo_identity_resource_id

  # AKS OIDC issuer URL for federated identity credential
  aks_oidc_issuer_url = var.aks_oidc_issuer_url

  # Platform GitOps repo in Azure DevOps
  platform_gitops_repo_url      = "https://dev.azure.com/org/project/_git/platform-gitops"
  platform_gitops_repo_path     = "argocd"
  platform_gitops_repo_revision = "main"

  # Optional: restrict repo-creds to a specific Azure DevOps project
  # argocd_repo_creds_url = "https://dev.azure.com/org/project/"

  # Optional: override Argo CD Helm values
  # argocd_additional_helm_values = [
  #   yamlencode({
  #     server = {
  #       replicas = 2
  #       resources = {
  #         requests = { cpu = "250m", memory = "256Mi" }
  #         limits   = { cpu = "500m", memory = "512Mi" }
  #       }
  #     }
  #   })
  # ]

  enable_telemetry = var.enable_telemetry
}
