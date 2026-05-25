output "role_arn" {
  description = "IAM role ARN — use as role-to-assume in GitHub Actions OIDC config"
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "IAM role name"
  value       = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN"
  value       = local.oidc_provider_arn
}
