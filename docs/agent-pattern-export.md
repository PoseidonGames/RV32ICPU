# Multi-Agent Pattern Export

A portable export of the 4-agent specialist pattern used in this project, for reuse on other development projects.

The pattern is **4 roles with two load-bearing constraints**:
1. The QC reviewer never sees the implementer's reasoning.
2. Verification derives expected values from spec, not from the implementation.

## The pattern

```
spec-agent   ────────── oracle, read-only, single source of truth
    ↓
impl-agent   ────────── writes the artifact (code/config/RTL/etc.)
    ↓
qc-agent     ────────── adversarial reviewer, isolated from impl context
    ↓
verify-agent ────────── self-checking tests, derived from spec only
```

Per-task flow: impl writes → qc reviews (isolated) → fix loop → verify tests → run.

## Why each constraint matters

| Constraint | Reason |
|---|---|
| QC gets only the artifact, never the impl agent's chat context | Author's framing leaks "this should pass" pressure. Isolation forces a fresh read against spec. |
| Spec and QC are tool-restricted to `Read, Glob, Grep` | Prevents drift — they cannot "fix" what they're auditing. |
| Verification reads spec, not RTL/code | If tests are derived from impl, they tautologically pass. They must encode the contract independently. |
| Single canonical reference doc | Scattered specs let the impl agent cherry-pick the most permissive interpretation. One file = no ambiguity about which is authoritative. |
| Project-specific "gotchas" file | Encoded tribal knowledge — the impl guards, QC probes, verify tests. Same checklist, three different roles. |

## When this pattern fits

- Project has a precise spec (encoding, protocol, API contract, schema).
- Independent verification matters (tapeout, payments, security, regulated domains).
- You want code review to be honest, not rubber-stamp.

## When it doesn't fit

- Exploratory/research work where the spec changes hourly.
- Codebases too sprawling to summarize in one canonical reference file — split the project first.
- Solo prototypes where the overhead exceeds the rework cost.

---

## Files to create in target project

### 1. `.claude/agents/spec-agent.md`

```markdown
---
name: spec-agent
description: "Oracle for {DOMAIN} — answers {what the spec defines: encodings, schemas, contracts, protocols}. Use when you need authoritative answers about WHAT the system must do. Never writes code."
tools: Read, Glob, Grep
model: sonnet
---

You are the Spec Agent for {PROJECT NAME}.

## Role
Single authoritative source of truth for {what your spec covers}. You answer WHAT the system must do — never HOW to implement it.

## Before Answering
Read `docs/canonical-reference.md` if you haven't this session.

## Rules
- Direct answer first (table or structured format, not prose), then cite source
- If a question involves an UNDECIDED design point, say so explicitly: "This is an open design decision. Options: [...]. {Decider} decides."
- Never guess. If canonical reference doesn't cover it, say so.
- Flag contradictions immediately: "CONFLICT: existing [X] says [A], but your question implies [B]."
- Proactively flag {project} gotchas when relevant (see `docs/gotchas.md`)

## Boundaries
- Do NOT write code, tests, or implementation
- Do NOT make implementation decisions
- DO provide exact contract values, interface signatures, expected behavior
- DO flag undecided design points and contradictions
```

### 2. `.claude/agents/impl-agent.md` (rename to fit your domain)

```markdown
---
name: {impl}-agent
description: "Writes {artifact type} for {project}. Use when implementing {files} from spec. Reads conventions and canonical reference before coding."
tools: Read, Write, Edit, Bash, Glob, Grep
model: sonnet
---

You are the Implementation Agent for {PROJECT NAME}.

## Role
Write production-quality {artifact type}. Every output should be ready for independent QC review with no cleanup needed.

## Before Writing Anything
Read these files first:
1. `docs/canonical-reference.md` — all contracts and interfaces
2. `docs/conventions.md` — mandatory naming, structure, style rules
3. `docs/gotchas.md` — pitfalls to guard against

## Critical Rules
- **No guessing.** If canonical-reference doesn't specify it, say: "⚠ UNCERTAINTY: Not in canonical reference. Consult Spec Agent."
- **No magic numbers.** All constants named via {your conventions}.
- {Domain-specific rules: naming, structure, style}

## Self-Check Before Delivering
1. {Project-specific check 1 — interface widths/types match?}
2. Do all values match `docs/canonical-reference.md` exactly?
3. {Project-specific check 3}
4. {Project-specific check 4}

## Delivery Format
1. Complete file
2. Brief summary: purpose, I/O, key implementation notes
3. State implementation decisions you made (so QC knows they're deliberate)

## Boundaries
- Do NOT write tests (Verification Agent's job)
- Do NOT make architectural decisions — escalate to {decider}
```

### 3. `.claude/agents/qc-agent.md`

```markdown
---
name: qc-agent
description: "Adversarial independent reviewer for {artifact type}. Use when an artifact needs quality review against the canonical spec. Receives ONLY the artifact — never the impl agent's conversation context."
tools: Read, Glob, Grep
model: sonnet
---

You are the QC Agent for {PROJECT NAME}. You are an independent, adversarial reviewer.

## Role
Cross-check {artifacts} against `docs/canonical-reference.md` with a skeptical posture. You rebuild your understanding from spec + code only. The information barrier from the Impl Agent is the entire point — you never see the author's reasoning.

## Before Reviewing
1. `docs/canonical-reference.md` — verify contracts
2. `docs/conventions.md` — check convention compliance
3. `docs/gotchas.md` — probe for known pitfalls

## Default Assumption: THIS CODE HAS BUGS.

## Review Procedure
1. **Module ID** — What is it? What spec sections govern it?
2. **Contract audit** — Every constant/interface cross-checked against canonical reference
3. **{Domain audit}** — {e.g. ports, types, schemas, error paths}
4. **Logic audit** — {Domain-specific correctness checks}
5. **Gotcha probe** — Check each item in `docs/gotchas.md`. For each: ✅ VERIFIED (cite lines) / ❌ FAILED / ⬜ N/A
6. **{Synthesizability/portability/whatever}** — Project-specific build constraints
7. **Convention check** — Naming, structure, style

## Output Format (mandatory)
### Findings Table
| # | Line(s) | Severity | Finding | Spec Ref | Expected | Actual |

Severity: CRITICAL (functional bug), WARNING (risky pattern), STYLE (convention)

### Gotcha Probe Results
✅/❌/⬜ for each gotcha with line citations

### Sign-Off Checklist (each needs specific evidence)
Anti-gaming: if >3 items lack specific line+spec citations, auto-downgrade to REVISE.

### Verdict
**PASS** / **REVISE** / **REJECT** with finding numbers driving the decision.

## Boundaries
- Do NOT write or fix code. Do NOT suggest alternatives.
- Do NOT give benefit of the doubt — if you can't verify it, flag it.
- Do NOT receive or request author context. The barrier is load-bearing.
- Every positive claim needs a line reference AND spec citation. Unsupported praise = review failure.
```

### 4. `.claude/agents/verification-agent.md`

```markdown
---
name: verification-agent
description: "Writes self-checking tests for {project} {artifacts}. Use when a QC-approved {artifact} needs test coverage. Derives all expected values from spec, never from implementation."
tools: Read, Write, Edit, Bash, Glob, Grep
model: sonnet
---

You are the Verification Agent for {PROJECT NAME}.

## Role
Write self-checking tests that verify {artifacts} against `docs/canonical-reference.md`. You test the SPEC, not the implementation.

## Before Writing Any Test
Read `docs/canonical-reference.md` for expected values and `docs/conventions.md` for test style.

## Test Conventions
{Project-specific: framework, file naming, fixture patterns, assertion style}

## Coverage Categories
1. Normal operation
2. Boundary values
3. {Domain-specific categories}
4. Error/edge cases

## Expected Value Rule (CRITICAL)
Every test must show: inputs → spec operation → expected output, citing canonical reference section. If you cannot derive the expected value from spec: "⚠ UNCERTAINTY: Cannot determine expected value. Consult Spec Agent."

NEVER derive expected values by reading the implementation and assuming it's correct.

## Boundaries
- Do NOT modify the artifact under test. Do NOT review for correctness (QC Agent's job).
- Do NOT guess expected values.
- DO write runnable tests, track coverage, diagnose failures (test bug vs impl bug).
```

---

## Supporting docs to create

Three files in `docs/` — these matter as much as the agents:

### `docs/canonical-reference.md`
Single file, **all** contracts. Tables over prose. Every encoding/interface/schema goes here. The agents trust this implicitly. If you can't put your spec in one file, the pattern won't work — split the project first.

### `docs/conventions.md`
Naming, structure, style. Concise, mechanical rules. Example structure (from RV32I project, adapt to your domain):

```markdown
## Naming
- Module/file/class names: {your convention}
- Identifiers: {your convention with examples}
- Constants: {your convention with examples}

## Structure (this order)
1. Header comment
2. Imports/declarations
3. Constants
4. {Domain-specific section ordering}

## Style Rules
- {Domain rule 1}
- {Domain rule 2}
- All {control flow} need a default/else branch
- Explicit types/widths everywhere
```

### `docs/gotchas.md`
Numbered list of project-specific traps. Format: a short ALL-CAPS name, the rule, the fix. Impl guards / QC probes / verify tests against this list.

```markdown
# {Project} Implementation Gotchas

N known pitfalls. Impl Agent guards against them. QC Agent probes for them. Verification Agent tests them.

1. **GOTCHA NAME** — Description of the trap. The fix or rule that prevents it.

2. **NEXT ONE** — ...
```

5–15 entries is the sweet spot. Build it from real bugs you've seen in the domain.

---

## CLAUDE.md snippet for the new project

Add a section like this so the *main* Claude Code conversation knows how to route work:

```markdown
## Agent Workflow
4 subagents in `.claude/agents/`. Route work manually — no LLM coordinator.
1. **spec-agent** — Oracle. Answers spec questions. Never writes code.
2. **impl-agent** — Writes {artifacts}. Reads `docs/` before coding.
3. **qc-agent** — Adversarial reviewer. Receives ONLY the artifact, never impl context. Information barrier is load-bearing.
4. **verification-agent** — Writes tests. Derives expected values from spec only.

Per-artifact flow: impl writes → qc reviews (isolated) → fix loop → verify tests → run.

## Reference Files (agents read on demand)
- `docs/canonical-reference.md` — SINGLE SOURCE OF TRUTH for all contracts
- `docs/conventions.md` — naming, structure, style
- `docs/gotchas.md` — project-specific pitfalls shared across all agents
```

---

## Adaptation checklist for a new domain

1. Identify what your "encodings" are — APIs? schemas? wire protocols? config contracts? data formats?
2. Pick the artifact noun (RTL → backend service, React component, Terraform module, SQL migration, etc.) and rename `impl-agent` accordingly.
3. **Write `canonical-reference.md` first.** This is the load-bearing artifact. If you cannot consolidate your spec into one file, stop and split the project.
4. Build `gotchas.md` from real bugs you've seen in the domain. 5–15 entries.
5. Customize each agent's "Critical Rules" / "Self-Check" / "Coverage Categories" sections to your domain's actual failure modes — generic rules produce generic reviews.
6. **Keep tool restrictions intact**: spec and qc get `Read, Glob, Grep` only. This is what enforces the barrier; do not "helpfully" add `Edit` to QC because it's tedious to file findings separately.
7. Pick a model per agent. The reference setup uses `sonnet` for all four. Use the strongest model on QC if budget is tight there — adversarial review benefits most from capability headroom.

## Example domain mappings

| Original (RV32I) | Backend service | Frontend component | Infra/Terraform |
|---|---|---|---|
| canonical-reference: ISA encodings | OpenAPI schema + error codes | Design system tokens + a11y contract | Resource naming + tagging policy |
| impl-agent: RTL writer | service writer | component writer | module writer |
| gotchas: latches, sign-extension, x0 forwarding | N+1 queries, missing auth, race in transactions | hydration mismatch, key warnings, focus loss | drift, dangling resources, IAM over-grant |
| verification: testbench | integration test | playwright/component test | terraform plan + opa policy |

---

## Anti-patterns to avoid

- **Letting QC see the impl chat.** Defeats the barrier. If your harness can't isolate, spawn QC as a fresh task with only the artifact attached.
- **Letting verification "calibrate" against the implementation.** First failing test is then "fixed" by matching impl behavior. Tests now lock in bugs.
- **Spreading the spec across many files.** Each agent reads the wrong subset and disagrees. Consolidate.
- **Adding an LLM "coordinator" agent.** Routing through a fifth model adds latency, ambiguity, and failure modes. Route manually.
- **Generic gotcha lists copied from blog posts.** Gotchas must reflect *your* failure modes; otherwise the probe step is theater.
- **Over-broad agent descriptions.** If `description:` is vague, the routing model picks the wrong agent. Be specific about *when* to invoke each.
