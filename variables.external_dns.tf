variable "external_dns_identity_client_id" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The client ID of the managed identity used by ExternalDNS to manage records
in Azure DNS. The identity must have the DNS Zone Contributor role on the
target Azure DNS zone. Written to the platform-identity Kubernetes secret
so that the ExternalDNS ArgoCD Application can reference it.
DESCRIPTION

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.external_dns_identity_client_id))
    error_message = "The external_dns_identity_client_id must be a valid UUID."
  }
}

variable "external_dns_identity_resource_id" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The Azure resource ID of the managed identity used by ExternalDNS. This is
the parent resource for the federated identity credential that this module
creates. The federated credential binds this identity to the ExternalDNS
controller Kubernetes service account, enabling workload identity
authentication to Azure DNS.

Example: `/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-external-dns`
DESCRIPTION

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.external_dns_identity_resource_id))
    error_message = "The external_dns_identity_resource_id must be a valid Azure resource ID for a user-assigned managed identity."
  }
}

variable "external_dns_namespace" {
  type        = string
  default     = "external-dns"
  nullable    = false
  description = <<DESCRIPTION
The Kubernetes namespace where ExternalDNS will be deployed by Argo CD.
Must match the destination namespace in the ExternalDNS Application manifest
in the platform-gitops repo. Used to construct the federated identity
credential subject.
DESCRIPTION

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.external_dns_namespace))
    error_message = "The external_dns_namespace must be a valid Kubernetes namespace name (lowercase alphanumeric and hyphens, max 63 characters)."
  }
}

variable "external_dns_service_account_name" {
  type        = string
  default     = "external-dns"
  nullable    = false
  description = <<DESCRIPTION
The name of the Kubernetes service account created by the ExternalDNS Helm
chart. Must match the service account name that the Helm chart creates,
which defaults to the release name. Used to construct the federated identity
credential subject.
DESCRIPTION
}
