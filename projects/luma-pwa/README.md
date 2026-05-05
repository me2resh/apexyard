# LUMA PWA

Aesthetic clinic booking marketplace PWA.

## Stack
- **Framework:** Next.js 14 (App Router)
- **Language:** TypeScript
- **Styling:** Tailwind CSS + CSS custom properties
- **Design System:** ApexYard brutalism (JetBrains Mono, warm paper, red accent, sharp corners)
- **UI Library:** @base-ui/react + shadcn/ui
- **State:** React Context
- **Auth:** Mock (any 4-digit OTP, any 4-digit admin PIN)
- **Analytics:** Consent-gated in-memory + localStorage log
- **Error tracking:** ErrorBoundary + analytics.error()
- **SEO:** Sitemap, robots.txt, OG/Twitter metadata, JSON-LD structured data
- **Database:** (planned) PostgreSQL + Prisma
- **Payments:** (planned) Telr/Stripe
- **Hosting:** (planned) Vercel

## Routes
| Route | Status | Description |
|-------|--------|-------------|
| `/` | Done | Login (phone + OTP) |
| `/explore` | Done | Clinic listing (auth required) |
| `/clinic/[id]` | Done | Clinic detail + slots (auth required) |
| `/book/[id]` | Done | Booking + payment (mock, auth required) |
| `/confirmed` | Done | Confirmation page (auth required) |
| `/ai-check` | Done | AI skin analysis (mock, auth required) |
| `/wallet` | Done | Wallet + transactions (auth required) |
| `/profile` | Done | User profile (auth required) |
| `/partner/register` | Done | Clinic onboarding form (auth required) |
| `/admin/*` | Done | Admin panel (requires admin auth) |
| `/privacy` | Done | Privacy policy |
| `/terms` | Done | Terms of service |
| `/api/health` | Done | Health check endpoint |
| `/robots.txt` | Done | Auto-generated |
| `/sitemap.xml` | Done | Auto-generated with clinic routes |

## Open Items (see #36)
- [x] Apply ApexYard brutalism design system (JetBrains Mono, paper palette, red accent, 0 radius)
- [x] Login page redesigned with terminal-style hero
- [x] Clinic detail page redesigned with titlebar + brutal cards
- [x] BottomNav, CookieBanner, ErrorBoundary updated
- [ ] Dark mode visual audit across all pages
- [ ] Arabic font fallback for DHA/terms pages

## Still needed for production
- Real backend (Node/Express API or Next.js API routes)
- Real auth (Twilio OTP + JWT)
- Database (PostgreSQL + Prisma)
- Payment integration (Telr/Stripe)
- Notifications (SMS/email)
- PWA service worker / offline support
- Oman DHA compliance
