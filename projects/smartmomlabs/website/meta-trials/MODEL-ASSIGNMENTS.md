# Meta ad trials — model assignments

Production model per asset. **Do not use one model for everything** — each tool has a sweet spot.

| Model | Use for | Skip for |
|-------|---------|----------|
| **Midjourney** | Photoreal lifestyle, luxury mood, editorial light | Exact UI mockups, Arabic text in-image |
| **GPT 4o** (ChatGPT / API image) | Layout-controlled posters, phone mockups, variant cards | Long video, subtle motion |
| **Kling 1.6 Pro** | Image-to-video from **your** blendavit photos | App UI screen recording |
| **Runway Gen-3 Alpha** | UI motion, short app promo clips, i2v polish | Full 20s narrative alone |
| **Veo 3.1** | Cinematic 5–8s clinic B-roll hook (Luma) | Product/supplement shots (uncanny risk) |

**Arabic copy:** Generate images **without** embedded text. Overlay in Canva/Figma/CapCut (Tajawal / Noto Sans Arabic).

---

## blendavit

| # | Asset | Format | Model | File |
|---|-------|--------|-------|------|
| B1 | Lifestyle hero | 1536×1024 | **Midjourney** | `blendavit-poster-1-lifestyle.png` — **blocked:** Gemini watermark in frame; hero uses `hero-stir-yoghurt` until regenerated |
| B2 | Problem → solution | 1536×1024 | **GPT 4o** | `blendavit-poster-2-split.png` → `assets/images/posters/poster-split-gummy.*` |
| B3 | Variant picker | 1536×1024 | **GPT 4o** | `blendavit-poster-3-variants.png` → `assets/images/posters/poster-variants.*` |
| B4 | Meta Reels ad | 1080×1920 · 20s | **Kling** (primary) + **Runway** (optional 3s cutaway) | `blendavit-reel-20s.mp4` |

## LUMA PWA

| # | Asset | Format | Model | File |
|---|-------|--------|-------|------|
| L1 | Explore / app promo | 1080×1080 | **GPT 4o** | `luma-poster-1-explore.png` |
| L2 | Book flow UI | 1080×1350 | **GPT 4o** | `luma-poster-2-booking.png` |
| L3 | Trust / luxury mood | 1080×1080 | **Midjourney** | `luma-poster-3-trust.png` |
| L4 | Meta Reels ad | 1080×1920 · 22s | **Veo 3.1** (0–6s hook) + **Runway** (6–22s UI) | `luma-reel-22s.mp4` |

---

## Why this split

- **blendavit** already has real product/lifestyle photography → **Kling i2v** beats generative video (Veo/Runway from text) for trust.
- **Luma** sells a **UI product** → **GPT 4o** for static mocks; **Runway** for screen motion; **Veo** only for a short premium clinic atmosphere opener (not fake faces).

Prompts: `blendavit/PROMPTS.md`, `luma-pwa/PROMPTS.md` (in ops repo under each project's meta-trials folder).
