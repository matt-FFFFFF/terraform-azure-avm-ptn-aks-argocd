# Read the GitHub App private key from Key Vault at apply time.
# The value is never persisted to state thanks to ephemeral + data_wo.
ephemeral "azurerm_key_vault_secret" "github_app_private_key" {
  count        = var.git_provider == "github" ? 1 : 0
  name         = var.github_app_private_key_secret_name
  key_vault_id = var.platform_keyvault_id
}

resource "kubernetes_secret_v1" "argocd_repo_creds_github" {
  count = var.git_provider == "github" ? 1 : 0

  metadata {
    name      = "argocd-repo-creds-github"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
      "app.kubernetes.io/managed-by"   = "terraform"
      "app.kubernetes.io/part-of"      = "argocd-bootstrap"
    }
  }

  type = "Opaque"

  # Non-sensitive fields in regular data.
  data = {
    type                    = "git"
    url                     = local.repo_creds_url
    githubAppID             = var.github_app_id
    githubAppInstallationID = var.github_app_installation_id
  }

  # Private key via write-only attribute — never stored in state.
  data_wo = {
    githubAppPrivateKey = ephemeral.azurerm_key_vault_secret.github_app_private_key[0].value
  }
  data_wo_revision = 1

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]

    precondition {
      condition     = var.github_app_id != null
      error_message = "github_app_id is required when git_provider = \"github\"."
    }
    precondition {
      condition     = var.github_app_installation_id != null
      error_message = "github_app_installation_id is required when git_provider = \"github\"."
    }
    precondition {
      condition     = var.github_app_private_key_secret_name != null
      error_message = "github_app_private_key_secret_name is required when git_provider = \"github\"."
    }
  }
}
