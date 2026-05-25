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
  value       = var.eks_oidc_provider_arn != "" ? aws_iam_role.alb_controller[0].arn : ""
}

output "external_secrets_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = var.eks_oidc_provider_arn != "" ? aws_iam_role.external_secrets[0].arn : ""
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager"
  value       = var.eks_oidc_provider_arn != "" ? aws_iam_role.cert_manager[0].arn : ""
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for ExternalDNS"
  value       = var.eks_oidc_provider_arn != "" ? aws_iam_role.external_dns[0].arn : ""
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler"
  value       = var.eks_oidc_provider_arn != "" ? aws_iam_role.cluster_autoscaler[0].arn : ""
}
