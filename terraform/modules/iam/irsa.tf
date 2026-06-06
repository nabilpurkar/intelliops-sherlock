locals {
  irsa_trust = {
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  }
}

# ─── AWS Load Balancer Controller ─────────────────────────────────────────────

resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust, {
    Statement = [
      merge(local.irsa_trust.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-alb-controller-role" })
}

resource "aws_iam_role_policy" "alb_controller" {
  #checkov:skip=CKV_AWS_355: ALB controller requires broad EC2/ELB permissions — scoped per AWS-recommended policy
  #checkov:skip=CKV_AWS_287: ec2:* / elasticloadbalancing:* are AWS-prescribed permissions for the ALB controller
  #checkov:skip=CKV_AWS_289: Resource exposure permissions are required by the ALB controller to manage load balancers
  #checkov:skip=CKV_AWS_290: Write access without constraints is required — mirrors the official AWS ALB controller IAM policy

  name = "alb-controller-policy"
  role = aws_iam_role.alb_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ALBControllerCore"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "elasticloadbalancing:*",
          "cognito-idp:DescribeUserPoolClient",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
        ]
        Resource = "*"
      },
      {
        Sid      = "ALBControllerIAM"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
    ]
  })
}

# ─── External Secrets Operator ────────────────────────────────────────────────

resource "aws_iam_role" "external_secrets" {
  name = "${var.cluster_name}-external-secrets-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust, {
    Statement = [
      merge(local.irsa_trust.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-external-secrets-role" })
}

resource "aws_iam_role_policy" "external_secrets" {
  #checkov:skip=CKV_AWS_355: secretsmanager:GetSecretValue and kms:Decrypt require wildcard in dev (no per-secret scoping yet)
  #checkov:skip=CKV_AWS_290: kms:Decrypt wildcard resource is required for dev — scope to CMK ARN in prod

  name = "external-secrets-policy"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:intelliops/${var.environment}/*"
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
      },
    ]
  })
}

# ─── cert-manager ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "cert_manager" {
  name = "${var.cluster_name}-cert-manager-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust, {
    Statement = [
      merge(local.irsa_trust.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cert-manager-role" })
}

resource "aws_iam_role_policy" "cert_manager" {
  #checkov:skip=CKV_AWS_355: Route53 zone listing requires wildcard resource — ChangeResourceRecordSets is scoped to hostedzone/*

  name = "cert-manager-route53-policy"
  role = aws_iam_role.cert_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Route53Changes"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/*"
      },
      {
        Sid    = "Route53List"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
        ]
        Resource = "*"
      },
    ]
  })
}

# ─── ExternalDNS ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "external_dns" {
  name = "${var.cluster_name}-external-dns-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust, {
    Statement = [
      merge(local.irsa_trust.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:external-dns:external-dns"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-external-dns-role" })
}

resource "aws_iam_role_policy" "external_dns" {
  #checkov:skip=CKV_AWS_355: Route53 zone listing requires wildcard — ChangeResourceRecordSets scoped to specific hosted zone

  name = "external-dns-route53-policy"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Route53Changes"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        Sid    = "Route53List"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = "*"
      },
    ]
  })
}

# ─── Cluster Autoscaler ───────────────────────────────────────────────────────

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust, {
    Statement = [
      merge(local.irsa_trust.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-autoscaler-role" })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  #checkov:skip=CKV_AWS_355: autoscaling:Describe* requires wildcard — no resource-level scoping available

  name = "cluster-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AutoscalerDescribe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "AutoscalerModify"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"             = "true"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

# ─── Kyverno — ECR pull for cosign image signature verification ───────────────

resource "aws_iam_role" "kyverno" {
  name = "${var.cluster_name}-kyverno-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust, {
    Statement = [
      merge(local.irsa_trust.Statement[0], {
        Condition = {
          StringLike = {
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:kyverno:kyverno-*"
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-kyverno-role" })
}

resource "aws_iam_role_policy" "kyverno_ecr" {
  #checkov:skip=CKV_AWS_355: ecr:GetAuthorizationToken requires wildcard — no resource-level scoping available for ECR auth token endpoint
  name = "kyverno-ecr-pull"
  role = aws_iam_role.kyverno.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthAndPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:ListImages",
        ]
        Resource = "*"
      },
    ]
  })
}
