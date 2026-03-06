resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "argocd-bootstrap"
    }
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_secret" "platform_identity" {
  metadata {
    name      = "platform-identity"
    namespace = kubernetes_namespace.argocd.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "argocd-bootstrap"
    }
  }

  data = {
    eso_client_id = var.eso_identity_client_id
    keyvault_name = local.platform_keyvault_name
    tenant_id     = var.tenant_id
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_secret" "argocd_repo_creds" {
  count = var.git_provider == "azuredevops" ? 1 : 0

  metadata {
    name      = "argocd-repo-creds-azuredevops"
    namespace = kubernetes_namespace.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
      "app.kubernetes.io/managed-by"   = "terraform"
      "app.kubernetes.io/part-of"      = "argocd-bootstrap"
    }
  }

  data = {
    type     = "git"
    url      = local.repo_creds_url
    username = "x-access-token"
    password = ""
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}
