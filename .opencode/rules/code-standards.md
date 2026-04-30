# Code Standards

These are sensible defaults for a TypeScript-leaning team. Adjust to fit your stack — the principles transfer.

## TypeScript

- Strict mode **must** be enabled in all projects
- No bare `any` types without an inline justification comment
- No swallowed errors (no empty catch blocks)
- Always handle errors or re-throw with context

## Domain-Driven Design

- Domain layer has **no external dependencies** (no frameworks, no HTTP, no DB)
- Application layer does **not** import infrastructure
- Proper separation: commands vs queries
- Value objects for domain concepts
- Domain events for side effects
- Repository pattern for data access

## Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Components | PascalCase | `UserProfile.tsx` |
| Hooks | camelCase with `use` prefix | `useAuth.ts` |
| Utilities | camelCase | `formatDate.ts` |
| Tests | Same name + `.test` | `UserProfile.test.tsx` |
| Directories | kebab-case | `user-management/` |
| Variables | camelCase | `userName` |
| Constants | SCREAMING_SNAKE | `MAX_RETRY_COUNT` |
| Booleans | `is/has/can` prefix | `isActive`, `hasPermission` |
| Domain Events | Past tense | `OrderPlaced`, `PaymentReceived` |

## Testing

- Roughly 70% unit, 20% integration, 10% E2E
- Tests test **behavior**, not implementation
- Arrange-Act-Assert pattern
- Coverage > 80% for domain logic

Pick the testing tools that fit your stack. Vitest + Playwright is one common combination; Jest + Cypress is another.

## Frontend

- Local state: framework primitive (e.g. `useState`)
- Server state: a query library (e.g. TanStack Query)
- Global state: only when justified (e.g. Zustand, Redux)
- Forms: schema-validated (e.g. React Hook Form + Zod)
- Always export the interface for component props
