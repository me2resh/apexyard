# Deployment Process

How code moves from development to production.

## Roles

Deployment is a **role-activated** workflow. Roles activate automatically per [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md).

| Stage | Primary role | Trigger |
|-------|--------------|---------|
| CI/CD pipeline design and maintenance | [Platform Engineer](../roles/engineering/platform-engineer.md) | CI/CD config changes, pipeline failures, golden-path updates |
| Staging deployment | [Platform Engineer](../roles/engineering/platform-engineer.md) | Push to `main` auto-triggers |
| Production promotion gate | [Platform Engineer](../roles/engineering/platform-engineer.md) + [Head of Engineering](../roles/engineering/head-of-engineering.md) sign-off for risky changes | Manual after QA sign-off |
| Incident response / rollback | [SRE](../roles/engineering/sre.md) | SLO breach, error-rate spike, P1 incident |
| Post-deploy monitoring (first 24-48h) | [SRE](../roles/engineering/sre.md) | Production deploy completed |
| Security review gate (if required) | [Security Auditor](../roles/security/security-auditor.md) | Auth / crypto / secrets / PII in the diff |

---

## Deployment Flow

```
Push to main
    |
    v
CI/CD triggers
    |
    v
Authenticate with cloud provider
    |
    v
Apply infrastructure changes (IaC)
    |
    v
Build application
    |
    v
Deploy to staging
    |
    v
Run smoke tests
    |
    v
Deploy to production (manual gate)
    |
    v
Verify and monitor
```

---

## Environments

| Environment | Purpose | Deploy Trigger |
|-------------|---------|----------------|
| Development | Local testing | Manual |
| Staging | Pre-production verification | Push to main (auto) |
| Production | Live users | Manual approval |

---

## CI/CD Pipeline Stages

### 1. Build
- Install dependencies
- Compile/transpile code
- Lint check

### 2. Test
- Unit tests
- Integration tests
- Coverage report (must be >80%)

### 3. Security
- Dependency audit
- Static analysis scan

### 4. Deploy to Staging
- Apply infrastructure changes
- Deploy application
- Run E2E tests

### 5. Deploy to Production (Manual Gate)
- Apply infrastructure changes
- Deploy application
- Run smoke tests
- Rollback on failure

---

## Pre-Deploy Checklist

Before deploying to production:

- [ ] All tests passing
- [ ] QA sign-off received
- [ ] Security review passed (if required)
- [ ] Feature flags configured (if applicable)
- [ ] Rollback plan documented
- [ ] Monitoring and alerts in place
- [ ] On-call team aware
- [ ] Database migrations tested

---

## Infrastructure as Code

All infrastructure changes must be:

1. **Defined in code** -- No manual console changes
2. **Version controlled** -- In the same repo as application code
3. **Reviewed** -- Through the same PR process
4. **Tested** -- In staging before production

### Project Structure

```
project/
├── app/                  # Application code
├── infra/                # Infrastructure as code
│   ├── main.tf          # (or equivalent for your IaC tool)
│   └── .gitignore
└── docs/
```

---

## Rollback

### Quick Rollback (Code)

```bash
# Revert the commit
git revert HEAD
git push origin main
# Auto-deploys to staging, then promote to production
```

### Infrastructure Rollback

```bash
# Apply previous known-good state
# Use your IaC tool's rollback mechanism
```

### When to Rollback

- Error rate spikes above threshold
- P1 incident caused by deployment
- Critical functionality broken
- Data corruption detected

### Rollback Decision Tree

```
Is the issue affecting users?
  YES --> Is there a quick fix (<15 min)?
    YES --> Apply hotfix
    NO  --> Rollback immediately
  NO  --> Is it degrading performance?
    YES --> Rollback within 1 hour
    NO  --> Fix in next deploy
```

---

## Environment Promotion

| From | To | Method |
|------|----|--------|
| Local | Staging | Push to main |
| Staging | Production | Manual trigger after verification |

### Production Deploy Approval

Before promoting to production:

1. Staging has been tested
2. QA has signed off
3. No open P1/P2 bugs
4. Team is available to monitor
5. It's not Friday afternoon (unless critical)

---

## Monitoring Post-Deploy

### First 30 Minutes
- Watch error rates
- Check response times
- Verify key user flows
- Monitor resource utilization

### First 24 Hours
- Compare metrics to pre-deploy baseline
- Check for gradual degradation
- Review user feedback channels
- Verify background jobs running correctly

### Alerts to Have

| Alert | Threshold | Action |
|-------|-----------|--------|
| Error rate | > 1% | Investigate immediately |
| Latency p99 | > 2s | Investigate |
| CPU/Memory | > 80% | Scale or optimize |
| Failed health checks | Any | Auto-rollback or page on-call |
