output "sqs_queue_url" {
  description = "URL of the intelliops-anomalies SQS queue"
  value       = aws_sqs_queue.anomalies.id
}

output "sqs_queue_arn" {
  description = "ARN of the intelliops-anomalies SQS queue"
  value       = aws_sqs_queue.anomalies.arn
}

output "ai_agent_role_arn" {
  description = "IRSA role ARN for the AI agent — annotate the k8s ServiceAccount with this"
  value       = aws_iam_role.ai_agent.arn
}

output "anomaly_detector_role_arn" {
  description = "IRSA role ARN for the anomaly detector"
  value       = aws_iam_role.anomaly_detector.arn
}
