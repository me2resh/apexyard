# blendavit — Meta trial prompts

Brand: mint `#e8f2f0`, forest `#1a3d32`, gold `#8a6428`. Calm pharmacy DTC. KSA parents, picky eaters.

---

## B1 · Poster · Midjourney

**Settings:** `--ar 1:1 --style raw --v 6.1`

```
Premium Saudi family wellness ad photography, morning kitchen, soft natural window light, mother hands stirring plain white yoghurt in ceramic bowl, small toddler portion nearby, mint-green and cream color palette, shallow depth of field, clinical warmth not cartoon, EllaOla register, no gummy vitamins, no visible brand logo, empty lower third for text overlay, photoreal editorial DTC supplement --ar 1:1 --style raw
```

**Overlay (Canva, AR):**  
Headline: `فيتامينات بدون طعم — تذوب في الزبادي`  
Sub: `حديد liposomal · بدون سكر · 30 ظرف`

---

## B2 · Poster · GPT 4o

```
Square 1080x1080 marketing poster, split editorial layout. Left third: muted refused gummy vitamins flat lay, desaturated. Right two-thirds: clean mint #e8f2f0 background, minimal line illustration of single sachet, forest green #1a3d32 accent bar, gold #8a6428 thin rule. Premium supplement brand, lots of whitespace, no people, no embedded text, no logos.
```

**Overlay (AR):**  
`تعبتي من الحلوى؟` / `مسحوق واحد · 0g سكر · حديد فعلي`

---

## B3 · Poster · GPT 4o

```
Vertical 1080x1350 product selector mockup, two equal cards on mint-tinted background: left card "Toddlers 1-3", right card "Kids 4+", forest green pill buttons, gold accent, white cards 18px radius, Albert Sans style typography placeholder blocks but NO readable text, premium DTC supplement PDP, KSA luxury wellness, no doctor, no stock photo faces.
```

**Overlay (AR):**  
`اختر الفئة المناسبة لطفلك` / `احجزي الآن — المملكة فقط`

---

## B4 · Video 20s · Kling (+ optional Runway)

### Kling (primary — use your photos)

Source images (in order, ~5s each):

1. `website/assets/images/hero-stir-yoghurt.png`
2. `website/assets/images/usage-stir-yoghurt.png`
3. `website/assets/images/usage-oats-bowl.png`
4. Pack shot WhatsApp PNG

**Kling prompt (per clip, i2v):**

```
Subtle natural motion, spoon slowly stirring yoghurt, steam-free kitchen, soft morning light, premium commercial, camera almost static, 5 seconds
```

**Motion strength:** Low–medium (avoid morphing hands/faces).

### Runway (optional 3s insert only if Kling clip 1 is weak)

Text-to-video:

```
Macro close-up plain yoghurt bowl, powder dissolving invisible, mint and white palette, commercial supplement ad b-roll, no faces, 3 seconds
```

### Assembly (CapCut / MPT)

| Time | Visual | VO (AR) |
|------|--------|---------|
| 0–3s | hero stir | طفلك يرفض الفيتامينات؟ |
| 3–8s | gummy cutaway still OR B2 poster | الحلوى فيها سugar. والشراب فيه طعم. |
| 8–14s | usage stir + oats | blendavit مسحوق بدون طعم — يختفي في الزبادي واللبن. |
| 14–18s | pack | حديد liposomal · SFDA · ثلاثين ظرف. |
| 18–20s | CTA card | احجزي علبتك |

**Export:** 1080×1920, H.264, ≤30MB for Meta.
