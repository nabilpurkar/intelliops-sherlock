locals {
  common_tags = merge(
    {
      env        = var.environment
      project    = var.project
      owner      = "devops-lead"
      managed-by = "terraform"
    },
    var.tags
  )
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_vpc" "main" {
  id = var.vpc_id
}

# ─── KMS — Secrets Encryption (disabled for dev) ─────────────────────────────
# Uncomment for staging/prod to enable envelope encryption of secrets and EBS.

# resource "aws_kms_key" "eks" {
#   description             = "KMS key for ${var.cluster_name} Kubernetes secrets and node EBS volumes"
#   deletion_window_in_days = 7
#   enable_key_rotation     = true
#
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Sid    = "AllowAccountAdmin"
#         Effect = "Allow"
#         Principal = {
#           AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
#         }
#         Action   = "kms:*"
#         Resource = "*"
#       },
#       {
#         Sid    = "AllowAutoScalingServiceRole"
#         Effect = "Allow"
#         Principal = {
#           AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
#         }
#         Action = [
#           "kms:Encrypt",
#           "kms:Decrypt",
#           "kms:ReEncrypt*",
#           "kms:GenerateDataKey*",
#           "kms:DescribeKey",
#           "kms:CreateGrant",
#         ]
#         Resource = "*"
#         Condition = {
#           Bool = { "kms:GrantIsForAWSResource" = "true" }
#         }
#       },
#       {
#         Sid    = "AllowEKSNodeRole"
#         Effect = "Allow"
#         Principal = {
#           AWS = aws_iam_role.node.arn
#         }
#         Action = [
#           "kms:Encrypt",
#           "kms:Decrypt",
#           "kms:ReEncrypt*",
#           "kms:GenerateDataKey*",
#           "kms:DescribeKey",
#           "kms:CreateGrant",
#         ]
#         Resource = "*"
#         Condition = {
#           Bool = { "kms:GrantIsForAWSResource" = "true" }
#         }
#       },
#     ]
#   })
# }
#
# resource "aws_kms_alias" "eks" {
#   name          = "alias/${var.cluster_name}-secrets"
#   target_key_id = aws_kms_key.eks.key_id
# }
#
# resource "aws_kms_grant" "autoscaling" {
#   name              = "${var.project}-${var.environment}-autoscaling-grant"
#   key_id            = aws_kms_key.eks.key_id
#   grantee_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
#   operations = [
#     "Encrypt",
#     "Decrypt",
#     "ReEncryptFrom",
#     "ReEncryptTo",
#     "GenerateDataKey",
#     "GenerateDataKeyWithoutPlaintext",
#     "DescribeKey",
#     "CreateGrant",
#   ]
# }

# ─── CloudWatch Log Group — Control Plane ────────────────────────────────────

resource "aws_cloudwatch_log_group" "eks" {
  #checkov:skip=CKV_AWS_158: KMS encryption skipped for dev, enabled in prod
  #checkov:skip=CKV_AWS_338: 30-day retention sufficient for dev, 1-year in prod
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = local.common_tags
}

# ─── IAM — Cluster Role ───────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ─── Security Group — Control Plane ──────────────────────────────────────────

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS control plane - accepts HTTPS from nodes, egress to kubelet"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-sg" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "cluster_ingress_nodes_443" {
  description              = "Nodes to API server (HTTPS)"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "cluster_ingress_cidr_443" {
  count             = length(var.allowed_cidr_blocks) > 0 ? 1 : 0
  description       = "HTTPS from allowed CIDRs (bastion/dev instances)"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "cluster_ingress_ipv6_443" {
  count             = length(var.allowed_ipv6_cidr_blocks) > 0 ? 1 : 0
  description       = "HTTPS from allowed IPv6 CIDRs (dev machine - kubectl access)"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  ipv6_cidr_blocks  = var.allowed_ipv6_cidr_blocks
  security_group_id = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "cluster_egress_kubelet" {
  description              = "API server to kubelet on nodes"
  type                     = "egress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "cluster_egress_webhooks" {
  description              = "API server to admission webhooks on nodes"
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster.id
}

# ─── Security Group — Nodes ───────────────────────────────────────────────────

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node-sg"
  description = "EKS managed nodes - pod networking and outbound AWS service access"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "node_ingress_self" {
  description       = "Node-to-node (pod-to-pod networking)"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_ingress_cluster_kubelet" {
  description              = "API server to kubelet (metrics, exec, logs)"
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_ingress_cluster_webhooks" {
  description              = "API server to admission webhooks on nodes"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_ingress_ipv6_all" {
  count             = length(var.allowed_ipv6_cidr_blocks) > 0 ? 1 : 0
  description       = "All TCP from allowed IPv6 CIDRs (dev machine - kubectl, NodePort, metrics)"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  ipv6_cidr_blocks  = var.allowed_ipv6_cidr_blocks
  security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_ingress_alb" {
  count                    = var.alb_security_group_id != "" ? 1 : 0
  description              = "ALB to pods (target-type: ip, all node ports)"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = var.alb_security_group_id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_egress_https" {
  description       = "Nodes to AWS services (ECR, S3, CloudWatch, STS) via NAT"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_egress_dns_tcp" {
  description       = "DNS (TCP) to VPC resolver"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_egress_dns_udp" {
  description       = "DNS (UDP) to VPC resolver"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  security_group_id = aws_security_group.node.id
}

# ─── EKS Cluster ─────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  #checkov:skip=CKV_AWS_339: EKS 1.33 is latest stable version, Checkov list not yet updated
  #checkov:skip=CKV_AWS_39: public endpoint intentionally enabled for dev; set endpoint_public_access=false in prod
  #checkov:skip=CKV_AWS_58: secrets encryption disabled for dev; enable KMS block for staging/prod
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : null
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # encryption_config — disabled for dev; uncomment for staging/prod
  # encryption_config {
  #   provider {
  #     key_arn = aws_kms_key.eks.arn
  #   }
  #   resources = ["secrets"]
  # }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.eks,
  ]
}

# ─── OIDC Provider (IRSA) ─────────────────────────────────────────────────────

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = local.common_tags
}

# ─── IAM — Node Role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM Session Manager access — no SSH key needed on nodes
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ─── Launch Template — IMDSv2 + Encrypted EBS ────────────────────────────────

resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"
  description = "IMDSv2-only, encrypted gp3 root volume, dual SG attachment"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.node_disk_size
      volume_type = "gp3"
      encrypted   = true # uses default aws/ebs key in dev
      # kms_key_id          = aws_kms_key.eks.arn  # uncomment for staging/prod
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  # Include both our custom node SG and the EKS-managed cluster SG.
  # Without the cluster SG here, managed nodes lose the auto-injected
  # control-plane communication rules.
  vpc_security_group_ids = [
    aws_security_group.node.id,
    aws_eks_cluster.main.vpc_config[0].cluster_security_group_id,
  ]

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  tags = local.common_tags

  lifecycle { create_before_destroy = true }
}

# ─── Managed Node Group ───────────────────────────────────────────────────────

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# ─── IRSA — EBS CSI Driver ────────────────────────────────────────────────────

locals {
  oidc_issuer = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ─── EKS Add-ons ─────────────────────────────────────────────────────────────

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

# coredns requires at least one node before it can schedule
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.main]
}
