# Handbook: Error Wrapping (Go pipeline variant)

**Scope:** PRs touching `**/*.go` files in a Go pipeline project.
**Enforcement:** advisory.

## The rule

Every error returned from a function in this codebase is **wrapped with context** using `fmt.Errorf("%w", err)`. The wrapping convention is `<package>: <operation>: %w`.

| Pattern | Rule |
|---|---|
| Returning an error from a stdlib call | `return fmt.Errorf("read config file: %w", err)` |
| Returning an error from a domain operation | `return fmt.Errorf("validate order %s: %w", id, err)` |
| Wrapping a typed error you want callers to inspect | Define a sentinel: `var ErrNotFound = errors.New("not found")` then `return fmt.Errorf("user %s: %w", id, ErrNotFound)` |
| Checking a wrapped error | `if errors.Is(err, ErrNotFound)` — NEVER `if err.Error() == "..."` |
| Adding context to a typed error to extract later | `errors.As(err, &target)` after `fmt.Errorf("%w", typedErr)` |
| Returning the unwrapped error | NEVER — always wrap. Even a one-line passthrough gets `fmt.Errorf("step: %w", err)` |

| Anti-pattern | Why it's broken |
|---|---|
| `if err != nil { return err }` | Loses the operation context; stack trace is just leaf errors |
| `return fmt.Errorf("error: %v", err)` (using `%v`, not `%w`) | Caller can't `errors.Is(...)` the wrapped error |
| `errors.New("read failed")` for non-sentinel errors | Strips the underlying cause |
| `panic(err)` outside of `main` or recoverable init | Pipelines should fail gracefully, not panic |
| String matching on `err.Error()` | Brittle; breaks when the error message changes |

## Why

Go's error chain is the equivalent of a stack trace — but only if you wrap. An unwrapped error in a 4-deep call stack is "read failed" with zero context; a wrapped chain is "kafka source: process partition 3: parse record at offset 1247: invalid JSON" — that's actionable.

The `%w` verb (vs `%v`) is what enables `errors.Is` and `errors.As`. Without it, callers can't inspect the underlying error type — they can only string-match, which is brittle and breaks on every rephrase.

## What Rex flags

Surface a finding when:

1. A function returns an error via `return err` (bare passthrough) instead of `return fmt.Errorf("<context>: %w", err)`.
2. An error is wrapped with `%v` instead of `%w`.
3. An error is constructed with `errors.New(...)` for a one-off message that should have been a wrap.
4. A caller uses `err.Error() == "..."` or `strings.Contains(err.Error(), "...")` to inspect an error (use `errors.Is` / `errors.As`).
5. A `panic(...)` is used for a recoverable condition (network blip, deserialisation error) — pipelines should return the error to the runner.
6. A new sentinel error is added inside a function (`errors.New(...)` inside a function body) instead of at package scope (`var ErrFoo = errors.New(...)`).

## Sample finding

> **Error wrapping (Go)** — `internal/sources/kafka/source.go:18` returns `return err` from the read path. The caller (`pipeline.Run`) only sees the leaf Kafka error and can't tell which source produced it. Wrap: `return fmt.Errorf("kafka source partition %d: read at offset %d: %w", partition, offset, err)`.
>
> **Error wrapping (Go)** — `internal/sinks/postgres/sink.go:24` uses `fmt.Errorf("write failed: %v", err)`. The `%v` strips the underlying error type — callers can't `errors.Is(err, pgx.ErrTimeout)`. Change to `%w`.
>
> **Error wrapping (Go)** — `internal/pipeline/runner.go:32` checks `if err.Error() == "checkpoint expired"`. Define a sentinel `var ErrCheckpointExpired = errors.New("checkpoint expired")` in `internal/checkpoint/`, wrap with `%w` at the source, and check via `errors.Is(err, checkpoint.ErrCheckpointExpired)`.

## What's NOT a violation

- `if err != nil { return err }` inside a function that's already wrapping its caller's error (a thin re-throw at a layer where adding context would be redundant). Rare; document with a comment.
- `errors.New(...)` at package scope for sentinel errors (`var ErrNotFound = errors.New("not found")`) — that IS the canonical pattern.
- `log.Fatalf(...)` in `main.go` for unrecoverable startup errors — only at the very top of the call stack.
- `panic(...)` for programmer errors (`assert: should not happen`) — fine, just not for runtime conditions.

## The standard pattern

```go
// internal/sources/kafka/source.go
package kafka

import (
    "context"
    "fmt"

    "github.com/segmentio/kafka-go"
    "github.com/yourorg/yourapp/internal/domain"
)

func (s *Source) Next(ctx context.Context) (domain.Record, bool, error) {
    msg, err := s.reader.ReadMessage(ctx)
    if err != nil {
        // EOF is a clean signal to the runner
        if errors.Is(err, io.EOF) {
            return domain.Record{}, false, nil
        }
        return domain.Record{}, false, fmt.Errorf(
            "kafka source %q partition %d: read: %w",
            s.topic, msg.Partition, err,
        )
    }

    record, err := domain.ParseRecord(msg.Value)
    if err != nil {
        return domain.Record{}, false, fmt.Errorf(
            "kafka source %q partition %d offset %d: parse: %w",
            s.topic, msg.Partition, msg.Offset, err,
        )
    }

    return record, true, nil
}
```

Errors carry the source name, the partition, the offset, AND the underlying cause. Debugging a failure is reading the error message.

## Custom error types (when sentinels aren't enough)

For errors that carry structured data (e.g. "rate-limited, retry after N seconds"), define a struct type:

```go
type RateLimitError struct {
    RetryAfter time.Duration
    Underlying error
}

func (e *RateLimitError) Error() string {
    return fmt.Sprintf("rate limited; retry after %s: %v", e.RetryAfter, e.Underlying)
}

func (e *RateLimitError) Unwrap() error { return e.Underlying }
```

Callers extract with `errors.As`:

```go
var rateLimit *RateLimitError
if errors.As(err, &rateLimit) {
    time.Sleep(rateLimit.RetryAfter)
    continue
}
```

This is the only correct way to propagate retry/backoff context through wrapped errors.
