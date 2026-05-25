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

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = aws_iam_role.alb_controller.arn
}

output "external_secrets_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets.arn
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager"
  value       = aws_iam_role.cert_manager.arn
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for ExternalDNS"
  value       = aws_iam_role.external_dns.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}
