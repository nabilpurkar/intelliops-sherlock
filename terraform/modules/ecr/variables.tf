variable "services" {
  description = "Service names to create ECR repositories for — each becomes <project>-<env>/<service>"
  type        = list(string)
  default     = ["order-service", "payment-service", "inventory-service", "load-generator"]
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name used as a prefix in repository names"
  type        = string
  default     = "intelliops"
}

variable "tags" {
  description = "Additional tags to merge into all resources"
  type        = map(string)
  default     = {}
}
