// Source: ApexYard · templates/architecture/c4-structurizr.dsl · github.com/me2resh/apexyard · MIT
//
// C4 escape hatch — Structurizr DSL. Use this ONLY when Mermaid C4
// (c4-context.md / c4-container.md) hits its ceiling:
//
//   - You need L3 (Component) precision inside one or more containers
//   - You want auto-zoom from ONE model to L1 -> L2 -> L3 views (Mermaid
//     requires hand-maintained, independently-drifting L1/L2/L3 files)
//   - You need proper Structurizr Workspace features — tags, per-view
//     styling, filtered views — that Mermaid's C4 support doesn't have
//
// Mermaid stays the DEFAULT for L1 + L2 (see c4-context.md / c4-container.md).
// This is a side-channel for projects that hit a wall, not a replacement.
// Decision rationale: docs/agdr/AgDR-0085-structurizr-dsl-escape-hatch.md
// (builds on the original tool choice in AgDR-0003).

workspace "{Project Name}" "One-sentence description of what the system does" {

    model {
        // --- People (same actors as c4-context.md's Person(...) lines) ---
        user  = person "User"  "The primary human actor — describe who this is"
        admin = person "Admin" "A privileged user — remove if you don't have one"

        // --- External systems (same as c4-context.md's System_Ext(...) lines) ---
        authProvider     = softwareSystem "Auth Provider"      "e.g. Auth0, Clerk, Supabase Auth" "External"
        paymentProcessor = softwareSystem "Payment Processor"  "e.g. Stripe, Paddle — remove if N/A" "External"
        emailProvider    = softwareSystem "Email Provider"     "e.g. Postmark, SES — remove if N/A" "External"

        // --- The system being modelled (same containers as c4-container.md) ---
        main = softwareSystem "{Project Name}" "One-sentence description of what the system does" {
            web = container "Web App" "Next.js / React" "Renders the UI, handles session state"

            api = container "API" "Node / Express (or your stack)" "Business logic, auth, orchestration" {
                // L3 (Component) — this is the level Mermaid can't express.
                // Auto-detection stops at L2 (containers); fill components in
                // by hand for whichever container needs the precision. Delete
                // this nested block for containers you don't want to zoom
                // into — a component-less container still renders fine at L2.
                authController = component "Auth Controller" "Express router" "Handles login / session endpoints"
                orderService   = component "Order Service"   "Domain service" "Order placement + fulfillment logic"
            }

            worker = container "Background Worker" "Node / BullMQ (or your stack)" "Async jobs — email, webhooks, ETL. Remove if synchronous-only."
            db     = container "Primary Database" "PostgreSQL" "Relational data" "Database"
            cache  = container "Cache" "Redis" "Session + hot lookups. Remove if not used." "Database"
        }

        // --- Relationships (same as c4-context.md / c4-container.md's Rel(...) lines) ---
        user  -> main "Uses" "HTTPS"
        admin -> main "Administers" "HTTPS"
        main -> authProvider     "Authenticates via"      "OAuth / OIDC"
        main -> paymentProcessor "Charges / webhooks"     "HTTPS + webhook"
        main -> emailProvider    "Sends transactional email" "SMTP / API"

        web -> api    "Calls"          "HTTPS / JSON"
        api -> db     "Reads / writes" "SQL"
        api -> cache  "Reads / writes" "TCP"
        api -> worker "Enqueues jobs"  "Redis / queue"
        worker -> emailProvider "Sends email"     "API"
        api    -> authProvider  "Validates tokens" "OIDC"

        // L3 relationship — inside the api container, between components.
        authController -> orderService "Delegates to" "In-process call"
    }

    views {
        // One model, three auto-generated zoom levels — the auto-zoom
        // Mermaid can't do (each Mermaid C4 file is hand-maintained and
        // independently drifts from the others).
        systemContext main "L1-SystemContext" {
            include *
            autoLayout
        }

        container main "L2-Containers" {
            include *
            autoLayout
        }

        component api "L3-APIComponents" {
            include *
            autoLayout
        }

        styles {
            element "Person" {
                shape Person
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Database" {
                shape Cylinder
            }
        }
    }

}
