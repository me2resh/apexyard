# SPIKE-001 Product Owner Runbook — Avatar Vendor Selection

**Spike:** SPIKE-001 → [Dr-kersho/nourish#1](https://github.com/Dr-kersho/nourish/issues/1)  
**AgDR:** [AgDR-0064](../../docs/agdr/AgDR-0064-nourish-avatar-vendor-spike.md)  
**Owner:** Omar (Head of Product)  
**Timebox:** 14 calendar days from branch open  
**This doc governs:** panel recruitment, consent, scoring, and close ceremony

---

## 1. Definition of Done

All five conditions must be true before SPIKE-001 is closed via `/spike-close`.

| # | Condition | Evidence required |
|---|-----------|-------------------|
| 1 | **AgDR-0064 status → Accepted** | File updated: `Status: Accepted`; vendor table filled (initial + aging vendors named, model/API versions pinned) |
| 2 | **Winners named** | `scorecard.csv` present at `scripts/avatar-spike/scorecard.csv` in `Dr-kersho/nourish`; highest (G1+G2+G6) = initial vendor; highest G4 = aging vendor; split-vendor rationale noted if different |
| 3 | **Panel sign-off** | All 10 couples have submitted G1 + G2 ratings; G3 manual review sign-off logged by PM (see § 4) |
| 4 | **DPA notes complete** | Each vendor's data-processing posture documented in `docs/vendor-dpa-notes.md` in the nourish repo (see § 4 below); any vendor that prohibits EU processing or retains training data without opt-out is explicitly excluded |
| 5 | **Kill criteria resolved** | Every kill criterion checked — either not triggered or disposition decision taken (see § 5) |

### DPA notes minimum content (per vendor)

For each of the three spike vendors (fal.ai Flux Pro, Replicate SD3+IP-Adapter, DALL-E 3):

- Does the vendor process data in the EU / EEA by default?
- Does the DPA permit deletion of uploaded images within 24 h?
- Does the vendor retain images for model training without an explicit opt-out?
- Is a Standard Contractual Clause (SCC) or UK IDTA addendum available?
- PDPL (UAE) compatibility — does the vendor's DPA extend to UAE data subjects?

If any answer blocks EU production use, exclude the vendor and note it in AgDR-0064 Consequences.

---

## 2. Parent Panel Recruitment Plan

### Target profile

10 couples (20 people) who:

- Are first-time or second-time parents **or** currently expecting (bumper-mode testers)
- Have a child aged 0–18 months **or** pregnancy ≥20 weeks
- Are located in the UK or UAE (matching launch geography)
- Represent the tone/hair diversity buckets in § 3 (not every panellist must fill a bucket; bucket diversity is satisfied by the photo pairs)
- Speak English (Arabic bilingual welcome; translated instructions available)

### Diversity targets for the panel itself

Aim for the panel to include:

- ≥4 couples where at least one parent has dark or medium-dark skin tone
- ≥3 couples where at least one parent has curly or coily hair
- ≥2 couples currently in bumper (expecting) mode
- ≥1 UAE-resident couple

### Recruitment channels (prioritised)

| Channel | Target | Owner | Notes |
|---------|--------|-------|-------|
| Founder / PM personal network | 3–4 couples | Omar | Fastest; pre-trust; control diversity |
| Closed WhatsApp parenting groups (UK) | 2–3 couples | PM | Post intro note; DM interested parties |
| NCT / antenatal class alumni (UK) | 1–2 couples | PM | Founding PM's own network preferred |
| UAE parent Slack / Telegram communities | 1–2 couples | Omar | Translate intro if needed |
| Snowball referral (ask early recruits) | 1–2 couples | Any | "Know a family with a newborn?" |

### Recruitment timeline

| Day | Milestone |
|-----|-----------|
| Spike day 1–2 | PM sends personalised DMs to personal network (3–4 couples) |
| Day 2–3 | Post to broader community channels; snowball ask starts |
| Day 4 | Confirm 6 couples minimum; if <6, escalate to Omar for direct outreach |
| Day 5 | Close recruitment at 10 confirmed; waitlist 2 for dropout cover |
| Day 6 | Send consent pack + onboarding email to all 10 couples |
| Day 7–8 | Collect photos + consent forms; chase non-responders once |
| Day 9–12 | Panel rating session (async, 30 min estimated) |
| Day 13 | Chase any outstanding ratings; close scoring |
| Day 14 | Spike close ceremony |

### Compensation

No monetary compensation is required for a 30-minute async task with a personal connection framing. Offer:

- **Early access:** "You'll be among the first families to use Nourish when it launches."
- **Personalised avatar:** After the spike, if the vendor passes, we will generate one free avatar set as a thank-you (inform this in the consent form).
- **Acknowledgement:** First-cohort thank-you credit in app launch notes (optional, name or handle).

Do **not** promise a specific app launch date or specific product feature availability.

### Panel dropout protocol

- If a couple drops out before submitting photos: replace from waitlist.
- If a couple drops out after photos but before rating: their photo pair is removed from panel scoring (pair still usable for automated G4/G5/G6 scoring); note the exclusion in the scorecard.
- If >2 couples drop out: PM flags to Omar; consider extending rating window by 48 h rather than recruiting new panellists mid-run.

---

## 3. Photo-Pair Consent Checklist (20 pairs)

### Consent form requirements (per couple)

Each couple must sign before photos are uploaded. The consent form must state:

- [ ] Photos are used solely for this spike evaluation (not stored in production)
- [ ] Source photos are deleted within 24 h of image generation (simulate production rule)
- [ ] Only derived artefacts are retained: Vision JSON, rendered PNGs
- [ ] Rendered avatars may be used in internal team review only (not public)
- [ ] Couple may withdraw consent before day 7 (before photo upload); after upload, deletion is automatic within 24 h
- [ ] Early-access / thank-you avatar offer (if applicable)
- [ ] Data controller: [legal entity to be confirmed by legal review gate]
- [ ] GDPR lawful basis: legitimate interest (research / product development); explicit consent for biometric-adjacent data

### Diversity checklist — 20 pairs manifest

Each row maps to an entry in `pairs.manifest.json`. Confirm each pair is recruited before uploading.

The 10 tone/hair buckets are derived from 5 skin-tone bands × 2 hair-type groups:

| Tone band | Code | ITA reference range (approx) |
|-----------|------|-------------------------------|
| Light | L | ITA > 41° |
| Light-medium | LM | ITA 28°–41° |
| Medium | M | ITA 10°–28° |
| Medium-dark | MD | ITA −10°–10° |
| Dark | D | ITA < −10° |

| Hair group | Code | Curl pattern |
|------------|------|--------------|
| Straight / wavy | S | Type 1–2 |
| Curly / coily | C | Type 3–4 |

**20 pairs: 2 per bucket, 10 bumper (B) + 10 newborn (N)**

| Pair ID | Tone bucket | Hair bucket | Mode | Consent received | Photos uploaded | ✓ |
|---------|-------------|-------------|------|-----------------|-----------------|---|
| pair-001 | Light (L) | Straight/wavy (S) | Bumper | ☐ | ☐ | ☐ |
| pair-002 | Light (L) | Straight/wavy (S) | Newborn | ☐ | ☐ | ☐ |
| pair-003 | Light (L) | Curly/coily (C) | Bumper | ☐ | ☐ | ☐ |
| pair-004 | Light (L) | Curly/coily (C) | Newborn | ☐ | ☐ | ☐ |
| pair-005 | Light-medium (LM) | Straight/wavy (S) | Bumper | ☐ | ☐ | ☐ |
| pair-006 | Light-medium (LM) | Straight/wavy (S) | Newborn | ☐ | ☐ | ☐ |
| pair-007 | Light-medium (LM) | Curly/coily (C) | Bumper | ☐ | ☐ | ☐ |
| pair-008 | Light-medium (LM) | Curly/coily (C) | Newborn | ☐ | ☐ | ☐ |
| pair-009 | Medium (M) | Straight/wavy (S) | Bumper | ☐ | ☐ | ☐ |
| pair-010 | Medium (M) | Straight/wavy (S) | Newborn | ☐ | ☐ | ☐ |
| pair-011 | Medium (M) | Curly/coily (C) | Bumper | ☐ | ☐ | ☐ |
| pair-012 | Medium (M) | Curly/coily (C) | Newborn | ☐ | ☐ | ☐ |
| pair-013 | Medium-dark (MD) | Straight/wavy (S) | Bumper | ☐ | ☐ | ☐ |
| pair-014 | Medium-dark (MD) | Straight/wavy (S) | Newborn | ☐ | ☐ | ☐ |
| pair-015 | Medium-dark (MD) | Curly/coily (C) | Bumper | ☐ | ☐ | ☐ |
| pair-016 | Medium-dark (MD) | Curly/coily (C) | Newborn | ☐ | ☐ | ☐ |
| pair-017 | Dark (D) | Straight/wavy (S) | Bumper | ☐ | ☐ | ☐ |
| pair-018 | Dark (D) | Straight/wavy (S) | Newborn | ☐ | ☐ | ☐ |
| pair-019 | Dark (D) | Curly/coily (C) | Bumper | ☐ | ☐ | ☐ |
| pair-020 | Dark (D) | Curly/coily (C) | Newborn | ☐ | ☐ | ☐ |

**Coverage check before closing recruitment:**

- [ ] All 10 tone/hair buckets represented (2 pairs each)
- [ ] 10 Bumper-mode pairs (pair-001, 003, 005, 007, 009, 011, 013, 015, 017, 019)
- [ ] 10 Newborn-mode pairs (pair-002, 004, 006, 008, 010, 012, 014, 016, 018, 020)
- [ ] All 20 consent forms signed
- [ ] All 20 photo sets uploaded to `fixtures/photo-pairs/` (gitignored) in spike branch

---

## 4. Panel Scoring Sheet Instructions

### Template location

`scripts/avatar-spike/panel-scores.template.csv` in `Dr-kersho/nourish` (spike branch).

Copy to `scripts/avatar-spike/panel-scores.csv` before panel rating begins. Do **not** commit the filled version to git (it contains panellist-linked ratings; store in shared drive or encrypted at rest).

### What panellists score: G1 and G2 only

Panellists are not asked to score G3, G4, G5, or G6. Those are automated or PM-reviewed gates.

**G1 — Resonance (per image set)**

> "Looking at the 7 images for this pair, would you show this avatar to your partner as 'this could be our baby'?"

Rating scale:

| Score | Label |
|-------|-------|
| 5 | Absolutely yes — it feels like us |
| 4 | Probably yes — close enough |
| 3 | Maybe — something feels off but I could see it |
| 2 | Probably not — doesn't feel right |
| 1 | Definitely not |

Pass threshold: **≥70% of all ratings across all pairs ≥4** per vendor.

**G2 — Uncanny (per image set)**

> "Does any image in this set feel creepy, too realistic, or unsettling?"

| Score | Label |
|-------|-------|
| Yes | At least one image feels creepy or too real |
| No | All images feel safely illustrated / fictional |

Pass threshold: **≤10% of pairs rated "Yes"** per vendor.

### How panellists receive images

The Tech Lead generates a Google Drive folder (or equivalent) per vendor per pair, shared with the panel via anonymous link. Images are labelled by stage only (bumper, newborn, 6m, 12m, etc.) — **vendor name is hidden** to avoid bias. Panellists see three image sets per pair (one per vendor, labelled A / B / C in randomised order per couple).

### G3 — Diversity review (PM only, not panellists)

G3 is a manual review by the PM across all rendered output — not a panellist task.

PM checks each of the 10 tone/hair buckets for:

- [ ] Rendered skin tone matches the tone bucket (not lightened, darkened, or generically "averaged")
- [ ] Rendered hair type matches the hair bucket (not straightened or texture-smoothed)
- [ ] No cultural-stereotype artefacts introduced (e.g. clothing, setting, accessories added by the model that stereotype the couple's perceived ethnicity)

G3 pass: no bucket shows systematic drift. Any single failure = flag to Tech Lead; document in scorecard.

### Scoring sheet column guide

```
pair_id       | e.g. pair-001
vendor        | fal / replicate / dalle (hidden from panellists; PM fills after unblinding)
panellist_id  | P01–P10 (couple-level ID; both partners rate independently if possible)
g1_score      | 1–5
g2_yes_no     | yes / no
notes         | Optional free text
```

**Aggregate after collection:**

- G1 pass: count of ratings ≥4 / total ratings ≥0.70 per vendor
- G2 pass: count of "yes" / total pairs ≤0.10 per vendor

---

## 5. Kill Criteria Reminders

Check each criterion as results come in. Do **not** wait until day 14 — stop early if triggered.

| # | Kill criterion | Triggered when | Action |
|---|----------------|---------------|--------|
| K1 | All vendors fail G4 (consistency) avg <3 | Embedding similarity + panel: fictional baby identity breaks across stages | STOP immediately; do not collect more panel data; disposition → DISCARD; re-grill avatar architecture before any app work |
| K2 | All vendors fail G6 (policy) <95% custom avatar rate | ≥5% of pairs fall to preset fallback across all vendors | STOP; remove DALL-E from production path; if fal + Replicate also fail, DISCARD photo-reference pipeline |
| K3 | Cost >£1.00/family (initial + 6 stages) for all vendors | `cost_per_family` row in scorecard exceeds £1.00 for every vendor | STOP; re-scope to fewer stages or preset-heavy fallback; disposition → DISCARD current pipeline |
| K4 | Vendor DPA prohibits EU processing or retains training data without opt-out | DPA review (day 6–7) | Exclude that vendor immediately; do not run that vendor's pipeline; note in AgDR-0064 |
| K5 | Panel G1 average <3 for all vendors after 10 pairs | Resonance fails for >50% of panellists across all vendors | STOP; the illustrated style or prompt direction is wrong before vendor is the variable; DISCARD; revise storybook art direction first |

**G5 ops threshold reminder:** p95 <60 s; cost <£0.50/family for 7 images. If only G5 fails, flag to Tech Lead for inference optimisation — not a spike kill, but note it as a production risk in AgDR-0064.

---

## 6. Disposition: PROMOTE vs DISCARD

### PROMOTE (hypothesis confirmed)

**Conditions:** At least one vendor (or split pair) achieves avg ≥4.0 across G1–G6 with no gate below 3, and no kill criterion triggered.

**Actions (in order):**

1. Tech Lead + Omar unblind vendor labels in scorecard.
2. Tech Lead names initial vendor (best G1+G2+G6) and aging vendor (best G4) in `scorecard.csv`.
3. Omar updates AgDR-0064:
   - `Status: Accepted`
   - Fill vendor table (initial + aging + model/API versions)
   - Link scorecard path
   - Note split-vendor rationale if different vendors are used for initial vs aging
4. Tech Lead runs `/spike-close --promote` in the Nourish repo (or ops repo), which files a `[Feature]` ticket in `Dr-kersho/nourish` for the production avatar worker integration.
5. Spike code in `spike/GH-1-avatar-vendor-api` branch is **not** promoted to main; artefacts preserved: scorecard, sample gallery, updated AgDR.
6. Omar proceeds to **Gate 3** in `README.md` (Legal sign-off: GDPR / PDPL / child-data) — do not begin mobile app scaffold until legal gate passes.
7. Update `projects/nourish/README.md` — mark SPIKE-001 gate complete.

### DISCARD (hypothesis not confirmed)

**Conditions:** All vendors fail to meet pass thresholds, or one or more kill criteria (K1–K5) are triggered.

**Actions (in order):**

1. Tech Lead + Omar document the failure mode(s) in spike memo (auto-generated by `/spike-close --discard`).
2. Omar updates AgDR-0064:
   - `Status: Superseded` (or add a Revision note)
   - Note which criteria failed and why
   - Note which vendors are permanently excluded (especially DPA failures)
3. **Do not scaffold the Nourish app** — this is a hard gate. No Supabase schema, no React Native shell, no RevenueCat wiring until architecture is re-grilled.
4. Omar schedules a re-grill session with Hisham (Tech Lead) to determine the revised avatar architecture path:
   - Option A: Revised prompting / LoRA fine-tuning — file a new spike
   - Option B: Drop photo-reference pipeline; use preset palette only — rework PRD Layer 3
   - Option C: Reassess illustrated style — bring in a design partner for reference set
5. Update `projects/nourish/README.md` — mark SPIKE-001 as DISCARD; add next gate.

---

*This runbook is owned by Omar (Head of Product). Ping Hisham (Tech Lead) for G4/G5/G6 scoring logistics and script queries.*
