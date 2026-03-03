resource "kubernetes_config_map" "git_askpass" {
  count = var.git_provider == "azuredevops" ? 1 : 0

  metadata {
    name      = "argocd-git-askpass"
    namespace = kubernetes_namespace.argocd.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "argocd-bootstrap"
    }
  }

  data = {
    "git-askpass.sh" = local.git_askpass_script
  }

  lifecycle {
    # Argo CD adopts this ConfigMap after first sync via the platform-gitops repo.
    # Ignore changes to data so Terraform does not fight with Argo CD over the
    # script content after bootstrap.
    ignore_changes = [data]
  }
}

resource "helm_release" "argocd" {
  name       = local.argocd_helm_release_name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_helm_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Base values include workload identity config, GIT_ASKPASS volume mount,
  # server service type, and the self-manage Application via extraObjects.
  # Additional user values are deep-merged on top by the Helm provider.
  values = concat(
    [yamlencode(local.argocd_helm_values_base)],
    var.argocd_additional_helm_values
  )

  # Wait for the ConfigMap, repo-creds, and federated credential to exist before
  # installing Argo CD, so the repo-server pod can authenticate immediately on startup.
  depends_on = [
    kubernetes_config_map.git_askpass,
    kubernetes_secret.argocd_repo_creds,
    kubernetes_secret_v1.argocd_repo_creds_github,
    azapi_resource.argocd_repo_federated_credential,
  ]

  lifecycle {
    # After bootstrap, Argo CD self-manages its own Helm chart from the
    # platform-gitops repo. Ignore changes to values so Terraform does not
    # revert Argo CD's self-managed configuration on subsequent applies.
    ignore_changes = [values]
  }
}
