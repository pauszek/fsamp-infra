# ADR-002: Event-Driven Architecture with SNS/SQS

## Status

Accepted

## Context

The FSAMP platform needs to process file uploads asynchronously. Processing can take seconds to minutes
depending on file size and analysis complexity. The system must handle:

- Decoupling between file upload (Gateway) and processing (Processor)
- Reliable message delivery with retry semantics
- Dead letter handling for failed messages
- Multiple consumers for different processing stages
- Audit trail of all events

### Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **SNS + SQS** | Native AWS, managed, scalable, free tier | AWS lock-in |
| **Amazon MSK (Kafka)** | Powerful, replay capability | ~$200+/month minimum |
| **EventBridge** | Serverless, rule-based routing | Less control over queuing |
| **Direct Lambda invocation** | Simple | No buffering, harder retry |

## Decision

We will use **SNS + SQS** for event-driven communication.

### Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                    Event Flow                                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────┐      ┌──────────────────┐      ┌──────────────────┐  │
│  │ Gateway  │─────▶│ SNS: file-events │─────▶│ SQS: processing  │  │
│  │ (upload) │      └──────────────────┘      └────────┬─────────┘  │
│  └──────────┘                                          │            │
│                                                        ▼            │
│  ┌──────────────────┐      ┌──────────────────┐ ┌────────────────┐ │
│  │ SNS: proc-events │◀─────│ Lambda/ECS      │ │ SQS: DLQ       │ │
│  │ (completion)     │      │ Processor        │ │ (failed msgs)  │ │
│  └────────┬─────────┘      └──────────────────┘ └───────┬────────┘ │
│           │                                              │          │
│           ▼                                              ▼          │
│  ┌──────────────────┐                          ┌──────────────────┐│
│  │ SQS: results     │                          │ SNS: dlq-alerts  ││
│  │ (notifications)  │                          │ (ops alerting)   ││
│  └──────────────────┘                          └──────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Fan-out pattern**: SNS topics allow multiple subscribers (future extensibility)
2. **Point-to-point**: SQS queues ensure exactly-once processing per consumer
3. **DLQ pattern**: Failed messages after 3 retries go to dead letter queue
4. **Visibility timeout**: 5 minutes for processing, prevents duplicate processing
5. **KMS encryption**: All messages encrypted at rest

### Message Flow

1. Gateway uploads file to S3
2. Gateway publishes `FileUploaded` event to SNS `file-events`
3. SNS delivers to SQS `file-processing` queue
4. Lambda/ECS polls queue, processes file
5. On success: publish `FileProcessed` to SNS `processing-events`
6. On failure (after retries): message goes to DLQ, alert sent

## Consequences

### Positive

- **Decoupling**: Gateway doesn't wait for processing
- **Scalability**: Lambda auto-scales with queue depth
- **Reliability**: Messages persisted until processed
- **Observability**: CloudWatch metrics for queue depth, DLQ
- **Cost**: Free tier covers typical usage

### Negative

- **Eventual consistency**: Processing is async
- **Complexity**: More components to manage
- **Debugging**: Distributed tracing needed (X-Ray)

### Mitigations

- Use correlation IDs for tracing across services
- CloudWatch alarms on DLQ depth
- Dashboard showing message flow metrics

## References

- [AWS SNS/SQS Fan-out Pattern](https://docs.aws.amazon.com/sns/latest/dg/sns-sqs-as-subscriber.html)
- [DLQ Best Practices](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html)
