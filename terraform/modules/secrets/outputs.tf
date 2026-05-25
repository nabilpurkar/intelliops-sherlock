output "postgresql_secret_arn" {
  description = "ARN of the PostgreSQL credentials secret"
  value       = aws_secretsmanager_secret.postgresql.arn
}

output "grafana_secret_arn" {
  description = "ARN of the Grafana credentials secret"
  value       = aws_secretsmanager_secret.grafana.arn
}

output "argocd_secret_arn" {
  description = "ARN of the ArgoCD credentials secret"
  value       = aws_secretsmanager_secret.argocd.arn
}

output "linkerd_secret_arn" {
  description = "ARN of the Linkerd mTLS certs secret"
  value       = aws_secretsmanager_secret.linkerd.arn
}

output "defectdojo_secret_arn" {
  description = "ARN of the DefectDojo credentials secret"
  value       = aws_secretsmanager_secret.defectdojo.arn
}
