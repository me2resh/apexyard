---
paths:
  - "internal/pipeline/**"
  - "internal/sources/**"
  - "internal/sinks/**"
---

# Handbook: Batch size tuning — sinks and sources

**Scope:** PRs that change batching behaviour in sources or sinks.
**Enforcement:** advisory.

## The rule

Batching is the difference between a pipeline that processes 100 records/second and one that processes 100,000 records/second. Two rules:

| Rule | Why |
|---|---|
| Sinks batch writes when the underlying store supports bulk writes (Postgres COPY, S3 multipart, Kafka batch produce) | Per-record overhead dominates; batching amortises it |
| Sources batch reads when the upstream supports bulk fetches (Kafka FetchMaxBytes, S3 ListObjects, DB cursor with FetchSize) | Same reason in reverse |

The batch-size knobs:

| Knob | Default | Tunable via |
|---|---|---|
| Sink batch size (records) | 100 — 1000 | Config |
| Sink batch byte limit | 1 MiB | Config |
| Sink flush interval (max time to hold a partial batch) | 1 — 5 seconds | Config |
| Source fetch size | 100 — 10000 | Config |
| Source max bytes per fetch | 1 MiB | Config |
| Worker pool size (concurrent batches) | 1 — N where N = sink's max parallelism | Config |

| Anti-pattern | Why it's broken |
|---|---|
| No batching at the sink for a bulk-write-capable store (writing rows one at a time to Postgres) | 100x throughput regression |
| Batch size hard-coded as a constant — no config | Operator can't tune per-environment |
| Batch flushed only on size, not on time | Slow streams stall in a half-full batch |
| Batch flushed only on time, not on size | High-volume streams send tiny batches |
| Per-record retry within a batch — splits the batch on failure but doesn't track which records were OK | Idempotency violations on partial retry |

## Why

Per-record fixed costs are huge:

- Postgres `INSERT` ≈ 1ms + payload time. Single-row inserts: 1000 records = 1 second of pure overhead.
- Postgres `COPY` of 1000 rows ≈ 5ms + payload time. **200x faster.**
- Kafka produce per-record: ~5ms acknowledged. Batched produce of 1000: ~10ms acknowledged. **500x faster.**
- S3 `PutObject` per file: ~100ms. `MultipartUpload`: fewer requests but harder to do right.

Batching is THE single highest-leverage optimisation for a data pipeline. Sources that don't batch silently cap throughput; sinks that don't batch dominate per-record cost.

## What Rex flags

Surface a finding when:

1. A new sink writes records one at a time when the underlying store supports bulk writes — should batch.
2. A sink batches but doesn't expose batch-size + flush-interval as config.
3. A sink batches but has only a size-based flush (no time-based) or only time-based (no size-based) — needs both.
4. A new source reads one at a time when the upstream supports bulk reads (Kafka without `FetchMaxBytes`, DB cursor without `FetchSize`).
5. A retry-on-partial-batch-failure path doesn't track which records in the batch succeeded — re-writes the whole batch, breaking idempotency assumptions.
6. A batch-size or flush-interval is hard-coded as a literal in the source file.

## Sample finding

> **Batch tuning (Go pipeline)** — `internal/sinks/postgres/sink.go:18` writes `INSERT INTO events VALUES ($1, $2)` per record. Postgres supports `COPY ... FROM STDIN` for bulk inserts; this codebase's throughput is currently capped at ~1000 records/s. Refactor the sink to batch records (configurable batch size + flush interval) and use `COPY` for the bulk write.
>
> **Batch tuning (Go pipeline)** — `internal/sources/kafka/source.go:14` configures the Kafka consumer with default `FetchMaxBytes` (1 MB). At ~1 KB per record, that's only ~1000 records per fetch. Bump to `FetchMaxBytes = 10 MB` and add a config knob; for high-volume topics the larger fetch dramatically improves throughput.
>
> **Batch tuning (Go pipeline)** — `internal/sinks/s3/sink.go:32` flushes on size only (`if len(batch) >= 1000 { flush() }`). For a slow stream, a partial batch sits in memory indefinitely. Add a time-based flush: a goroutine that flushes every `flushInterval` regardless of size.

## What's NOT a violation

- A sink writing to a store that genuinely doesn't support batching (HTTP PUT to a single-record-per-request API) — flag the upstream design, not the sink.
- A pipeline that's IO-bound on the source side and never reaches sink-side bottlenecks — premature optimisation; don't batch yet.
- A sink with batch size = 1 explicitly chosen for low-latency (event-driven, must propagate within ms) — document with a comment, then it's fine.

## The standard pattern

```go
// internal/sinks/postgres/sink.go
type Sink struct {
    db            *sql.DB
    batchSize     int
    flushInterval time.Duration
    batch         []domain.Record
    mu            sync.Mutex
    flushTimer    *time.Timer
}

func New(db *sql.DB, batchSize int, flushInterval time.Duration) *Sink {
    s := &Sink{
        db:            db,
        batchSize:     batchSize,
        flushInterval: flushInterval,
    }
    s.flushTimer = time.AfterFunc(flushInterval, s.flushOnTimer)
    return s
}

func (s *Sink) Write(ctx context.Context, r domain.Record) error {
    s.mu.Lock()
    s.batch = append(s.batch, r)
    shouldFlush := len(s.batch) >= s.batchSize
    s.mu.Unlock()

    if shouldFlush {
        return s.Flush(ctx)
    }
    return nil
}

func (s *Sink) Flush(ctx context.Context) error {
    s.mu.Lock()
    batch := s.batch
    s.batch = nil
    s.flushTimer.Reset(s.flushInterval)
    s.mu.Unlock()

    if len(batch) == 0 {
        return nil
    }

    return s.bulkInsert(ctx, batch)
}

func (s *Sink) bulkInsert(ctx context.Context, batch []domain.Record) error {
    // COPY ... FROM STDIN for Postgres bulk insert
    // (impl omitted for brevity)
    // Note: COPY is atomic per-statement; if it fails, no rows are inserted.
    // Retries re-send the whole batch — idempotency lives in the upsert
    // semantics (ON CONFLICT DO UPDATE), enforced by the at-least-once handbook.
    return nil
}
```

`batchSize` and `flushInterval` are config knobs. Both flush conditions fire. Idempotency on retry is enforced by the upsert SQL in `bulkInsert`.

## Tuning the knobs

The right values are workload-dependent. Defaults to start:

| Workload | Batch size | Flush interval |
|---|---|---|
| High-volume (>1000 r/s), latency-tolerant | 1000 | 5s |
| Medium-volume (100 r/s), some latency sensitivity | 100 | 1s |
| Low-volume (< 10 r/s), latency-sensitive | 10 | 100ms |
| Event-driven (must propagate within ms) | 1 | n/a |

Measure on production traffic; tune from there.
