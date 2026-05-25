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
