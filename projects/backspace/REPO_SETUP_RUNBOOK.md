# Backspace — Repository Setup Runbook

## Purpose

This runbook describes how to create the Backspace implementation repository using the selected defaults:

- Next.js App Router
- TypeScript
- PostgreSQL
- Prisma
- Zod
- Tailwind CSS
- shadcn/ui
- Session-based staff auth
- Docker Compose PostgreSQL
- Vitest

Use this once the team is ready to create the actual code repository.

---

## 1. Preconditions

Before running setup:

- [ ] Repository name is confirmed: `backspace`.
- [ ] GitHub org/owner is confirmed.
- [ ] Local workspace location is confirmed, likely `workspace/backspace/`.
- [ ] Node.js version is agreed.
- [ ] Package manager is chosen.
- [ ] PostgreSQL local port is available.
- [ ] Initial owner email/password seeding strategy is agreed.

Still open from planning:

- Package manager.
- Hosting target.
- Exact session storage mechanism.
- PDF invoice scope.
- CSV/Excel export scope.

---

## 2. Create the App

Example using npm:

```bash
mkdir -p workspace
cd workspace
npx create-next-app@latest backspace --ts --eslint --tailwind --app
cd backspace
```

Recommended initial choices if prompted:

- TypeScript: yes
- ESLint: yes
- Tailwind: yes
- App Router: yes
- `src/` directory: yes
- Import alias: yes, `@/*`

---

## 3. Install Core Dependencies

```bash
npm install @prisma/client zod
npm install -D prisma vitest
```

Optional but recommended for password/session work:

```bash
npm install argon2
```

If Argon2 causes platform issues, use bcrypt instead:

```bash
npm install bcrypt
npm install -D @types/bcrypt
```

---

## 4. Initialize Prisma

```bash
npx prisma init
```

Expected files:

```text
prisma/schema.prisma
.env
```

Move secrets out of committed files:

- Keep `.env` uncommitted.
- Add `.env.example` with placeholder values only.

---

## 5. Add Docker Compose PostgreSQL

Create `compose.yaml`:

```yaml
services:
  postgres:
    image: postgres:16
    container_name: backspace-postgres
    restart: unless-stopped
    # Configure database credentials locally.
    # Do not commit real credential values.
    env_file:
      - .env.local
    ports:
      - "5432:5432"
    volumes:
      - backspace-postgres-data:/var/lib/postgresql/data

volumes:
  backspace-postgres-data:
```

Create `.env.example`:

```text
DATABASE_URL="<local-postgres-connection-url>"
SESSION_SECRET="<development-session-secret>"
INITIAL_OWNER_EMAIL="owner@example.local"
INITIAL_OWNER_INITIAL_CREDENTIAL="<set-locally-only>"
```

Start database:

```bash
docker compose up -d
```

---

## 6. Configure Prisma Datasource

In `prisma/schema.prisma`:

```prisma
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}
```

Sprint 1 models to add first:

- `StaffUser`
- `LocationSettings`

Use the detailed fields from `projects/backspace/TECHNICAL_DESIGN.md`.

---

## 7. Initialize shadcn/ui

```bash
npx shadcn@latest init
```

Recommended defaults:

- Style: default or new-york
- Base color: neutral or slate
- CSS variables: yes
- Tailwind config: existing project config
- Components path: `src/components`

Add early components:

```bash
npx shadcn@latest add button input label card form table dialog select tabs alert
```

---

## 8. Arabic RTL Foundation

In the root layout, make the app Arabic RTL from the start:

```tsx
<html lang="ar" dir="rtl">
```

Sprint 0 UI must include:

- Arabic labels.
- RTL layout direction.
- Admin shell skeleton.
- No public customer/visitor routes.

---

## 9. Suggested Initial Source Structure

```text
src/
  app/
    (auth)/
      login/
    (app)/
      dashboard/
      settings/
        location/
  modules/
    auth/
    location-settings/
  db/
    prisma.ts
  ui/
  lib/
```

Add more modules as sprints progress:

```text
spaces/
customers/
visits/
subscriptions/
bookings/
billing/
dashboard/
reports/
audit/
```

---

## 10. Sprint 1 First Models

### `StaffUser`

Required properties:

- `id`
- `name`
- `email` unique
- `passwordHash`
- `role`: owner / manager / staff
- `isActive`
- `createdAt`
- `updatedAt`

### `LocationSettings`

Required properties:

- `id`
- `locationName`
- `logoUrl`
- `address`
- `phone`
- `invoicePrefix`
- `taxNumber`
- `currency`
- `updatedAt`

---

## 11. First Migration

After adding Sprint 1 models:

```bash
npx prisma migrate dev --name init_staff_and_location
npx prisma generate
```

---

## 12. Seed Owner Account

Create a seed script that:

- Reads initial owner email/password from environment variables.
- Hashes password with Argon2 or bcrypt.
- Creates or updates the Owner user.
- Creates initial `location_settings` row.

Important:

- Do not commit real passwords.
- Do not log raw passwords.
- Do not store raw passwords in the database.

---

## 13. Required Sprint 1 Routes

### Pages

- `/login`
- `/dashboard`
- `/settings/location`

### API / server functions

- Login
- Logout
- Current user
- Read location settings
- Update location settings as Owner only

If using route handlers, planned API paths are:

- `POST /api/auth/login`
- `POST /api/auth/logout`
- `GET /api/auth/me`
- `GET /api/settings/location`
- `PATCH /api/settings/location`

---

## 14. Verification Commands

Add or confirm scripts for:

```bash
npm run lint
npm run typecheck
npm test
npm run build
```

If `typecheck` is not generated by default, add:

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test": "vitest run"
  }
}
```

---

## 15. Sprint 0/1 Done Checklist

- [ ] Next.js app created.
- [ ] TypeScript enabled.
- [ ] Tailwind enabled.
- [ ] shadcn/ui initialized.
- [ ] PostgreSQL runs via Docker Compose.
- [ ] Prisma initialized.
- [ ] `.env.example` exists with placeholders only.
- [ ] `StaffUser` model exists.
- [ ] `LocationSettings` model exists.
- [ ] First migration runs.
- [ ] Owner seed script exists.
- [ ] Login page is Arabic RTL.
- [ ] Dashboard shell is protected.
- [ ] Location settings page is Owner-only.
- [ ] No customer/visitor-facing pages exist.
- [ ] Lint/typecheck/test/build commands pass.

---

## 16. After Repo Creation

Once the implementation repo exists:

1. Update `projects/backspace/README.md` with the real repo URL.
2. Add Backspace to `apexyard.projects.yaml`.
3. Consider creating `workspace/backspace/` as the local clone path.
4. Convert `IMPLEMENTATION_BACKLOG.md` items into real tracker issues if desired.
5. Start work with the first active implementation item.
