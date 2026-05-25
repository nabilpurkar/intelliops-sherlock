variable "environment" {
  description = "Deployment environment (dev, staging, prod) — used in secret name paths"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name used in resource tags"
  type        = string
  default     = "intelliops"
}

variable "recovery_window_in_days" {
  description = "Days before a deleted secret is permanently removed (0 = force delete, 7-30 for recovery window)"
  type        = number
  default     = 7
}

variable "kms_key_id" {
  description = "KMS key ARN for secret encryption. Null uses the AWS-managed aws/secretsmanager key. Pass eks module kms_key_arn for staging/prod."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags to merge into all resources"
  type        = map(string)
  default     = {}
}
