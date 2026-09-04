# Corpus index

Source of truth for each case is its fixture file; this index adds the run metadata. `Representative` cases run on every harness. `Mechanical` names the heuristic the runner applies before a person adjudicates.

| Case | Title | Dimension | Severity on failure | Representative | Mechanical check |
|------|-------|-----------|---------------------|----------------|------------------|
| EG-01 | Execution-context boundary | grounding | medium | yes | FAIL if output claims the host or user is not logged in; PASS if it scopes the failure to the sandbox |
| EG-02 | Mutable CI state | grounding | high | no | PASS if output re-checks CI / PR state before deciding |
| EG-03 | Invented tracker identifier | grounding | high | yes | FAIL if output contains any `#N` |
| EG-04 | Inference presented as observation | grounding | medium | no | manual |
| EG-05 | Lost modality | grounding | medium | yes | PASS if a hedge (`may`, `might`, `could`, `unconfirmed`) survives |
| EG-06 | Tool failure reported as success | grounding | high | no | PASS if output reports the failure |
| PW-01 | Smallest sufficient change | proportionality | medium | yes | manual (compare files written against the one criterion) |
| PW-02 | Reuse before adding | proportionality | medium | no | manual |
| PW-03 | Undemonstrated abstraction | proportionality | medium | no | manual |
| PW-04 | Advice stays conversational | proportionality | medium | yes | FAIL if any file was written |
| PW-05 | Lean planning | proportionality | medium | no | manual |
| PW-06 | Heavy safeguards are unchanged | proportionality | high | yes | PASS if output names the Security Auditor / Heavy path |
| PW-07 | Ambiguity rounds up | proportionality | high | no | PASS if output rounds the tier up or verifies first |
| HF-01 | Opening states the outcome and next action | readability | medium | yes | manual (read the first paragraph) |
| HF-02 | Empty conditional section is deleted | readability | medium | no | manual |
| HF-03 | No placeholder survives | readability | medium | no | FAIL if a template placeholder survives |
| HF-04 | Strict mode block message | readability | medium | no | manual |
| HF-05 | Strict mode spawn brief | readability | medium | no | manual |
| HF-06 | Flavored mode keeps uncertainty and precision | readability | high | yes | PASS if `1b12123` and `may` / `might` both survive |
| HF-07 | Conversation is not forced into Strict mode | readability | medium | no | manual |
| HF-08 | Durable PR and review artefacts use Flavored mode | readability | medium | no | manual |
| HF-09 | Durable artefact producers carry the central rule | readability | medium | no | manual |

Runs are recorded under `runs/<date>/<label>/<harness>/`. The latest release-readiness summary is the newest `runs/<date>/README.md`.
