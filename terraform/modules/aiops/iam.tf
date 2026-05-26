locals {
  irsa_trust_base = {
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

# ─── AI Agent IRSA ────────────────────────────────────────────────────────────

resource "aws_iam_role" "ai_agent" {
  name = "${var.cluster_name}-ai-agent-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust_base, {
    Statement = [
      merge(local.irsa_trust_base.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:aiops-demo:ai-agent"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-ai-agent-role" })
}

resource "aws_iam_role_policy" "ai_agent" {
  #checkov:skip=CKV_AWS_355: bedrock:InvokeModel scoped to account — model IDs cannot be used as resource ARNs
  name = "ai-agent-policy"
  role = aws_iam_role.ai_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-sonnet-4-5*",
          "arn:aws:bedrock:${var.aws_region}:${var.aws_account_id}:inference-profile/us.anthropic.claude-sonnet-4-5*",
        ]
      },
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.anomalies.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/eks/${var.cluster_name}/*"
      },
      {
        Sid    = "SecretsRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:intelliops/${var.environment}/*"
      },
    ]
  })
}

# ─── Anomaly Detector IRSA ────────────────────────────────────────────────────

resource "aws_iam_role" "anomaly_detector" {
  name = "${var.cluster_name}-anomaly-detector-role"

  assume_role_policy = jsonencode(merge(local.irsa_trust_base, {
    Statement = [
      merge(local.irsa_trust_base.Statement[0], {
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:aiops-demo:anomaly-detector"
          }
        }
      })
    ]
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-anomaly-detector-role" })
}

resource "aws_iam_role_policy" "anomaly_detector" {
  name = "anomaly-detector-policy"
  role = aws_iam_role.anomaly_detector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SQSSend"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.anomalies.arn
      },
    ]
  })
}
