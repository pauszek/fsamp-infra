# Service Objectives

This document defines reliability targets for the FSAMP reference platform. The
targets are design goals for the thesis project and should be validated with real
CloudWatch data before being used as an external SLA.

## Service Level Indicators

| SLI | Measurement |
|---|---|
| Availability | Successful requests or invocations divided by valid requests or invocations |
| Latency | p50, p95, and p99 request or processing duration |
| Error rate | 5xx responses, failed Lambda invocations, failed event publishes |
| Saturation | ECS CPU/memory, Lambda concurrency, SQS backlog, DynamoDB capacity |
| Event lag | Age of oldest SQS message and outbox pending age |

Client-side 4xx responses are excluded from availability unless the system caused
the error.

## Targets

| Component | Objective | Window |
|---|---|---|
| Gateway availability | 99.5% | 30 days |
| Gateway p95 latency | < 500 ms | 30 days |
| Gateway p99 latency | < 2 s | 30 days |
| Processor availability | 99.9% | 30 days |
| Processor p95 duration | < 2 s | 30 days |
| Event pipeline delivery | 99.9% | 30 days |
| Event lag p95 | < 60 s | 30 days |
| DLQ rate | < 0.01% | 30 days |

## Error Budget

Error budget is calculated as `100% - SLO target` for the selected window.

| Remaining Budget | Operating Mode |
|---|---|
| > 50% | Normal delivery |
| 25-50% | Review risky changes and watch deploys closely |
| 10-25% | Prioritize reliability fixes over feature work |
| < 10% | Freeze non-critical changes until the cause is understood |

## Alerts

| Alarm | Signal | Severity |
|---|---|---|
| `fsamp-gateway-5xx` | Gateway 5xx rate above threshold | Critical |
| `fsamp-lambda-errors` | Processor Lambda errors above threshold | Critical |
| `fsamp-lambda-throttles` | Any sustained Lambda throttling | High |
| `fsamp-dlq-messages` | Messages visible in DLQ | High |
| `fsamp-outbox-pending` | Outbox pending count or age above threshold | Medium |
| `fsamp-critical-health` | Composite health alarm | Critical |

Burn-rate alerting should be added once enough production-like traffic exists to
calibrate thresholds.

## Useful CloudWatch Insights Queries

Availability:

```sql
fields @timestamp, status_code
| filter ispresent(status_code)
| stats
    sum(if(status_code < 500, 1, 0)) as success,
    count(*) as total
| display success / total * 100 as availability_percent
```

Endpoint errors:

```sql
fields @timestamp, path, status_code
| filter status_code >= 500
| stats count(*) as errors by path
| sort errors desc
| limit 10
```

Latency:

```sql
fields @timestamp, duration_ms
| stats
    pct(duration_ms, 50) as p50,
    pct(duration_ms, 95) as p95,
    pct(duration_ms, 99) as p99
    by bin(1h)
```

## References

- Google SRE Book: Service Level Objectives
- AWS Well-Architected Framework: Reliability Pillar
