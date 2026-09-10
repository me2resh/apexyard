<!-- Source: ApexYard · templates/tickets/bug.md · github.com/me2resh/apexyard · MIT -->
<!--
Required: Bug Scenario, Repro Steps, Environment, Severity, Glossary.
Conditional: Mitigation, Investigation Notes.
Delete a conditional section that has no content. Do not write "N/A". Replace every {{placeholder}} or write TBD. Delete this comment before filing.
Rule: .claude/rules/writing-standard.md. Use the controlled technical writing profile. Use short complete sentences and active voice.
-->

**[{{severity}}] {{title}}**

## Bug Scenario

**Given** {{precondition}}
**When** {{action}}
**Then** {{unexpected_result}}
**Expected** {{correct_behavior}}

## Repro Steps

{{repro_steps}}

## Environment

{{environment}}

## Severity

{{severity_label}}

## Mitigation

{{mitigation}}

## Investigation Notes

{{investigation_notes}}

## Glossary

| Term | Definition |
|------|------------|
| {{glossary_term_1}} | {{glossary_definition_1}} |
