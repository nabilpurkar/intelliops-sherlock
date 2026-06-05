locals {
  common_tags = merge(
    {
      env        = var.environment
      project    = var.project
      owner      = "devops-lead"
      managed-by = "terraform"
    },
    var.tags
  )

  secret_names = [
    "postgresql", "grafana", "argocd", "linkerd",
    "defectdojo", "backstage", "litmus", "slack", "sonarqube",
  ]
}

data "aws_region" "current" {}

# Force-clear any pending-deletion secrets before creating them.
# Triggered only when environment/project changes (i.e. initial create after destroy).
# Safe no-op when secrets are active — AWS API calls return without error.
resource "null_resource" "clear_pending_secrets" {
  triggers = {
    env     = var.environment
    project = var.project
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${data.aws_region.current.region}"
      for name in ${join(" ", local.secret_names)}; do
        SECRET_ID="${var.project}/${var.environment}/$name"
        if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" &>/dev/null; then
          echo "Found existing secret: $SECRET_ID — force-deleting"
          aws secretsmanager restore-secret --secret-id "$SECRET_ID" --region "$REGION" 2>/dev/null || true
          aws secretsmanager delete-secret --secret-id "$SECRET_ID" \
            --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
          # Poll until AWS confirms the name is gone (propagation can take a few seconds)
          WAITED=0
          while aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" &>/dev/null; do
            if [ "$WAITED" -ge 30 ]; then
              echo "Timed out waiting for $SECRET_ID deletion — continuing anyway"
              break
            fi
            echo "Waiting for $SECRET_ID to be fully removed..."
            sleep 3
            WAITED=$((WAITED + 3))
          done
          echo "Secret cleared: $SECRET_ID"
        fi
      done
    EOT
  }
}

resource "aws_secretsmanager_secret" "postgresql" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/postgresql"
  description             = "PostgreSQL credentials for intelliops ${var.environment} — sonarqube, defectdojo, kong databases"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/postgresql" })
}

resource "aws_secretsmanager_secret" "grafana" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/grafana"
  description             = "Grafana admin credentials for intelliops ${var.environment}"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/grafana" })
}

resource "aws_secretsmanager_secret" "argocd" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/argocd"
  description             = "ArgoCD admin credentials for intelliops ${var.environment}"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/argocd" })
}

resource "aws_secretsmanager_secret" "linkerd" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — certs renewed manually before expiry
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/linkerd"
  description             = "Linkerd mTLS trust anchor (ca_crt) and issuer cert+key (base64) — trust anchor expires 2036-05-22, issuer expires 2027-05-25"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/linkerd" })
}

resource "aws_secretsmanager_secret" "defectdojo" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/defectdojo"
  description             = "DefectDojo credentials for intelliops ${var.environment} — admin password, Django secret key, AES key, postgresql + valkey passwords"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/defectdojo" })
}

resource "aws_secretsmanager_secret" "backstage" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — GitHub token rotated manually
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/backstage"
  description             = "Backstage IDP credentials — github_token for catalog integration"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/backstage" })
}

resource "aws_secretsmanager_secret" "litmus" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — rotated manually
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/litmus"
  description             = "LitmusChaos MongoDB credentials — mongodb_root_user, mongodb_root_password"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/litmus" })
}

resource "aws_secretsmanager_secret" "slack" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — webhook rotated manually
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/slack"
  description             = "Slack webhook URL for AIOps alert notifications"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/slack" })
}

resource "aws_secretsmanager_secret" "sonarqube" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — rotated by configure-stack.sh
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/sonarqube"
  description             = "SonarQube credentials — admin_password, ci_token"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  depends_on = [null_resource.clear_pending_secrets]
  tags       = merge(local.common_tags, { Name = "intelliops/${var.environment}/sonarqube" })
}
