variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name used in resource tags"
  type        = string
  default     = "intelliops"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name — used in IRSA role name and trust condition"
  type        = string
}

variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS module"
  type        = string
}

variable "eks_oidc_provider_url" {
  description = "OIDC issuer URL without https:// (e.g. oidc.eks.us-east-1.amazonaws.com/id/XXX)"
  type        = string
}

variable "recovery_window_in_days" {
  description = "Secrets Manager recovery window. Set to 0 to allow immediate deletion (dev only)."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Additional tags to merge into all resources"
  type        = map(string)
  default     = {}
}
