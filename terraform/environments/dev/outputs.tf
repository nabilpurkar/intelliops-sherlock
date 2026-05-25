output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (used as node subnets in dev)"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN — use when creating new IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "EKS OIDC issuer URL (without https://)"
  value       = module.eks.oidc_provider_url
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by service name"
  value       = module.ecr.repository_urls
}

# ─── IRSA Role ARNs ───────────────────────────────────────────────────────────

output "irsa_alb_controller_role_arn" {
  description = "IRSA role ARN for aws-load-balancer-controller — paste into aws-lb-controller-values.yaml"
  value       = module.iam.alb_controller_role_arn
}

output "irsa_external_secrets_role_arn" {
  description = "IRSA role ARN for external-secrets — paste into external-secrets-values.yaml"
  value       = module.iam.external_secrets_role_arn
}

output "irsa_cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager — paste into cert-manager-values.yaml"
  value       = module.iam.cert_manager_role_arn
}

output "irsa_external_dns_role_arn" {
  description = "IRSA role ARN for ExternalDNS — paste into external-dns-values.yaml"
  value       = module.iam.external_dns_role_arn
}

output "irsa_cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler — paste into cluster-autoscaler-values.yaml"
  value       = module.iam.cluster_autoscaler_role_arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC role ARN — configured in ci.yml"
  value       = module.iam.role_arn
}

# ─── Secrets ──────────────────────────────────────────────────────────────────

output "postgresql_secret_arn" {
  description = "ARN of the PostgreSQL credentials secret"
  value       = module.secrets.postgresql_secret_arn
}

output "grafana_secret_arn" {
  description = "ARN of the Grafana credentials secret"
  value       = module.secrets.grafana_secret_arn
}

output "argocd_secret_arn" {
  description = "ARN of the ArgoCD credentials secret"
  value       = module.secrets.argocd_secret_arn
}

output "linkerd_secret_arn" {
  description = "ARN of the Linkerd mTLS certs secret"
  value       = module.secrets.linkerd_secret_arn
}

output "defectdojo_secret_arn" {
  description = "ARN of the DefectDojo credentials secret"
  value       = module.secrets.defectdojo_secret_arn
}
