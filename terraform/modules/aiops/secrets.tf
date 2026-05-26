# Converted from: aws secretsmanager create-secret --name intelliops/dev/slack ...
resource "aws_secretsmanager_secret" "slack" {
  #checkov:skip=CKV2_AWS_57: Auto-rotation not configured — webhook URL rotated manually
  #checkov:skip=CKV_AWS_149: KMS CMK not required for dev
  name                    = "intelliops/${var.environment}/slack"
  description             = "Slack webhook URL for AI agent auto-remediation alerts"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.common_tags, { Name = "intelliops/${var.environment}/slack" })
}
