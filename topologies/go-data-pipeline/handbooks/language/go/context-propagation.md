# Handbook: Context Propagation (Go pipeline variant)

**Scope:** PRs touching `**/*.go` files in a Go pipeline project.
**Enforcement:** advisory.

## The rule

Every function that does I/O, runs for non-trivial time, or spawns a goroutine accepts `context.Context` as its first parameter. Propagation rules:

| Rule | Why |
|---|---|
| `ctx` is always the first parameter | Convention; tools (`golangci-lint`, IDE refactors) expect it there |
| Never pass `context.Background()` from inside a function — receive it from caller | Caller might have set a deadline / cancellation that needs to propagate |
| `context.TODO()` only as a placeholder during refactoring, NEVER in shipped code | `TODO` is a "fix this later" marker, not a sentinel |
| Functions that spawn goroutines must accept ctx AND propagate it | Otherwise goroutines outlive their caller's cancellation |
| Check `ctx.Err()` at loop heads in long-running stages | Cancellation only fires when you check |
| Sleep via `select { case <-time.After: ... case <-ctx.Done(): ... }`, not `time.Sleep` | `time.Sleep` is uncancellable |
| Don't store ctx in struct fields (except for request-scoped types with documented lifetime) | Struct field outlives the call; cancellation semantics break |

## Why

In a pipeline, every layer needs to know "should I keep going, or has the operator pressed ctrl-C / has the deadline expired?" The answer is `ctx.Err() != nil`. Without context propagation, the pipeline runs to completion even after the operator killed it — every goroutine inherits parent timeouts ONLY if ctx is threaded through.

The reverse — `context.Background()` from inside a function — silently breaks the chain. Even if the caller cancels, this function (and everything it spawns) keeps running. Resource leaks, slow shutdowns, "I killed it but it's still processing" bugs.

## What Rex flags

Surface a finding when:

1. A function does I/O (file read, network call, DB query) without accepting `context.Context`.
2. A function that calls one of the above passes `context.Background()` instead of receiving + forwarding a ctx.
3. `context.TODO()` appears in non-test code without a `// TODO: <reason>` comment.
4. A goroutine is spawned without a ctx — `go func() { ... }()` with no cancellation signal inside.
5. A long-running loop has no `select` with `<-ctx.Done()` — can't be cancelled.
6. `time.Sleep(...)` is used in code paths that should respect cancellation.
7. `ctx` is passed as a non-first parameter (`func F(arg1 string, ctx context.Context)`) — Go convention is `ctx` first.
8. `ctx` is stored in a struct field except for documented request-scoped types (e.g. a stream subscription's lifetime ties to a request's ctx).

## Sample finding

> **Context propagation (Go)** — `internal/sources/http/source.go:24` calls `http.Get(url)` (no ctx). On pipeline shutdown, the HTTP request keeps running until the upstream completes — could be minutes for a slow endpoint. Use `req, _ := http.NewRequestWithContext(ctx, "GET", url, nil); http.DefaultClient.Do(req)` and the request cancels with the pipeline.
>
> **Context propagation (Go)** — `internal/pipeline/worker.go:18` has `for { ... }` with no cancellation check. On shutdown the loop runs to completion. Add `select { case <-ctx.Done(): return ctx.Err(); default: }` at the loop head, or restructure the loop with a `for { select { ... } }` shape.
>
> **Context propagation (Go)** — `internal/sinks/postgres/sink.go:32` has `time.Sleep(retryDelay)`. Switch to `select { case <-time.After(retryDelay): case <-ctx.Done(): return ctx.Err() }` so a shutdown doesn't have to wait the full retry delay.

## What's NOT a violation

- A pure function with no I/O (e.g. `func ValidateOrder(o Order) error`) — no ctx needed.
- `main()` calling `context.Background()` once at the top of the program to seed the tree — that's the canonical pattern.
- `ctx` stored in a struct that has documented "lives for the duration of one stream/subscription" semantics — fine if the lifetime contract is clear.
- A short loop (< 10 iterations, < 1s total) without a cancellation check — pragmatic.

## The standard shape

```go
// cmd/orders-pipeline/main.go
func main() {
    ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer cancel()

    if err := pipeline.Run(ctx, source, transformers, sink); err != nil {
        log.Fatalf("pipeline: %v", err)
    }
}

// internal/pipeline/runner.go
func Run(ctx context.Context, src Source, ts []Transformer, sink Sink) error {
    for {
        if err := ctx.Err(); err != nil {
            return fmt.Errorf("pipeline cancelled: %w", err)
        }
        record, hasMore, err := src.Next(ctx)
        if err != nil { return err }
        if !hasMore { break }
        // ... process record ...
    }
    return sink.Flush(ctx)
}

// internal/sources/kafka/source.go
func (s *Source) Next(ctx context.Context) (domain.Record, bool, error) {
    msg, err := s.reader.ReadMessage(ctx)
    // ReadMessage already respects ctx — Kafka SDK is well-behaved
    // ...
}
```

Cancellation flows top-to-bottom; every layer checks ctx; the program shuts down cleanly when the operator sends SIGINT.

## The `context.WithTimeout` pattern

For per-operation timeouts (e.g. each Kafka read should take at most 5s):

```go
func (s *Source) Next(ctx context.Context) (domain.Record, bool, error) {
    readCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    msg, err := s.reader.ReadMessage(readCtx)
    if err != nil {
        return domain.Record{}, false, fmt.Errorf("kafka: read: %w", err)
    }
    // ...
}
```

`readCtx` is cancelled either by the parent (`ctx`) OR by the timeout — whichever fires first. The `cancel()` deferred call cleans up the timer resource regardless.
