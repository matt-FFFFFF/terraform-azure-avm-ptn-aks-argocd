locals {
  # Derive the Key Vault name from the resource ID.
  # e.g. /subscriptions/.../providers/Microsoft.KeyVault/vaults/kv-platform-tls -> kv-platform-tls
  platform_keyvault_name = basename(var.platform_keyvault_id)

  # The Helm release name determines the service account names.
  # The argo-cd chart creates SAs named: <release>-<component>
  argocd_helm_release_name = "argocd"
  argocd_repo_server_sa    = "${local.argocd_helm_release_name}-repo-server"

  # The federated identity credential subject must exactly match the
  # Kubernetes service account used by the Argo CD repo-server pod.
  argocd_repo_server_federated_subject = "system:serviceaccount:${var.argocd_namespace}:${local.argocd_repo_server_sa}"

  # The federated identity credential subject for the ExternalDNS controller.
  # ExternalDNS is deployed by Argo CD (sync wave 2), but the FIC must exist
  # before ExternalDNS pods can authenticate to Azure DNS via workload identity.
  external_dns_federated_subject = "system:serviceaccount:${var.external_dns_namespace}:${var.external_dns_service_account_name}"

  # The federated identity credential subject for the ESO controller.
  # ESO is deployed by Argo CD (sync wave 0), but the FIC must exist
  # before ESO pods can authenticate to Key Vault.
  eso_federated_subject = "system:serviceaccount:${var.eso_namespace}:${var.eso_service_account_name}"

  # Derive the org-level URL from the platform repo URL for repo-creds template.
  # Azure DevOps: https://dev.azure.com/org/project/_git/repo -> https://dev.azure.com/org/
  # GitHub:       https://github.com/org/repo                 -> https://github.com/org/
  # GitHub (GHE): https://github.corp.com/org/repo            -> https://github.corp.com/org/
  repo_creds_url = coalesce(
    var.argocd_repo_creds_url,
    var.git_provider == "github"
    ? try(regex("^(https://[^/]+/[^/]+/)", var.platform_gitops_repo_url)[0], var.platform_gitops_repo_url)
    : try(regex("^(https://dev\\.azure\\.com/[^/]+/)", var.platform_gitops_repo_url)[0], var.platform_gitops_repo_url)
  )

  # The GIT_ASKPASS script acquires an Azure AD token via workload identity federation
  # and returns it to Git as the password for HTTPS authentication to Azure DevOps.
  # Uses python3 (available in the Argo CD base image) instead of jq for JSON parsing.
  git_askpass_script = <<-SCRIPT
    #!/bin/bash
    TOKEN=$(curl -s "$${AZURE_AUTHORITY_HOST}$${AZURE_TENANT_ID}/oauth2/v2.0/token" \
      -d "client_id=$${AZURE_CLIENT_ID}" \
      -d "scope=499b84ac-1321-427f-aa17-267ca6975798/.default" \
      -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
      -d "client_assertion=$(cat $${AZURE_FEDERATED_TOKEN_FILE})" \
      -d "grant_type=client_credentials" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    echo "$TOKEN"
  SCRIPT

  # Base Helm values for Argo CD. These configure:
  # 1. Server service type
  # 2. The self-manage Application via extraObjects
  # 3. (ADO only) Workload identity on the repo-server, GIT_ASKPASS env + volume mount
  argocd_helm_values_base = merge(
    {
      server = {
        service = {
          type = var.argocd_server_service_type
        }
      }
      extraObjects = [
        {
          apiVersion = "argoproj.io/v1alpha1"
          kind       = "Application"
          metadata = {
            name      = "platform-root"
            namespace = var.argocd_namespace
          }
          spec = {
            project = "default"
            source = {
              repoURL        = var.platform_gitops_repo_url
              path           = var.platform_gitops_repo_path
              targetRevision = var.platform_gitops_repo_revision
            }
            destination = {
              server    = "https://kubernetes.default.svc"
              namespace = var.argocd_namespace
            }
            syncPolicy = {
              automated = {
                prune    = true
                selfHeal = true
              }
            }
          }
        }
      ]
    },
    var.git_provider == "azuredevops" ? {
      repoServer = {
        serviceAccount = {
          annotations = {
            "azure.workload.identity/client-id" = var.argocd_repo_identity_client_id
          }
        }
        podLabels = {
          "azure.workload.identity/use" = "true"
        }
        env = [
          {
            name  = "GIT_ASKPASS"
            value = "/usr/local/bin/git-askpass.sh"
          }
        ]
        volumes = [
          {
            name = "git-askpass"
            configMap = {
              name        = "argocd-git-askpass"
              defaultMode = 493 # 0755 in octal
            }
          }
        ]
        volumeMounts = [
          {
            name      = "git-askpass"
            mountPath = "/usr/local/bin/git-askpass.sh"
            subPath   = "git-askpass.sh"
          }
        ]
      }
    } : {}
  )
}
