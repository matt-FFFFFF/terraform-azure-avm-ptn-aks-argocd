resource "random_uuid" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
}

resource "modtm_telemetry" "this" {
  count = var.enable_telemetry ? 1 : 0

  tags = {
    avm_git_commit            = "0000000"
    avm_git_file              = "main.telemetry.tf"
    avm_yor_name              = "this"
    avm_yor_trace             = random_uuid.telemetry[0].result
    avm_ptn_id                = "ptn-aks-argocd"
    avm_ptn_name              = "terraform-azure-avm-ptn-aks-argocd"
    avm_ptn_classification    = "pattern"
    avm_ptn_terraform_version = ">=1.9"
  }
}
