<!-- Source: ApexYard · templates/tickets/migration.md · github.com/me2resh/apexyard · MIT -->

**[Migration] {{type}}: {{summary}}**

## Migration

**Type**: {{type}}
**Affected tables/entities**: {{affected_tables}}
**Estimated downtime**: {{downtime_level}} — {{downtime_reasoning}}
**Data volume**: {{data_volume}}
**Priority**: {{priority}}

## Rollback Plan

{{rollback_plan}}

**Tested against**: {{rollback_tested_against}}

## Cross-Service Consumers

{{cross_service_consumers}}

**Deploy-order constraint**: {{deploy_order_constraint}}

## Testing Plan

- Dev smoke: {{dev_smoke}}
- Staging verify: {{staging_verify}}
- Canary / phased rollout: {{canary_plan}}

## Observability

{{observability}}

## Agent Decision Record

Migration AgDR: `{{agdr_path}}`

## Glossary

| Term | Definition |
|------|------------|
| {{glossary_term_1}} | {{glossary_definition_1}} |

---

Created by `/migration`. Do not edit the labels off this issue — the
migration-gate hook (`require-migration-ticket.sh`) verifies the
`migration` label is present before allowing edits to migration files.
