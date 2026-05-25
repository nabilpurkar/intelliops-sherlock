variable "github_repo" {
  description = "GitHub repository in owner/repo format (e.g. nabilpurkar/intelliops-sherlock)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID — used to scope ECR and EKS ARNs"
  type        = string
}

variable "aws_region" {
  description = "AWS region for ECR/EKS ARN scoping"
  type        = string
  default     = "us-east-1"
}

variable "ecr_repo_prefix" {
  description = "ECR repository prefix — grants push access to <prefix>/* (e.g. intelliops-dev)"
  type        = string
  default     = "intelliops-dev"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if it already exists in the account."
  type        = bool
  default     = true
}

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

variable "tags" {
  description = "Additional tags to merge into all resources"
  type        = map(string)
  default     = {}
}

# ─── EKS IRSA variables ───────────────────────────────────────────────────────

variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN from the EKS module — required to create IRSA trust policies"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_url" {
  description = "OIDC issuer URL without https:// from the EKS module (e.g. oidc.eks.us-east-1.amazonaws.com/id/XXX)"
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "EKS cluster name — used as prefix in IRSA role names"
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for ExternalDNS — scopes ChangeResourceRecordSets permission"
  type        = string
  default     = ""
}
