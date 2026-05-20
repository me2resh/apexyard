# Handbook: Clean Architecture Layering (Go pipeline variant)

**Scope:** all PRs in a Go data-pipeline project.
**Enforcement:** advisory.

## The rule

A Go pipeline codebase under ApexYard's topology is organised in four packages with a strict dependency direction:

```
internal/domain/  ←  internal/pipeline/  ←  cmd/<name>/
                          ↑       ↑
        internal/sources/         internal/sinks/
```

| Package | What lives there | CAN import | CANNOT import |
|---|---|---|---|
| `internal/domain/` | Plain structs for the records flowing through the pipeline; pure validation/transformation functions | Standard library only | `internal/pipeline/`, `internal/sources/`, `internal/sinks/`, any external SDK |
| `internal/pipeline/` | The stage interfaces (`Source`, `Transformer`, `Sink`), pipeline runner, backpressure logic | `internal/domain/`, standard library, `context` | Concrete source/sink implementations |
| `internal/sources/` | Concrete sources (Kafka consumer, S3 lister, file reader, HTTP poller) | `internal/domain/`, `internal/pipeline/` (the Source interface), external SDKs | `internal/sinks/`, `cmd/` |
| `internal/sinks/` | Concrete sinks (Postgres writer, S3 writer, Kafka producer, stdout) | `internal/domain/`, `internal/pipeline/` (the Sink interface), external SDKs | `internal/sources/`, `cmd/` |
| `cmd/<name>/` | The main entry point — wires sources + transformers + sinks via the runner | All inner packages, all SDKs | (outermost — wires the world) |

## Why

A pipeline's domain is **the records flowing through it**, not the connectors. Putting Kafka logic inside the domain welds the business to one queue technology. Putting business logic inside the Kafka consumer makes the consumer un-testable without a Kafka instance.

The interface-driven split (`Source`, `Sink` interfaces in `internal/pipeline/`; concrete implementations in `internal/sources/`, `internal/sinks/`) is what makes a pipeline testable: swap a real Kafka source for a slice of fixtures; swap a Postgres sink for an in-memory map. The pipeline runner doesn't change.

## What Rex flags

Surface a finding when:

1. A file under `internal/domain/` imports an external SDK (`github.com/segmentio/kafka-go`, `github.com/aws/aws-sdk-go-v2/...`, etc.).
2. A file under `internal/pipeline/` imports anything from `internal/sources/` or `internal/sinks/` (cross-arrow violation).
3. A file under `internal/sources/` imports from `internal/sinks/` (or vice versa).
4. A new source or sink doesn't implement the canonical interface defined in `internal/pipeline/` — instead exposes its concrete type as the public API.
5. Business validation logic lives in a source/sink file (e.g. record validation inside the Kafka consumer) instead of `internal/domain/`.
6. `cmd/<name>/main.go` contains business logic — should only wire and run.

## Sample finding

> **Clean architecture (Go pipeline)** — `internal/domain/order.go:5` imports `github.com/segmentio/kafka-go`. The domain shouldn't know about Kafka. Move the Kafka-specific record parsing into `internal/sources/kafka/orders.go` (a Source implementation) and have it construct domain `Order` values to hand off to the pipeline.
>
> **Clean architecture (Go pipeline)** — `internal/pipeline/runner.go:12` imports `github.com/yourorg/yourapp/internal/sources/kafka`. The runner should depend on the `Source` interface, not concrete sources. Move the concrete type back to `internal/sources/kafka/` and have `cmd/<name>/main.go` instantiate + pass it in.

## What's NOT a violation

- `cmd/<name>/main.go` importing every package — that's its job. The outermost wiring layer can see everything.
- A test file (`*_test.go`) cross-importing freely — test code is its own boundary.
- A source AND a sink in the same external service (e.g. Kafka source AND Kafka sink) sharing a configuration helper — refactor the shared helper into `internal/pkg/<shared>/` if it grows.

## The standard layout

```
cmd/
└── orders-pipeline/
    └── main.go              ← wires sources + transformers + sinks, calls runner.Run(ctx)

internal/
├── domain/
│   ├── order.go             ← type Order struct { ... }
│   └── validate.go          ← func ValidateOrder(o Order) error { ... }
├── pipeline/
│   ├── runner.go            ← func Run(ctx, src Source, transformers []Transformer, sink Sink) error
│   ├── source.go            ← type Source interface { Next(ctx) (Record, bool, error); Close() error }
│   ├── sink.go              ← type Sink interface { Write(ctx, Record) error; Flush(ctx) error }
│   └── transformer.go       ← type Transformer interface { Transform(ctx, Record) (Record, error) }
├── sources/
│   └── kafka/
│       └── source.go        ← implements pipeline.Source for Kafka
└── sinks/
    └── postgres/
        └── sink.go          ← implements pipeline.Sink for Postgres
```

The split is what lets the pipeline run identically against fixtures in tests and a real Kafka instance in prod.
