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
}

resource "aws_secretsmanager_secret" "postgresql" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/postgresql"
  description             = "PostgreSQL credentials for intelliops ${var.environment} — sonarqube, defectdojo, kong databases"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  tags = merge(local.common_tags, { Name = "intelliops/${var.environment}/postgresql" })
}

resource "aws_secretsmanager_secret" "grafana" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/grafana"
  description             = "Grafana admin credentials for intelliops ${var.environment}"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  tags = merge(local.common_tags, { Name = "intelliops/${var.environment}/grafana" })
}

resource "aws_secretsmanager_secret" "argocd" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — credentials rotated manually for dev
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/argocd"
  description             = "ArgoCD admin credentials for intelliops ${var.environment}"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  tags = merge(local.common_tags, { Name = "intelliops/${var.environment}/argocd" })
}

resource "aws_secretsmanager_secret" "linkerd" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — certs renewed manually before expiry
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev; set kms_key_id variable for staging/prod
  name                    = "intelliops/${var.environment}/linkerd"
  description             = "Linkerd mTLS trust anchor (ca_crt) and issuer cert+key (base64) — trust anchor expires 2036-05-22, issuer expires 2027-05-25"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  tags = merge(local.common_tags, { Name = "intelliops/${var.environment}/linkerd" })
}
