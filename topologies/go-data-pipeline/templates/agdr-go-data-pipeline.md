# {Short Title — e.g. "Choosing Kafka vs SQS for the orders pipeline source"}

> In the context of {context — Go data-pipeline project, what workload drove the decision}, facing {concern — e.g. "at-least-once delivery at 10k rps with replay support"}, I decided {decision — e.g. "Kafka with manual offset commits"} to achieve {goal — e.g. "deterministic replay from arbitrary offsets, durable retention for 7 days"}, accepting {tradeoff — e.g. "operational overhead of running Kafka, vs SQS's managed simplicity"}.

## Context

{Decision-relevant context only. What's the pipeline's throughput target? Latency budget? Source / sink technologies? Replay requirements? Multi-tenancy?}

## Options Considered

> ApexYard's Go-data-pipeline topology v1.0.0 ships this template with stack-specific option prompts. Fill in the rows that apply; delete the rest.

### A) Queue / source technology

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Kafka** | High throughput; deterministic replay; partition-level ordering; broad ecosystem | Operational complexity; consumer-group rebalances; offset-management subtlety | |
| **AWS SQS** | Managed; trivial setup; per-message visibility timeout = built-in retry | No replay; FIFO queues are limited; per-message cost at scale | |
| **NATS / NATS JetStream** | Light operationally; subjects + streams; good Go SDK | Smaller ecosystem; less broad adoption | |
| **AWS Kinesis** | Managed Kafka-alike; replay window | Throughput limits per shard; consumer-library quirks | |
| **Redpanda** | Kafka API + simpler ops | Newer; smaller community | |
| **PostgreSQL LISTEN/NOTIFY** | Already-deployed Postgres; no extra infra | Not durable; ephemeral; max payload size limits | |

### B) Checkpoint storage

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **In-source (Kafka offsets via consumer group)** | Co-located with the source; one less thing to operate | Coupled to Kafka; consumer-group semantics get fiddly | |
| **Postgres (separate `checkpoints` table)** | Already-deployed; strong consistency | Adds a DB write per checkpoint; latency | |
| **DynamoDB** | Managed; fast key-value writes | Vendor lock-in; eventual-consistency footguns | |
| **Local SQLite** | Trivial; embedded | Doesn't survive container restarts; single-instance only | |

### C) Sink — destination

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Postgres bulk INSERT with `COPY`** | Fast; strong consistency; ACID | Schema rigidity; vertical-scale ceiling | |
| **S3 (Parquet / JSON-lines)** | Cheap storage; analytics-friendly; horizontal scale | Eventually consistent on list; latency for downstream | |
| **ClickHouse / Snowflake / BigQuery** | Built for analytical workloads | Latency tier; cost | |
| **Kafka (next stage in a multi-stage pipeline)** | Backpressure built in; downstream decoupling | Doubles the queue infra |  |
| **HTTP endpoint (downstream service)** | Simple; no infra | No batching; throughput cap at HTTP RPS | |

### D) Concurrency model

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Single goroutine per pipeline** | Simplest; ordering preserved | Throughput capped at single-thread speed | |
| **Bounded worker pool via `errgroup.SetLimit`** | Concurrent processing; explicit cap | Out-of-order processing; sink must be idempotent (see at-least-once handbook) | |
| **Per-partition worker (Kafka)** | Per-partition ordering + parallelism | Hot-partition imbalance | |
| **Channel pipeline (fan-out, fan-in)** | Composable | Channel-management complexity; deadlock-prone | |

### E) Deployment

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Kubernetes Deployment** | Standard ops; rolling restart; HPA | Operational overhead | |
| **Single binary on a VM (systemd)** | Simplest for low-volume | No HA; manual scaling | |
| **Lambda (with EventBridge / SQS trigger)** | Pay-per-record; no instance management | Cold starts; 15-min execution cap | |
| **ECS / Cloud Run** | Container + auto-scale | Less flexibility than k8s |  |

## Decision

Chosen: **{the option}**, because {2-3 sentences naming the load-bearing reason. Reference at-least-once / batching / observability handbooks if applicable}.

## Consequences

- {Throughput / latency target}
- {Operational story — who runs the queue, on-call, monitoring}
- {Sink contract — idempotency strategy}
- {Cost envelope}

## Artifacts

- {Commit / PR links}
- {Updated `go.mod` dependencies}
- {Sink schema files (if SQL) or docs (if S3 layout)}
- {Affected handbooks}

## What this decision does NOT cover

- {Multi-region replication — separate AgDR}
- {Schema evolution — separate AgDR}
- {Authentication to the queue / sink — separate AgDR if non-trivial}
