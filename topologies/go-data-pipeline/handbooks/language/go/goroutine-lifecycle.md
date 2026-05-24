# Handbook: Goroutine Lifecycle (Go pipeline variant)

**Scope:** PRs touching `**/*.go` files in a Go pipeline project.
**Enforcement:** advisory.

## The rule

Every goroutine has a documented exit path. Goroutines that outlive their caller's context are a goroutine leak — they hold memory, file handles, network connections forever. Follow these rules:

| Rule | Pattern |
|---|---|
| Every `go func() { ... }()` has an explicit exit condition | `select { case <-ctx.Done(): return }` in any loop |
| `sync.WaitGroup` for "wait for these N to finish" | `wg.Add(1)` before `go`, `defer wg.Done()` in the goroutine, `wg.Wait()` to join |
| `errgroup` for "wait + propagate the first error" | `g, gctx := errgroup.WithContext(ctx); g.Go(func() error { ... }); g.Wait()` |
| Channels are closed by the SENDER, never the receiver | Receiver loops on `for v := range ch` — exits when sender closes |
| Goroutines that send to a channel check for closed receivers | `select { case ch <- v: case <-ctx.Done(): return }` — avoids panic on send to closed |
| Worker pools have an explicit cap | `for i := 0; i < N; i++ { go worker(...) }` — never unbounded `go` per iteration |

| Anti-pattern | Why it's broken |
|---|---|
| `go someFunc()` with no cancellation signal | Goroutine leak if `someFunc` runs forever |
| Unbounded `go` per loop iteration | Can spawn millions of goroutines; OOM |
| Receiver closing the channel | Panics if sender writes after close; data loss |
| `defer wg.Done()` BEFORE `wg.Add(1)` | Race: Done fires before Wait sees the Add |
| Recovering from a panic and continuing | Goroutine is in an undefined state; restart, don't recover-and-continue |

## Why

Goroutines are cheap to create, expensive to leak. A long-running pipeline that leaks a goroutine per record processed will OOM after a few million records. Worse, leaks are silent — there's no compile error, no runtime warning. The first signal is "memory is climbing and we don't know why".

Tools like `go test -race` and `goleak` (from Uber) catch some leaks. The handbook catches the rest at review time.

## What Rex flags

Surface a finding when:

1. A `go func() { ... }()` is added without an obvious exit path (no `<-ctx.Done()`, no bounded loop, no return statement).
2. Goroutines are spawned in a `for` loop without a worker-pool cap (`for r := range records { go process(r) }` — unbounded).
3. A channel is closed inside a receiving function — that's the sender's job.
4. `sync.WaitGroup.Done()` is deferred BEFORE the corresponding `Add(1)` (race).
5. A panic recovery (`recover()`) is followed by a continue, not a goroutine exit.
6. A new long-running background task (file watcher, periodic flush) is added without a documented shutdown path.

## Sample finding

> **Goroutine lifecycle (Go)** — `internal/sinks/postgres/sink.go:22` spawns a flush goroutine via `go s.flushLoop()` with no ctx and no shutdown channel. On pipeline shutdown the goroutine keeps running forever — goroutine + DB connection leak. Pass `ctx` to `flushLoop` and have it `select { case <-ctx.Done(): return }` in its loop.
>
> **Goroutine lifecycle (Go)** — `internal/pipeline/worker.go:18` spawns `go process(record)` inside the main loop with no concurrency cap. On a burst of 100k records, the program spawns 100k goroutines simultaneously. Use an `errgroup` with `SetLimit(N)` (Go 1.20+) or a worker-pool pattern with a fixed N.
>
> **Goroutine lifecycle (Go)** — `internal/pipeline/runner.go:14` has the receiver function calling `close(ch)`. Channels are closed by senders. Move the `close` into the sending function (or a defer at the top of the sender's first call).

## What's NOT a violation

- Short-lived goroutines that demonstrably terminate (`go func() { time.Sleep(1*time.Second); doThing() }()` — bounded by a sleep timer).
- Goroutines spawned by well-behaved libraries (HTTP server's `ServeHTTP` per-request goroutines) — library handles lifecycle.
- `go func() { recover(); ... }()` in a top-level error reporter — pragmatic for crash isolation in a stage; document it.
- A goroutine that runs for the program's lifetime AND is fine being leaked at shutdown (e.g. signal handler in `main`).

## The standard worker pool

```go
// internal/pipeline/parallel_runner.go
import "golang.org/x/sync/errgroup"

func ParallelRun(ctx context.Context, src Source, ts []Transformer, sink Sink, workers int) error {
    g, gctx := errgroup.WithContext(ctx)
    g.SetLimit(workers)

    records := make(chan Record, workers)

    // Producer
    g.Go(func() error {
        defer close(records)
        for {
            r, hasMore, err := src.Next(gctx)
            if err != nil { return fmt.Errorf("source: %w", err) }
            if !hasMore { return nil }
            select {
            case records <- r:
            case <-gctx.Done():
                return gctx.Err()
            }
        }
    })

    // Workers (bounded by g.SetLimit)
    for record := range records {
        record := record  // capture
        g.Go(func() error {
            for _, t := range ts {
                out, err := t.Transform(gctx, record)
                if err != nil { return fmt.Errorf("transform: %w", err) }
                for _, r := range out {
                    if err := sink.Write(gctx, r); err != nil {
                        return fmt.Errorf("sink: %w", err)
                    }
                }
            }
            return nil
        })
    }

    if err := g.Wait(); err != nil { return err }
    return sink.Flush(ctx)
}
```

Producer + bounded workers + explicit channel close + errgroup-propagated cancellation. Every goroutine has a documented exit path.

## Testing for leaks

Add `goleak.VerifyNone(t)` to your top-level test functions:

```go
func TestRun(t *testing.T) {
    defer goleak.VerifyNone(t)
    // ... test ...
}
```

If the pipeline leaks a goroutine, the test fails with a stack trace pointing at the leaking goroutine. Cheap insurance.
