# Topology: Go Data Pipeline

**Version**: 1.0.0
**Stack**: Go 1.22+ + cobra CLI + structured logging (slog) + standard library + (optional) Kafka/SQS/NATS consumer
**Use this when**: building a batch ETL job, a streaming event processor, or a CLI tool that reads from one or more sources and writes to a sink — **no HTTP server surface**.

## What this topology bundles

Pick this topology in `/handover` and the skill instantiates:

| Layer | Files instantiated | Where they land |
|-------|--------------------|-----------------|
| Architecture handbooks | `clean-architecture-layers.md` (always-load), `pipeline-stages.md` (always-load) | `handbooks/architecture/` |
| Language handbooks | `error-wrapping.md`, `context-propagation.md`, `goroutine-lifecycle.md` | `handbooks/language/go/` |
| Domain handbooks | `pipeline-checkpointing/at-least-once.md`, `pipeline-batching/batch-size-tuning.md`, `pipeline-observability/structured-logs.md` | `handbooks/domain/<area>/` (each has `paths:` frontmatter) |
| CI pipeline | `go-pipeline-ci.yml` (golangci-lint + go vet + go test -race -cover + go build all platforms) | `.github/workflows/` |
| AgDR template | `agdr-go-data-pipeline.md` (queue choice, checkpointing strategy, observability prompts) | `docs/agdr/agdr-go-data-pipeline.draft.md` |

## Why pick this topology

A data pipeline is categorically different from a web service: no request/response, no per-request auth, no client-side concerns. The failure modes are different too — at-least-once delivery, idempotency, checkpointing, backpressure. Pretending it's a web service (e.g. running it as a long-poll HTTP handler) loses the shape entirely.

Go's standard library + `context.Context` + goroutine model is a natural fit for pipelines: streaming, cancellable, observable. The topology's handbooks codify the Go-idiomatic way to structure a pipeline.

If your project has both a pipeline AND an HTTP API, run `/handover` twice (once per shape) into separate Go modules, OR pick a topology for whichever is the dominant surface and add the other manually.

## Ambient affordances this topology assumes

| Affordance | How it's provided | Why it matters to Rex |
|------------|-------------------|------------------------|
| Strong typing | Go's enforced types + nil-error returns | error-wrapping handbook is enforceable |
| Module boundaries | `cmd/<name>/`, `internal/pipeline/`, `internal/sources/`, `internal/sinks/`, `internal/domain/` | clean-architecture handbook applies |
| Framework opinionation | cobra for CLI; standard library elsewhere — explicit, no magic | pipeline-stages handbook stays simple |
| Test coverage signal | `go test -cover` in CI; threshold via the workflow | Coverage gates apply |
| Lint baseline | `golangci-lint` with the recommended preset | Replaces piecemeal linter configs |

## Files in this bundle

```
go-data-pipeline/
├── VERSION
├── README.md
├── handbooks/
│   ├── architecture/
│   │   ├── clean-architecture-layers.md
│   │   └── pipeline-stages.md
│   ├── language/
│   │   └── go/
│   │       ├── error-wrapping.md
│   │       ├── context-propagation.md
│   │       └── goroutine-lifecycle.md
│   └── domain/
│       ├── pipeline-checkpointing/
│       │   └── at-least-once.md                             ← paths: internal/pipeline/**, internal/checkpoint/**
│       ├── pipeline-batching/
│       │   └── batch-size-tuning.md                         ← paths: internal/pipeline/**, internal/sources/**
│       └── pipeline-observability/
│           └── structured-logs.md                           ← paths: internal/**, cmd/**
├── golden-paths/
│   └── go-pipeline-ci.yml
└── templates/
    └── agdr-go-data-pipeline.md
```
