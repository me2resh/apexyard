# Backspace — Prisma Schema Draft

## Purpose

This is a first-pass Prisma/PostgreSQL schema draft for the Backspace MVP. It is intended to accelerate Sprint 0/1 implementation after the Next.js + PostgreSQL repository is created.

This draft should be copied/adapted into `prisma/schema.prisma` in the implementation repo, then reviewed during migration creation.

---

## Notes

- Prisma model names use PascalCase.
- Database table names map to snake_case with `@@map`.
- The MVP is single-location, but `LocationSettings` remains configurable for future reuse/white-label needs.
- Customers are internal records only and never authenticate.
- Staff authentication uses `StaffUser.passwordHash` and `StaffUser.isActive`.

---

## Prisma Schema Draft

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

enum StaffRole {
  owner
  manager
  staff
}

enum CustomerType {
  visitor
  subscriber
  company
}

enum VisitStatus {
  open
  closed
  cancelled
}

enum SubscriptionDurationType {
  weekly
  biweekly
  monthly
}

enum CustomerSubscriptionStatus {
  active
  expired
  cancelled
}

enum BookingStatus {
  confirmed
  cancelled
  completed
}

enum InvoiceSourceType {
  visit
  subscription
  booking
  manual
}

enum InvoiceStatus {
  unpaid
  paid
  overdue
  cancelled
}

enum PaymentMethod {
  cash
  bank_transfer
  external_card
  other
}

model StaffUser {
  id           String    @id @default(uuid()) @db.Uuid
  name         String
  email        String    @unique
  passwordHash String    @map("password_hash")
  role         StaffRole
  isActive     Boolean   @default(true) @map("is_active")
  createdAt    DateTime  @default(now()) @map("created_at")
  updatedAt    DateTime  @updatedAt @map("updated_at")

  createdVisits Visit[]   @relation("VisitCreatedBy")
  closedVisits  Visit[]   @relation("VisitClosedBy")
  bookings      Booking[] @relation("BookingCreatedBy")
  payments      Payment[] @relation("PaymentReceivedBy")
  auditLogs     AuditLog[]

  @@map("staff_users")
}

model LocationSettings {
  id            String   @id @default(uuid()) @db.Uuid
  locationName  String   @map("location_name")
  logoUrl       String?  @map("logo_url")
  address       String?
  phone         String?
  invoicePrefix String   @map("invoice_prefix")
  taxNumber     String?  @map("tax_number")
  currency      String   @default("EGP")
  updatedAt     DateTime @updatedAt @map("updated_at")

  @@map("location_settings")
}

model Space {
  id         String   @id @default(uuid()) @db.Uuid
  name       String
  type       String
  capacity   Int
  hourlyRate Decimal  @map("hourly_rate") @db.Decimal(10, 2)
  isActive   Boolean  @default(true) @map("is_active")
  notes      String?
  createdAt  DateTime @default(now()) @map("created_at")
  updatedAt  DateTime @updatedAt @map("updated_at")

  visits   Visit[]
  bookings Booking[]

  @@index([isActive])
  @@map("spaces")
}

model Customer {
  id         String       @id @default(uuid()) @db.Uuid
  name       String
  phone      String
  email      String?
  type       CustomerType
  notes      String?
  archivedAt DateTime?    @map("archived_at")
  createdAt  DateTime     @default(now()) @map("created_at")
  updatedAt  DateTime     @updatedAt @map("updated_at")

  visits        Visit[]
  subscriptions CustomerSubscription[]
  bookings      Booking[]
  invoices      Invoice[]

  @@index([phone])
  @@index([type])
  @@index([archivedAt])
  @@map("customers")
}

model Visit {
  id                 String      @id @default(uuid()) @db.Uuid
  customerId         String      @map("customer_id") @db.Uuid
  spaceId            String      @map("space_id") @db.Uuid
  checkInAt          DateTime    @map("check_in_at")
  checkOutAt         DateTime?   @map("check_out_at")
  durationMinutes    Int?        @map("duration_minutes")
  hourlyRateSnapshot Decimal     @map("hourly_rate_snapshot") @db.Decimal(10, 2)
  totalAmount        Decimal?    @map("total_amount") @db.Decimal(10, 2)
  status             VisitStatus @default(open)
  notes              String?
  createdByStaffId   String      @map("created_by_staff_id") @db.Uuid
  closedByStaffId    String?     @map("closed_by_staff_id") @db.Uuid
  createdAt          DateTime    @default(now()) @map("created_at")
  updatedAt          DateTime    @updatedAt @map("updated_at")

  customer       Customer  @relation(fields: [customerId], references: [id])
  space          Space     @relation(fields: [spaceId], references: [id])
  createdByStaff StaffUser @relation("VisitCreatedBy", fields: [createdByStaffId], references: [id])
  closedByStaff  StaffUser? @relation("VisitClosedBy", fields: [closedByStaffId], references: [id])
  invoices       Invoice[]

  @@index([status])
  @@index([checkInAt])
  @@index([customerId])
  @@index([spaceId])
  @@map("visits")
}

model SubscriptionPlan {
  id           String                   @id @default(uuid()) @db.Uuid
  name         String
  durationType SubscriptionDurationType @map("duration_type")
  durationDays Int                      @map("duration_days")
  price        Decimal                  @db.Decimal(10, 2)
  isActive     Boolean                  @default(true) @map("is_active")
  createdAt    DateTime                 @default(now()) @map("created_at")
  updatedAt    DateTime                 @updatedAt @map("updated_at")

  customerSubscriptions CustomerSubscription[]

  @@index([durationType])
  @@index([isActive])
  @@map("subscription_plans")
}

model CustomerSubscription {
  id            String                     @id @default(uuid()) @db.Uuid
  customerId    String                     @map("customer_id") @db.Uuid
  planId        String                     @map("plan_id") @db.Uuid
  startDate     DateTime                   @map("start_date") @db.Date
  endDate       DateTime                   @map("end_date") @db.Date
  priceSnapshot Decimal                    @map("price_snapshot") @db.Decimal(10, 2)
  status        CustomerSubscriptionStatus @default(active)
  notes         String?
  createdAt     DateTime                   @default(now()) @map("created_at")
  updatedAt     DateTime                   @updatedAt @map("updated_at")

  customer Customer         @relation(fields: [customerId], references: [id])
  plan     SubscriptionPlan @relation(fields: [planId], references: [id])
  invoices Invoice[]

  @@index([customerId])
  @@index([status])
  @@index([endDate])
  @@map("customer_subscriptions")
}

model Booking {
  id               String        @id @default(uuid()) @db.Uuid
  customerId       String        @map("customer_id") @db.Uuid
  spaceId          String        @map("space_id") @db.Uuid
  startsAt         DateTime      @map("starts_at")
  endsAt           DateTime      @map("ends_at")
  status           BookingStatus @default(confirmed)
  notes            String?
  createdByStaffId String        @map("created_by_staff_id") @db.Uuid
  createdAt        DateTime      @default(now()) @map("created_at")
  updatedAt        DateTime      @updatedAt @map("updated_at")

  customer       Customer  @relation(fields: [customerId], references: [id])
  space          Space     @relation(fields: [spaceId], references: [id])
  createdByStaff StaffUser @relation("BookingCreatedBy", fields: [createdByStaffId], references: [id])
  invoices       Invoice[]

  @@index([spaceId, startsAt, endsAt])
  @@index([status])
  @@index([customerId])
  @@map("bookings")
}

model Invoice {
  id            String            @id @default(uuid()) @db.Uuid
  invoiceNumber String            @unique @map("invoice_number")
  customerId    String            @map("customer_id") @db.Uuid
  sourceType    InvoiceSourceType @map("source_type")
  sourceId      String?           @map("source_id") @db.Uuid
  subtotal      Decimal           @db.Decimal(10, 2)
  total         Decimal           @db.Decimal(10, 2)
  status        InvoiceStatus     @default(unpaid)
  issuedAt      DateTime          @default(now()) @map("issued_at")
  dueAt         DateTime?         @map("due_at")
  createdAt     DateTime          @default(now()) @map("created_at")
  updatedAt     DateTime          @updatedAt @map("updated_at")

  customer Customer @relation(fields: [customerId], references: [id])
  payments Payment[]

  // Source-specific optional relations. sourceId is generic, so these are
  // documented relationships rather than enforced polymorphic relations.

  @@index([customerId])
  @@index([sourceType, sourceId])
  @@index([status])
  @@index([issuedAt])
  @@map("invoices")
}

model Payment {
  id                String        @id @default(uuid()) @db.Uuid
  invoiceId         String        @map("invoice_id") @db.Uuid
  amount            Decimal       @db.Decimal(10, 2)
  method            PaymentMethod
  paidAt            DateTime      @map("paid_at")
  receivedByStaffId String        @map("received_by_staff_id") @db.Uuid
  notes             String?
  createdAt         DateTime      @default(now()) @map("created_at")

  invoice         Invoice   @relation(fields: [invoiceId], references: [id])
  receivedByStaff StaffUser @relation("PaymentReceivedBy", fields: [receivedByStaffId], references: [id])

  @@index([invoiceId])
  @@index([paidAt])
  @@index([method])
  @@map("payments")
}

model AuditLog {
  id           String    @id @default(uuid()) @db.Uuid
  actorStaffId String    @map("actor_staff_id") @db.Uuid
  action       String
  entityType   String    @map("entity_type")
  entityId     String    @map("entity_id") @db.Uuid
  before       Json?
  after        Json?
  createdAt    DateTime  @default(now()) @map("created_at")

  actorStaff StaffUser @relation(fields: [actorStaffId], references: [id])

  @@index([actorStaffId])
  @@index([entityType, entityId])
  @@index([createdAt])
  @@map("audit_logs")
}
```

---

## Additional Database Constraints to Consider

Prisma cannot express every business constraint cleanly in the schema. Add service-level checks and, where needed, raw SQL migrations for:

### Single `location_settings` row

MVP expects one row only. Enforce through application logic or a fixed singleton ID.

### Booking conflict prevention

The main overlap rule should be checked transactionally:

```text
new.startsAt < existing.endsAt
AND new.endsAt > existing.startsAt
AND existing.status = confirmed
AND existing.spaceId = new.spaceId
```

For stronger database-level protection, consider a PostgreSQL exclusion constraint later.

### Invoice source uniqueness

MVP should prevent duplicate invoice creation for the same `sourceType + sourceId`, except `manual` invoices where `sourceId` is null.

### Positive money values

Validate in application code:

- `hourlyRate >= 0`
- `price >= 0`
- `invoice.total >= 0`
- `payment.amount > 0`

---

## Sprint 1 Subset

For the first migration, start with only:

- `StaffRole` enum
- `StaffUser`
- `LocationSettings`

Then add module tables sprint by sprint to keep migrations easy to review.
