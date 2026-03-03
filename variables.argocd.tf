variable "argocd_namespace" {
  type        = string
  default     = "argocd"
  nullable    = false
  description = <<DESCRIPTION
The Kubernetes namespace in which to install Argo CD. The namespace is created
by this module if it does not already exist.
DESCRIPTION

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.argocd_namespace))
    error_message = "The argocd_namespace must be a valid Kubernetes namespace name (lowercase alphanumeric and hyphens, max 63 characters)."
  }
}

variable "argocd_helm_version" {
  type        = string
  default     = "7.8.8"
  nullable    = false
  description = <<DESCRIPTION
The version of the Argo CD Helm chart to install. This is the chart version,
not the Argo CD application version. See https://github.com/argoproj/argo-helm
for available versions.
DESCRIPTION
}

variable "argocd_additional_helm_values" {
  type        = list(string)
  default     = []
  nullable    = false
  description = <<DESCRIPTION
Additional Helm values to pass to the Argo CD chart as a list of YAML strings.
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
DESCRIPTION
}

variable "argocd_server_service_type" {
  type        = string
  default     = "ClusterIP"
  nullable    = false
  description = <<DESCRIPTION
The Kubernetes service type for the Argo CD server. Use `ClusterIP` for internal
access (recommended when using an Istio Gateway or ingress controller), or
`LoadBalancer` for direct external access.
DESCRIPTION

  validation {
    condition     = contains(["ClusterIP", "LoadBalancer", "NodePort"], var.argocd_server_service_type)
    error_message = "The argocd_server_service_type must be one of: ClusterIP, LoadBalancer, NodePort."
  }
}

variable "platform_gitops_repo_url" {
  type        = string
  nullable    = false
  description = <<DESCRIPTION
The Git repository URL for the platform-gitops repository. This is the repo
that Argo CD will sync to self-manage its own configuration and deploy
platform components (ESO, Gateway, namespaces, AppProjects, etc.).

Example: `https://dev.azure.com/org/project/_git/platform-gitops`
Example: `https://github.com/org/platform-gitops`
DESCRIPTION

  validation {
    condition     = can(regex("^https://", var.platform_gitops_repo_url))
    error_message = "The platform_gitops_repo_url must be an HTTPS URL."
  }
}

variable "platform_gitops_repo_path" {
  type        = string
  default     = "argocd"
  nullable    = false
  description = <<DESCRIPTION
The path within the platform-gitops repository where the Argo CD self-management
configuration is located. This is the path that the platform-root Application
will sync from.
DESCRIPTION
}

variable "platform_gitops_repo_revision" {
  type        = string
  default     = "main"
  nullable    = false
  description = <<DESCRIPTION
The Git revision (branch, tag, or commit SHA) of the platform-gitops repository
to sync. Defaults to `main`.
DESCRIPTION
}

variable "argocd_repo_creds_url" {
  type        = string
  default     = null
  description = <<DESCRIPTION
The base URL for the Argo CD repository credential template. All Git repos
whose URL starts with this prefix will use the authentication method configured
by this module.

If not set, the default is derived from `var.platform_gitops_repo_url`:
- Azure DevOps: the organization-level URL, e.g. `https://dev.azure.com/org/`
- GitHub: the organization-level URL, e.g. `https://github.com/org/`

Set this to a more specific URL to restrict which repos use these credentials,
or to a broader URL if your repos span multiple organizations.
DESCRIPTION
}
