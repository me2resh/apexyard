# Plan — Parallel but gated: Lane A (trust) + Lane B (AI scout index)

**Decision:** Option **A** (CEO, 2026-05-28)  
**Owner:** Omar (Product) + Engineering  
**Status:** Active

## Gates

| Lane | Work now | Code merge | Marketing |
|------|----------|------------|-----------|
| **A — AI evidence + human scout** | 076, 080, 081, 082 gold; #43/#44; prod clip smoke | Yes (calibration ops + analyzers) | “Verified drill” only **after** per-drill sign-off |
| **B — Pitch IQ Scout Index** | ADR + PRD draft (this repo / koraid `docs/`) | **No** until **076 sprint** signed off in `sprint-calibration-v1-results.md` | No “AI scout” until ADR + PM copy approval |

```bash
npm run calibrate:field-status   # exit 0 = all drills ≥ 40 trials → Lane B code unlock
```

---

## Lane A — What to verify (drills + videos)

**Target:** **N ≥ 40 valid trials per drill** (exclude `EXAMPLE_*` rows).  
**Runbook:** [FIELD-STUDY-RUNBOOK](https://github.com/Dr-kersho/koraid/blob/main/docs/research/calibration/FIELD-STUDY-RUNBOOK.md)

### Silver (scout-ready core)

| Ticket | Drill | Video you need | Ground truth | KoraID capture | Filming (aligned to literature + our checklists) |
|--------|-------|----------------|--------------|----------------|-----------------------------------------------------|
| **076** | **20 m sprint** | Full run, side-on, player enters frame before start, exits after 20 m | Photocells **or** frame-reviewed video at 60+ fps ([Photo Finish® vs photocells](https://doi.org/10.3390/s24206719); [MediaPipe 5/10/20 m](https://doi.org/10.21203/rs.3.rs-7513017)) | App upload → `cvAiTimeSeconds`, `cvMethod`, `cvConfidence` | Tripod, **~90° to lane**, hip height, **60 fps** if device allows; mark 0/20 m; contrast kit; lock exposure; Alexandria outdoor + one indoor session |
| **080** | **CMJ / jump** | Side-on jump, feet visible, full flight | Force plate, jump mat, or manual flight-time → height | `cvAiHeightCm`, method, confidence | Side camera, player ~60% frame height; stable lighting ([MMPose CMJ refs](https://doi.org/10.3390/s24206624)) |
| **081** | **Agility shuttle** | Full 4×5 m shuttle (~12–18 s) | Stopwatch + cone protocol (8–25 s valid band) | `mediapipe_shuttle_v1` timing | Environment camera per UI; COD apps use ~1 m high, 4 m from line, perpendicular ([505 app validity](https://pmc.ncbi.nlm.nih.gov/articles/PMC11730434/)) |

### Gold (065–067 analyzers + 082 calibration)

| Ticket | Drill | Video you need | Ground truth | Notes |
|--------|-------|----------------|--------------|--------|
| **082-juggling** | Juggling | Continuous keep-ups, ball visible | Coach count of touches | Analyzer shipped; needs **40** calibrated trials |
| **082-passing** | Passing | Targets/cones, all reps in frame | Coach count completed passes | Same |
| **082-shooting** | Shooting | Shot sequence to goal | Coach count on-target / attempts per protocol | Same |
| **082-dribbling** | Dribbling | Timed slalom | Stopwatch | Metric = seconds; tolerance in `gold_metric.py` |
| **082-position** | Position | Position-specific gold drill | Coach score per rubric | Lowest literature support — prioritize honest copy |

**Scout-ready today:** only drills with **completed** CV + **calibrated** `cvMethod` (not `gold-mvp-passthrough`) count toward checklist.

### Platinum / scout clips (smoke, not N≥40 in 076)

| Asset | Purpose | Count |
|-------|---------|--------|
| Match / program **clips** | `/scout/clips`, clip CV pass | 3+ per pilot player for scout-ready **clips** row |
| Drill videos above | Pitch IQ verify + calibration CSV | 40+ per drill type |

---

## Online supplement (finish calibration desk work — **not** replace field N≥40)

Use public videos to stress-test analyzers and priors **before/while** field days run. Config: `koraid/docs/research/calibration/online-probe-queries.json`.

```bash
cd koraid
npm run calibrate:online-probe              # discover + download (yt-dlp) + analyze
npm run calibrate:online-probe -- --analyze-only   # reuse cache

# Prod worker (needs secret on operator machine)
CV_WORKER_URL=https://koraid-cv-worker.onrender.com \
CV_WORKER_SECRET='…' \
npm run calibrate:online-probe -- --remote --analyze-only
```

| Drill | Example search intents (in repo JSON) | Online role |
|-------|--------------------------------------|-------------|
| Sprint | “20 meter sprint test football timer” | Bias check vs title/description times |
| Agility | “5-10-5 shuttle run soccer test” | Shuttle analyzer regression |
| Jump | “vertical jump test cm countermovement” | Height sanity (weak labels) |
| Gold ×5 | juggling / passing / shooting / dribbling / position | Analyzer smoke only — **sparse science** |

Label online runs **`ONLINE-PILOT`** in notes — do **not** mix into 076 sign-off CSV as field truth.

**Literature already in repo:** [cv-accuracy-literature.md](https://github.com/Dr-kersho/koraid/blob/main/docs/research/cv-accuracy-literature.md) (Photo Finish®, MediaPipe sprint, MMPose jump, COD apps).

---

## Field ops — minimum schedule

| Week | Ops | Engineering |
|------|-----|-------------|
| 1 | Recruit **≥15** players × **3** sprint trials → 45+ rows; start CSV | Render smoke; export AI columns |
| 2 | Sprint to **40+**; start jump + agility | `calibrate:sprint-report`; draft results MD |
| 3–4 | Gold drills (8 trials/player/drill type if needed) | Per-drill reports; update literature copy table |
| Parallel | — | **Lane B:** ADR-0005 draft + PRD (no code) |

**Sign-off per drill:** PM approves Arabic/English claims in `cv-accuracy-literature.md` § Copy-approved.

---

## Lane B — Product deliverables (while 076 runs)

See [ADR-DRAFT-0005-ai-scout-index.md](./ADR-DRAFT-0005-ai-scout-index.md).

**Unlock Lane B implementation when:**

1. `npm run calibrate:field-status` → exit **0** for **sprint** (minimum); full exit 0 preferred before marketing “verified gold.”
2. ADR-0005 accepted.
3. PRD acceptance criteria + scout UX mocks approved.

---

## Success metrics

| Lane | Metric |
|------|--------|
| A | Sprint MAE (s) + 95% CI filed; failure rate conf &lt; 0.6; scout-ready uses calibrated methods only |
| B (post-gate) | Scout time-to-shortlist; override rate of AI index; zero conflation with human scout rating in analytics |

---

*Next engineering ticket:* field study execution (ops-led). Next product:* finalize ADR-0005 + PRD, roadmap row for Pitch IQ Scout Index.*
