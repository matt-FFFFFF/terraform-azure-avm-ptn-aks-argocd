output "argocd_namespace" {
  value       = kubernetes_namespace.argocd.metadata[0].name
  description = "The Kubernetes namespace where Argo CD is installed."
}

output "argocd_server_service_name" {
  value       = "argocd-server"
  description = <<DESCRIPTION
The name of the Argo CD server Kubernetes service. Use this for port-forwarding
or configuring ingress/gateway routes:

  kubectl port-forward svc/argocd-server -n <namespace> 8080:443
DESCRIPTION
}

output "platform_identity_secret_name" {
  value       = kubernetes_secret.platform_identity.metadata[0].name
  description = <<DESCRIPTION
The name of the Kubernetes secret containing platform identity values
(ESO client ID, Key Vault name, tenant ID). Reference this in the
platform-gitops repo when configuring the ESO ClusterSecretStore.
DESCRIPTION
}

output "repo_creds_url" {
  value       = local.repo_creds_url
  description = <<DESCRIPTION
The base URL used for the Argo CD repository credential template. All Git
repositories whose URL starts with this prefix will use workload identity
authentication via GIT_ASKPASS.
DESCRIPTION
}

output "helm_release_name" {
  value       = helm_release.argocd.name
  description = "The name of the Argo CD Helm release."
}

output "helm_release_version" {
  value       = helm_release.argocd.version
  description = "The version of the Argo CD Helm chart that was deployed."
}

output "argocd_repo_server_service_account" {
  value       = local.argocd_repo_server_sa
  description = <<DESCRIPTION
The name of the Kubernetes service account used by the Argo CD repo-server.
This is the service account that the federated identity credential is bound to.
DESCRIPTION
}

output "argocd_repo_federated_credential_id" {
  value       = azapi_resource.argocd_repo_federated_credential.id
  description = "The Azure resource ID of the federated identity credential for the Argo CD repo-server."
}

output "eso_federated_credential_id" {
  value       = azapi_resource.eso_federated_credential.id
  description = "The Azure resource ID of the federated identity credential for the External Secrets Operator."
}

output "eso_service_account_name" {
  value       = var.eso_service_account_name
  description = <<DESCRIPTION
The name of the Kubernetes service account that the ESO federated identity
credential is bound to. The ESO Helm chart must create a service account
with this exact name for workload identity to function.
DESCRIPTION
}
