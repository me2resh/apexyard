# Getting Started with ApexStack

Short version of the setup flow. For the full walkthrough (directory layout, daily workflow, upgrade path, FAQ) see [`multi-project.md`](multi-project.md).

---

## Prerequisites

- A GitHub account and an org you can fork into
- [Claude Code](https://claude.com/claude-code) installed
- [GitHub CLI (`gh`)](https://cli.github.com) installed (optional but recommended)
- Basic familiarity with Claude Code's `CLAUDE.md` system

---

## Step 1: Fork apexstack on GitHub

Your ops repo **is** a fork of apexstack. One repo, no nested installs.

Visit [`github.com/me2resh/apexstack`](https://github.com/me2resh/apexstack), **Star** it, then **Fork** it into your org. Rename the fork if you want (`your-org/ops`, `your-org/apex`, or keep it as `apexstack` — GitHub handles the rename cleanly).

Then clone your fork locally:

```bash
gh repo fork me2resh/apexstack --clone
cd apexstack
```

Or with plain git:

```bash
git clone https://github.com/your-org/apexstack.git
cd apexstack
```

Add the upstream remote so you can pull future updates:

```bash
git remote add upstream https://github.com/me2resh/apexstack.git
```

Later, `git fetch upstream && git merge upstream/main` pulls the latest apexstack improvements into your fork.

---

## Step 2: Configure for Your Team

Edit `onboarding.yaml` with your company details:

```yaml
company:
  name: "Acme Corp"
  mission: "Making widgets simple"

team:
  - name: "Alice"
    role: "tech-lead"
    department: "engineering"
  - name: "Bob"
    role: "backend-engineer"
    department: "engineering"
  - name: "Charlie"
    role: "product-manager"
    department: "product"

tech_stack:
  language: "TypeScript"
  framework: "Next.js"
  database: "PostgreSQL"
  hosting: "Vercel"
```

---

## Step 3: Create the portfolio registry

Copy the example registry and list every repo you want under management:

```bash
cp apexstack.projects.yaml.example apexstack.projects.yaml
$EDITOR apexstack.projects.yaml
```

The minimal entry is:

```yaml
version: 1
projects:
  - name: example-app
    repo: your-org/example-app
    docs: projects/example-app
    status: active
```

Even if you have just one repo, register it — the skills work the same whether you have 1 or 20.

The `CLAUDE.md` at the root of your fork is the stack entry point. Claude Code reads it automatically when you start a session inside the fork — no additional wiring needed.

---

## Step 4: Start Using It

### Ask Claude Code to act as a role

```
Review this PR as the QA Engineer
```

```
As the Security Auditor, check this code for vulnerabilities
```

### Use the workflow

```
I'm starting work on ticket #42. Walk me through the SDLC process.
```

### Generate documents from templates

```
Create a PRD for the user authentication feature
```

```
Write a technical design for the payment processing system
```

### Record decisions

```
I need to decide between PostgreSQL and DynamoDB for this service.
Create an AgDR.
```

---

## Customization

### Adding a Custom Role

Create a new file in `roles/your-department/your-role.md`:

```markdown
# Role: [Role Name]

## Identity
You are a [Role Name]. You [primary responsibility].

## Responsibilities
- [Responsibility 1]
- [Responsibility 2]

## Capabilities

### CAN Do
- [Capability 1]

### CANNOT Do
- [Limitation 1]

## Interfaces
| Direction | Role | Interaction |
|-----------|------|-------------|
| Reports to | [Role] | [How] |

## Escalate When
- [Condition 1]
```

### Modifying a Workflow

Edit files in `workflows/` to match your team's process. For example, if you don't have a separate QA phase, remove it from `workflows/sdlc.md`.

### Adding a Template

Drop new markdown templates in `templates/` and reference them in `CLAUDE.md`.

---

## What to Expect

After setup, Claude Code will:

1. **Understand your team structure** -- It knows who does what
2. **Follow your SDLC** -- It enforces workflow gates
3. **Use your standards** -- Code reviews follow the defined checklist
4. **Generate structured docs** -- PRDs, tech designs, ADRs from templates
5. **Track decisions** -- Agent Decision Records for technical choices

---

## Troubleshooting

### Claude Code doesn't seem to know about the stack

Make sure you're running Claude Code from inside your fork of apexstack (the ops repo). Claude Code reads `CLAUDE.md` automatically from the working directory's root — if you're one level deep (e.g. inside `workspace/<project>/`) it picks up the project's own `CLAUDE.md` instead.

### Roles aren't being applied correctly

Check that the role file exists in the expected path under `roles/`.

### Workflows feel too heavy for my team

Customize! Edit `onboarding.yaml` to disable stages:

```yaml
workflows:
  require_prd: false
  require_technical_design: false
  require_qa_signoff: false
```

---

## Next Steps

- Browse the [roles](../roles/) to see all available role definitions
- Read the [workflows](../workflows/) to understand the development process
- Check the [templates](../templates/) for document formats
- Star the [GitHub repo](https://github.com/me2resh/apexstack) for updates
