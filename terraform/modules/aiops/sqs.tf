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

resource "aws_sqs_queue" "anomalies_dlq" {
  #checkov:skip=CKV_AWS_27: SSE with CMK not required for dev — SQS managed encryption sufficient
  name                      = "intelliops-anomalies-dlq"
  message_retention_seconds = 86400
  kms_master_key_id         = "alias/aws/sqs"

  tags = merge(local.common_tags, { Name = "intelliops-anomalies-dlq" })
}

resource "aws_sqs_queue" "anomalies" {
  #checkov:skip=CKV_AWS_27: SSE with CMK not required for dev — SQS managed encryption sufficient
  name                       = "intelliops-anomalies"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  kms_master_key_id          = "alias/aws/sqs"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.anomalies_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.common_tags, { Name = "intelliops-anomalies" })
}

resource "aws_sqs_queue_policy" "anomalies" {
  queue_url = aws_sqs_queue.anomalies.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAIOpsAgent"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ai_agent.arn
        }
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.anomalies.arn
      },
      {
        Sid    = "AllowAnomalyDetectorSend"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.anomaly_detector.arn
        }
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.anomalies.arn
      },
    ]
  })
}
