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
