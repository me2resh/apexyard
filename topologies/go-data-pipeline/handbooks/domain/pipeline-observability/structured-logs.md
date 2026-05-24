---
paths:
  - "internal/**"
  - "cmd/**"
---

# Handbook: Structured logging via slog

**Scope:** PRs that add or modify logging in a Go pipeline project.
**Enforcement:** advisory.

## The rule

Logging uses Go's standard library `log/slog` (Go 1.21+) with structured key-value fields. Every log line follows the same shape:

```go
slog.Info("event description",
    "key1", value1,
    "key2", value2,
    slog.Group("nested", "subkey", subvalue),
)
```

| Required fields per log line | Why |
|---|---|
| A short, fixed event description (`"record processed"`, `"sink flushed"`) | Easy to grep and aggregate |
| Stage / component name (`"stage", "kafka-source"`) | Filter by stage in observability tool |
| Record / batch identifier when applicable (`"record_id", id` OR `"batch_size", n`) | Trace a specific failure back to the data |
| Error field for errors (`"err", err.Error()`) | Don't embed errors in the message string |
| Latency for timed operations (`"latency_ms", elapsed.Milliseconds()`) | Performance dashboards work without parsing log text |

Log levels:

| Level | When |
|---|---|
| `Debug` | Per-record processing detail; off in production |
| `Info` | Pipeline lifecycle events (start, stop, flush, checkpoint) — sub-second granularity |
| `Warn` | Recoverable issues (retry, partial failure, backpressure) |
| `Error` | Unrecoverable per-record failures, sink writes that failed after all retries |
| `Fatal` (not in slog — use log.Fatalf in main only) | Pipeline-killing failures at startup |

## Why

Unstructured logs (`fmt.Printf("processed record %s", id)`) are unusable at scale. You can't query `WHERE level = "error" AND stage = "postgres-sink"`. You can't aggregate latency per stage. You can't trace a specific record through the pipeline.

Structured logging via `slog` is free (stdlib, no dep), fast (no allocation in the hot path with the right handler), and the universal language of observability tools. Every other Go logging library has been outclassed by `slog` since Go 1.21.

## What Rex flags

Surface a finding when:

1. A new log line uses `fmt.Println`, `log.Printf`, or any package-level non-slog logger.
2. A `slog` call has the error embedded in the message string (`slog.Error(fmt.Sprintf("failed: %v", err))`) instead of as a field (`slog.Error("write failed", "err", err.Error())`).
3. A `slog` call doesn't include a stage / component identifier — making the log line ambiguous about where it came from.
4. A log line in a hot path (per-record) uses `Info` level — should be `Debug` to avoid flooding production logs.
5. A log line includes raw PII / secrets — credit card numbers, JWT tokens, password fields.
6. A timed operation (DB query, network call) doesn't log latency — performance regressions go undetected.
7. `panic(err)` is used as a logging mechanism — should be `slog.Error` followed by an explicit return or process exit.

## Sample finding

> **Structured logs (Go)** — `internal/sinks/postgres/sink.go:24` calls `log.Printf("flush failed: %v", err)`. Unstructured; no stage identifier; the error is in the message. Replace with `slog.Error("postgres sink flush failed", "stage", "postgres-sink", "batch_size", len(batch), "err", err.Error())`.
>
> **Structured logs (Go)** — `internal/pipeline/runner.go:32` logs every successful record write at `Info` level. In production this floods logs at the record throughput. Demote to `Debug` (or remove entirely; metrics are better for per-record cardinality).
>
> **Structured logs (Go)** — `internal/sources/kafka/source.go:18` logs `slog.Info("authenticated", "token", token)`. The token is a secret. Redact: `slog.Info("authenticated", "token_prefix", token[:8])` or omit entirely.

## What's NOT a violation

- `fmt.Errorf("...: %w", err)` for error wrapping — that's not logging; that's the error-wrapping handbook.
- A `slog.Debug` call in a hot path — debug is gated by handler level; in production it's a no-op.
- Test code using `t.Logf(...)` — test logging is its own thing.
- `log.Fatal` / `log.Fatalf` in `main.go` for startup errors — slog doesn't have a Fatal level; stdlib `log.Fatalf` is fine for the one place that exits the process.

## The standard pattern

```go
// internal/sinks/postgres/sink.go
import "log/slog"

func (s *Sink) Flush(ctx context.Context) error {
    start := time.Now()
    s.mu.Lock()
    batch := s.batch
    s.batch = nil
    s.mu.Unlock()

    if len(batch) == 0 {
        return nil
    }

    logger := slog.With("stage", "postgres-sink", "batch_size", len(batch))
    logger.Debug("flush started")

    err := s.bulkInsert(ctx, batch)
    elapsed := time.Since(start)

    if err != nil {
        logger.Error("flush failed",
            "latency_ms", elapsed.Milliseconds(),
            "err", err.Error(),
        )
        return fmt.Errorf("postgres sink: flush %d records: %w", len(batch), err)
    }

    logger.Info("flush succeeded", "latency_ms", elapsed.Milliseconds())
    return nil
}
```

`slog.With("stage", "postgres-sink", "batch_size", len(batch))` pre-binds the stage and batch context; subsequent log calls in this scope don't need to re-specify. The error is a field, not embedded in the message.

## Configuring the handler

`main.go` configures slog once:

```go
// cmd/orders-pipeline/main.go
func main() {
    level := slog.LevelInfo
    if os.Getenv("LOG_LEVEL") == "debug" {
        level = slog.LevelDebug
    }

    handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: level,
    })
    slog.SetDefault(slog.New(handler))

    // ... rest of main
}
```

JSON output for production (parsed by observability tools); add a `slog.NewTextHandler` for human-readable local dev if you want.

## Tracing across stages

For a multi-stage pipeline, propagate a trace ID via the `context.Context`:

```go
// At record ingestion (source)
ctx = context.WithValue(ctx, traceIDKey{}, uuid.New().String())

// At every log call
slog.InfoContext(ctx, "record processed", ...)

// A custom slog handler reads the traceID from ctx and adds it to every log line.
```

This lets observability tools group all logs for one record into a single trace — invaluable when debugging "what happened to record X".
