# Security Review — {project} @ {short-sha}

> Persisted by `/security-review` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. Edit the body freely; keep the frontmatter parseable. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

- Diff reviewed: `{branch}..main` ({N} files, {M} +/- lines)
- Review focus: code-class findings (auth, input validation, secrets handling, dependencies)
- Out of scope: architecture-level threat modelling — that belongs in `/threat-model`

## Findings

| # | Severity | OWASP class | Finding | File:Line | Status |
|---|---|---|---|---|---|
| F1 | critical | A03 Injection | (e.g. unsanitised user input concatenated into SQL) | `src/users.ts:42` | open |
| F2 | high | A07 Auth failure | (e.g. JWT signature not verified) | `src/auth.ts:18` | open |
| F3 | medium | A05 Misconfig | (e.g. CORS `Access-Control-Allow-Origin: *`) | `src/server.ts:8` | open |

## Dependency vulnerabilities

| Package | Current | Patched | Severity | Advisory |
|---|---|---|---|---|
| (e.g. axios) | 0.21.1 | 1.6.0 | high | CVE-XXXX-NNNN |

Run `npm audit` / `pip audit` and capture critical+high here.

## Secrets scan

- [ ] `.env*` files in repo? (`git ls-files | grep -E '^.env'`)
- [ ] API keys / tokens hardcoded? (`grep -rE '(api[_-]?key|secret|token)\s*[=:]\s*["'\'']'`)
- [ ] Cloud account IDs / ARNs in source?

## Recommendations

Order by severity:

1. F1 — fix injection vector before any new feature work
2. F2 — verify JWT signatures
3. (lower-severity items after)

## Notes

(Context: prior incidents in this area, why specific findings are higher-severity than they look, links to related AgDRs.)
