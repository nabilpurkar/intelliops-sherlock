output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Private API server endpoint for the EKS cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = aws_eks_cluster.main.arn
}

output "node_group_arn" {
  description = "ARN of the managed node group"
  value       = aws_eks_node_group.main.arn
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for cluster authentication"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — use this to create IRSA roles for workloads"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without https:// — used as the condition variable prefix in IRSA trust policies"
  value       = local.oidc_issuer
}

output "cluster_security_group_id" {
  description = "ID of the EKS-managed cluster security group (auto-attached to nodes)"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "ID of the custom node security group"
  value       = aws_security_group.node.id
}

# output "kms_key_arn" — disabled for dev (KMS commented out)
# output "kms_key_arn" {
#   description = "ARN of the KMS key used for secrets encryption and node EBS volumes"
#   value       = aws_kms_key.eks.arn
# }
