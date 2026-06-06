output "topic_arns" {
  description = "Map of topic purposes to ARNs"
  value = {
    file_events       = aws_sns_topic.file_events.arn
    processing_events = aws_sns_topic.processing_events.arn
    dlq_alerts        = aws_sns_topic.dlq_alerts.arn
  }
}

output "queue_urls" {
  description = "Map of queue purposes to URLs"
  value = {
    file_processing      = aws_sqs_queue.file_processing.url
    analysis_results     = aws_sqs_queue.analysis_results.url
    dlq                  = aws_sqs_queue.dlq.url
    outbox_publisher_dlq = aws_sqs_queue.outbox_publisher_dlq.url
  }
}

output "queue_arns" {
  description = "Map of queue purposes to ARNs"
  value = {
    file_processing      = aws_sqs_queue.file_processing.arn
    analysis_results     = aws_sqs_queue.analysis_results.arn
    dlq                  = aws_sqs_queue.dlq.arn
    outbox_publisher_dlq = aws_sqs_queue.outbox_publisher_dlq.arn
  }
}
