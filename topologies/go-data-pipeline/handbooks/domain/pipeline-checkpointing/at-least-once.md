---
paths:
  - "internal/pipeline/**"
  - "internal/checkpoint/**"
  - "internal/sources/**"
  - "internal/sinks/**"
---

ENFORCEMENT: blocking

# Handbook: At-least-once delivery via checkpointing

**Scope:** PRs touching the pipeline runner, checkpoint state, sources, or sinks.
**Enforcement:** **blocking** — data-loss safety.

## The rule

This pipeline guarantees **at-least-once delivery**. Every record is written to the sink at least once; the sink is responsible for idempotent writes. The checkpointing protocol:

1. **Source produces a record AND a position** (Kafka offset, S3 ETag + line number, DB primary key, etc.)
2. **Pipeline processes the record** (transformers, then sink.Write)
3. **Sink confirms write success** before returning from `Write`
4. **Pipeline commits the source's position** to the checkpoint store

On restart, the source rewinds to the last committed position. Any records processed but not yet checkpointed are re-processed — hence the **idempotent sink** requirement.

| Source supplies | Pipeline guarantees | Sink must be |
|---|---|---|
| `(Record, Position)` per `Next` call | `Sink.Write` completes successfully before checkpointing the position | Idempotent (write twice = same end state as write once) |

Anti-patterns that violate at-least-once:

| Anti-pattern | Failure mode |
|---|---|
| Checkpoint before sink.Write succeeds | Record lost on sink failure |
| Sink doesn't dedupe on retry | Duplicates land in the downstream system |
| Source provides no position | Restart re-processes everything from the start (or nothing — both broken) |
| Checkpoint store has no read-after-write consistency (e.g. eventually-consistent S3 list) | Wrong position on restart |
| `defer commit()` instead of explicit commit after sink success | Commits even on sink failure if the function returns early |

## Why

At-least-once is the only reliability guarantee that's actually achievable in a distributed pipeline. Exactly-once requires distributed-transaction support across source + sink (rare), or sink-side idempotency keys (achievable). At-most-once means losing data on any failure — almost always wrong for a data pipeline.

The blocking enforcement reflects the cost: a pipeline that silently drops records corrupts downstream analytics, breaks billing, hides bugs. A pipeline that double-writes is annoying but recoverable.

## What Rex flags (BLOCKING)

Surface a **request-changes** finding when:

1. A new source doesn't include a `Position()` method on the record OR doesn't pair `(record, position)` in its `Next` return.
2. The pipeline runner calls `checkpoint.Commit(pos)` BEFORE `sink.Write(record)` returns successfully.
3. A new sink doesn't document its idempotency strategy in a comment at the top of the file (upsert key? dedup key? overwrite-by-key?).
4. A sink uses `INSERT` to a relational DB without `ON CONFLICT DO UPDATE` (or equivalent) for the natural key — duplicates on retry will violate constraints.
5. A checkpoint store is added that's eventually-consistent (S3 list, DynamoDB without strong consistency flag, Cassandra default consistency).
6. A `defer checkpoint.Commit(pos)` appears anywhere — should be an explicit commit after sink success, not a deferred one.

## Sample finding

> **At-least-once delivery (BLOCKING)** — `internal/sources/file/source.go:24` returns `(Record, true, nil)` but no position. On restart the source starts from byte 0 — re-processes the whole file. Add a `Position` field to the source's state (line number / byte offset) and return it as part of the source's `Next` return; pair with the pipeline's checkpoint commit.
>
> **At-least-once delivery (BLOCKING)** — `internal/pipeline/runner.go:32` calls `checkpoint.Commit(pos)` before `sink.Write(record)`. If `sink.Write` fails, the position is checkpointed and the record is lost. Move the commit AFTER the successful write.
>
> **At-least-once delivery (BLOCKING)** — `internal/sinks/postgres/sink.go:18` uses `INSERT INTO events (...) VALUES (...)`. On retry, the second insert violates the primary-key constraint. Change to `INSERT ... ON CONFLICT (id) DO UPDATE SET ...` (or `DO NOTHING` if updates aren't meaningful).

## What's NOT a violation

- A pipeline explicitly designed as "best effort, drops on failure" (e.g. a metrics tap) — document with `// at-most-once: failure tolerant` at the package level. Rex won't flag.
- A sink that's naturally idempotent (writing to a key-value store with PUT semantics) — no extra dedup needed; comment to that effect is sufficient.
- Sources that don't produce positions because the upstream IS the durable store (e.g. a SQS consumer where SQS's own visibility timeout handles redelivery) — document the deferred-to-upstream model.

## The standard pattern

```go
// internal/pipeline/runner.go
func Run(ctx context.Context, src Source, ts []Transformer, sink Sink, cp Checkpoint) error {
    for {
        record, pos, hasMore, err := src.Next(ctx)
        if err != nil { return fmt.Errorf("source: %w", err) }
        if !hasMore {
            return sink.Flush(ctx)
        }

        // Transform
        for _, t := range ts {
            record, err = t.Transform(ctx, record)
            if err != nil { return fmt.Errorf("transform: %w", err) }
        }

        // Write (sink is idempotent)
        if err := sink.Write(ctx, record); err != nil {
            return fmt.Errorf("sink: %w", err)
        }

        // Commit checkpoint ONLY after successful write
        if err := cp.Commit(ctx, pos); err != nil {
            return fmt.Errorf("checkpoint: %w", err)
        }
    }
}
```

```go
// internal/sinks/postgres/sink.go

// IdempotencyModel: UPSERT by event_id (natural key).
// Re-running with the same event_id is a no-op; field updates use
// last-write-wins.
type Sink struct {
    db *sql.DB
}

func (s *Sink) Write(ctx context.Context, r domain.Record) error {
    _, err := s.db.ExecContext(ctx, `
        INSERT INTO events (event_id, payload, processed_at)
        VALUES ($1, $2, NOW())
        ON CONFLICT (event_id) DO UPDATE SET
            payload = EXCLUDED.payload,
            processed_at = EXCLUDED.processed_at
    `, r.EventID, r.Payload)
    if err != nil {
        return fmt.Errorf("postgres sink: upsert event %s: %w", r.EventID, err)
    }
    return nil
}
```

Every sink in the codebase documents its idempotency strategy at the top of the file. Every source produces (record, position). The runner sequences: process → write → commit. That's the at-least-once contract.

## When you need exactly-once

If duplicates are genuinely intolerable (financial transactions, idempotency-key-free downstream APIs), you need:

1. A sink that supports an idempotency key (Stripe Charges API, AWS DynamoDB with conditional writes)
2. The source's position OR the record itself includes a stable idempotency key
3. The sink writes (key, record, position) atomically OR the dedupe table lives in the same transaction as the data write

File an AgDR if your project needs this — exactly-once requires more design than this handbook prescribes.
