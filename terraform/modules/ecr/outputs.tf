output "repository_urls" {
  description = "ECR repository URL for each service — use as the image prefix in k8s deployments"
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "repository_arns" {
  description = "ECR repository ARN for each service — use in IAM policies for push/pull access"
  value       = { for k, v in aws_ecr_repository.services : k => v.arn }
}
