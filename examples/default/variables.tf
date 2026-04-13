variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Controls whether AVM telemetry is enabled for the module."
}

# These variables would typically come from Terraform Workspace 1 outputs,
# passed via CI/CD pipeline variables or tfvars file.

variable "aks_host" {
  type        = string
  description = "The AKS cluster API server host URL."
}

variable "aks_client_certificate" {
  type        = string
  sensitive   = true
  description = "Base64 encoded client certificate for AKS authentication."
}

variable "aks_client_key" {
  type        = string
  sensitive   = true
  description = "Base64 encoded client key for AKS authentication."
}

variable "aks_cluster_ca_certificate" {
  type        = string
  sensitive   = true
  description = "Base64 encoded cluster CA certificate for AKS authentication."
}

variable "tenant_id" {
  type        = string
  description = "The Azure AD tenant ID."
}

variable "platform_keyvault_id" {
  type        = string
  description = "The Azure resource ID of the platform Key Vault for gateway TLS certificates."
}

variable "eso_identity_client_id" {
  type        = string
  description = "The client ID of the managed identity for ESO."
}

variable "eso_identity_resource_id" {
  type        = string
  description = "The Azure resource ID of the managed identity for ESO."
}

variable "argocd_repo_identity_client_id" {
  type        = string
  description = "The client ID of the managed identity for the Argo CD repo-server."
}

variable "argocd_repo_identity_resource_id" {
  type        = string
  description = "The Azure resource ID of the managed identity for the Argo CD repo-server."
}

variable "aks_oidc_issuer_url" {
  type        = string
  description = "The OIDC issuer URL of the AKS cluster."
}

variable "external_dns_identity_client_id" {
  type        = string
  description = "The client ID of the managed identity for ExternalDNS."
}

variable "external_dns_identity_resource_id" {
  type        = string
  description = "The Azure resource ID of the managed identity for ExternalDNS."
}

variable "external_dns_subscription_id" {
  type        = string
  description = "The Azure subscription ID containing the DNS zone managed by ExternalDNS."
}

variable "external_dns_resource_group" {
  type        = string
  description = "The Azure resource group containing the DNS zone managed by ExternalDNS."
}
