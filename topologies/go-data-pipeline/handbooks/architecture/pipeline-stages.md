# Handbook: Pipeline Stages — composable stage interfaces

**Scope:** all PRs in a Go pipeline project, especially `internal/pipeline/**` and any new source/sink/transformer.
**Enforcement:** advisory.

## The rule

Every stage in the pipeline implements ONE of three interfaces. They compose linearly: source → transformer(s) → sink.

```go
// Source produces records.
type Source interface {
    Next(ctx context.Context) (Record, bool, error)   // record, hasMore, error
    Close() error
}

// Transformer transforms records 1-to-N (filtering = N=0; mapping = N=1; fan-out = N>1).
type Transformer interface {
    Transform(ctx context.Context, r Record) ([]Record, error)
}

// Sink consumes records.
type Sink interface {
    Write(ctx context.Context, r Record) error
    Flush(ctx context.Context) error
}
```

| Rule | Why |
|---|---|
| Sources hand off records via `Next` — pull model, not push | The runner controls backpressure by deciding when to call `Next` |
| Transformers return a slice — even for 1-to-1, return `[]Record{result}` | Consistent shape; runner doesn't need to branch on transformer kind |
| Sinks accept one record at a time; batch internally if needed | Keeps the runner simple; sinks own their own batching strategy |
| Every stage accepts `context.Context` as the first param | Cancellation, deadlines, request-scoped values propagate |
| Errors are wrapped with stage context | `fmt.Errorf("kafka source: read failed: %w", err)` — the stack trace shows where the failure occurred |

## Why

The "pull model with single-record-at-a-time interfaces" is what makes the runner trivial:

```go
for {
    record, hasMore, err := src.Next(ctx)
    if err != nil { return err }
    if !hasMore { break }
    for _, t := range transformers {
        transformed, err := t.Transform(ctx, record)
        if err != nil { return err }
        // (recursion into transformed[] omitted for brevity)
    }
    if err := sink.Write(ctx, record); err != nil { return err }
}
return sink.Flush(ctx)
```

Adding parallelism, batching, or retries is then a runner-level concern (the runner spawns worker goroutines around this loop), not something baked into every stage. Stages stay simple; the runner stays customisable.

## What Rex flags

Surface a finding when:

1. A new source/sink/transformer doesn't implement the canonical interface — instead exposes a non-standard method.
2. A stage signature doesn't take `context.Context` as the first parameter.
3. A stage returns an error wrapped with `errors.New` (no context) instead of `fmt.Errorf("<stage>: <op>: %w", err)`.
4. A transformer mutates the input record in place AND returns it — caller can't safely call it concurrently. Either return a new record or document the mutation contract.
5. A source's `Next` panics on shutdown instead of returning a clean `(zero, false, nil)` or `(zero, false, context.Canceled)`.
6. A sink batches internally but doesn't expose `Flush()` for end-of-stream cleanup.

## Sample finding

> **Pipeline stages** — `internal/sources/kafka/source.go:24` returns `errors.New("read failed")`. The runner has no idea which source failed or which operation. Use `fmt.Errorf("kafka source: read failed: %w", err)` so the error chain identifies the stage.
>
> **Pipeline stages** — `internal/transformers/dedupe.go:18` defines `func (d *Dedupe) Process(r Record) Record`. The canonical interface is `Transform(ctx context.Context, r Record) ([]Record, error)`. Rename and adjust the signature so the runner can compose stages uniformly.

## What's NOT a violation

- A stage that internally spawns goroutines (e.g. a sink that batches by sending records to a channel) — internal concurrency is fine; the public interface stays single-threaded.
- A custom interface for a specific pipeline that genuinely doesn't fit (e.g. a CDC-aware source that yields (record, position) pairs) — document the divergence in the package's `doc.go` and keep the canonical interface as the default.
- Helper methods alongside the canonical interface (`func (s *S) Position() Offset`) — fine, just not the primary interface.

## The standard runner

```go
// internal/pipeline/runner.go
package pipeline

import "context"

func Run(ctx context.Context, src Source, ts []Transformer, sink Sink) error {
    defer src.Close()
    for {
        r, hasMore, err := src.Next(ctx)
        if err != nil {
            return fmt.Errorf("source: %w", err)
        }
        if !hasMore {
            return sink.Flush(ctx)
        }
        records := []Record{r}
        for _, t := range ts {
            var next []Record
            for _, in := range records {
                out, err := t.Transform(ctx, in)
                if err != nil {
                    return fmt.Errorf("transformer %T: %w", t, err)
                }
                next = append(next, out...)
            }
            records = next
        }
        for _, out := range records {
            if err := sink.Write(ctx, out); err != nil {
                return fmt.Errorf("sink: %w", err)
            }
        }
    }
}
```

Customisations (parallel workers, batching, retries) layer on top — not inside the stage interfaces.
