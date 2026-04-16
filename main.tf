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

# The external-dns namespace is created by Terraform so that the azure-config
# ConfigMap exists before ArgoCD deploys the ExternalDNS Helm chart.
# The ArgoCD Application uses CreateNamespace=false since the namespace is
# pre-created here.
resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = var.external_dns_namespace

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

# ConfigMap containing the Azure provider configuration for ExternalDNS.
# ExternalDNS reads /etc/kubernetes/azure.json at startup. With workload
# identity the file only needs non-sensitive metadata — the actual token
# exchange is handled by the AKS workload identity webhook.
resource "kubernetes_config_map" "external_dns_azure_config" {
  metadata {
    name      = "external-dns-azure-config"
    namespace = kubernetes_namespace.external_dns.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "argocd-bootstrap"
    }
  }

  data = {
    "azure.json" = jsonencode({
      tenantId                     = var.tenant_id
      subscriptionId               = var.external_dns_subscription_id
      resourceGroup                = var.external_dns_resource_group
      aadClientId                  = var.external_dns_identity_client_id
      useWorkloadIdentityExtension = true
    })
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_secret" "eso_identity" {
  metadata {
    name      = "platform-identity"
    namespace = kubernetes_namespace.argocd.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "argocd-bootstrap"
    }
  }

  data = {
    eso_client_id          = var.eso_identity_client_id
    external_dns_client_id = var.external_dns_identity_client_id
    keyvault_name          = local.platform_keyvault_name
    tenant_id              = var.tenant_id
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
