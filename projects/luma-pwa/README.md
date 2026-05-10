# LUMA PWA

**Source repo:** [github.com/Dr-kersho/luma-pwa](https://github.com/Dr-kersho/luma-pwa)

Aesthetic clinic booking marketplace PWA (patient app + clinic admin under one deploy).

## Stack (high level)

- Next.js 14 App Router, TypeScript, Tailwind, Prisma 7, Neon PostgreSQL
- Auth: patient OTP (Twilio in production), clinic admin PIN, httpOnly JWT
- Email: Resend; uploads: Vercel Blob; optional Plausible after cookie consent

## ApexYard docs here

PRDs, technical notes, and AgDRs for this product live under `projects/luma-pwa/` in the ops repo. Implementation truth is always the **luma-pwa** git repo.

## Local clone (optional)

From the ops repo root, convention is `workspace/luma-pwa` (gitignored). You can also keep a sibling clone at `D:\projects\luma-pwa` and point tools at it; hooks resolve the ops root via `onboarding.yaml` + `apexyard.projects.yaml`.

## Ticket prefix

Engineering labels in app docs: **LUM-xx** (see `docs/TICKETS.md` in the app repo).
