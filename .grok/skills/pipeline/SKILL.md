---
name: pipeline
description: Run the structured Plan → Scout → Implement/Validate loop → Review pipeline (Grok-native version of the original .claude/workflows/pipeline.js). Use for any non-trivial change.
when-to-use: Any PR-bound or important change. Pass the task description after the slash. Supports trivial: true to skip plan/scout.
user-invocable: true
---

# Pipeline Skill — Grok Native (Plan → Scout → Loop → Review)

This skill encodes the deterministic quality pipeline from the fab-ui-2-0 Claude setup, adapted for Grok's `spawn_subagent`, personas, capability modes, and model routing.

**Goal**: Every meaningful change goes through Plan (if needed) → Scout → (Implement ↔ Validate) → 3-lens Review with evidence. No yolo edits.

## Prerequisites (always)
- Read `AGENTS.md` and relevant personas first.
- Current model routing (via `.grok/config.toml`):
  - `grok-build`: lead + heavy work (coder, validator, complex planner)
  - `grok-composer-2.5-fast`: fast/light roles (scout/explore, reviewer, simple plan)
- Use personas for consistent behavior: `planner`, `scout`, `coder`, `validator`, `reviewer`.
- Demand **high-signal evidence** (see token-efficiency.md):
- Validator: report exact command + exit_code + concise evidence (key lines or errors; full tail only on failures or "all pass" claims).
- Reviewers: quote verbatim from actual files/diffs.
- Re-audit on success claims remains mandatory.
- Lead produces Phase Summaries after major stages and writes them + key artifacts to the working directory.

## Invocation
```
/pipeline Add user status filter dropdown to equipment table

/pipeline trivial: true Fix typo in button label
```

Args parsed from text after `/pipeline`:
- `trivial: true` → skip Plan + Scout (for tiny mechanical changes)
- `maxAttempts: N` (default 4)
- Otherwise the whole string is the `task`.

## Detailed Phases & Spawn Patterns

### Phase 1: Plan (skip if trivial)
Use the `planner` persona + `plan` subagent_type (read-only).

```
spawn_subagent with:
  prompt: |
    Plan this change: <task>
    Read AGENTS.md and project rules first.
    Produce a detailed phased implementation plan with:
    - exact file paths (relative or absolute)
    - specific changes per phase
    - DB / API / frontend impact
    - testing strategy + required new tests
    - risks and edge cases
    Output in the structured plan format from the planner persona.
  subagent_type: plan
  description: "Create implementation plan"
  capability_mode: read-only
  # model will be routed per config / persona
```

Store the returned plan text for the next phases.

**Immediately after receiving the plan**, the lead must:
- Write `plan.md` (or update it) in the target working directory.
- Produce a short "Plan Summary" (what the phases achieve, key risks, main files) and store it (e.g. as comment or separate summary file).

### Phase 2: Scout (skip if trivial)
Use `scout` persona + `explore` subagent_type on fast model.

```
spawn_subagent with:
  prompt: |
    Gather implementation context for: <task>
    Plan (if any): <plan>
    Focus on: existing patterns (with file:line + snippets), similar prior code, conventions from AGENTS.md, exact signatures/types.
    Be comprehensive so the coder needs no further exploration.
    Return a structured Scout Report.
  subagent_type: explore
  description: "Scout context and patterns"
  capability_mode: read-only
```

**Immediately after the scout**, the lead must:
- Write `scout-report.md` (compact version) to the target directory.
- Create a short Scout Summary (key patterns + file:line only) for subsequent prompts.

### Phase 3: Implement ↔ Validate Loop (mandatory)
Max attempts default 4.

For each attempt:

**Coder** (write-capable, mercury-2 high reasoning):
```
spawn_subagent with:
  prompt: |
    You are the Coder persona (mercury-2, reasoning_effort=high).

    Task: <task>
    Relevant Plan: See plan.md (focus on the phases for this attempt)
    Phase Summary (previous work): <short lead-produced summary or reference to *-summary.md>
    Scout Highlights: key patterns from scout-report.md (use file:line references)

    Rules (from persona):
    - Implement ONLY the current scope from the plan.
    - Read plan.md / summaries / scout-report.md from the working directory when available.
    - Do NOT paste the full previous plan, full scout report, or large previous code blocks unless you are directly editing them.
    - Prefer `git diff` or small targeted excerpts when discussing changes.
    - Follow AGENTS.md + token-efficiency.md conventions.
    - If .ts/.js: run typecheck yourself before handing off.
    - Work in the target directory (use cwd/isolation as provided).
    - End with "Implementation Complete" + list of files created/modified + brief summary of what changed.

    <previous feedback if any>
  subagent_type: general-purpose
  description: "Implement attempt N"
  capability_mode: all
  # isolation: "worktree" recommended for coder
  cwd: <target directory>
```

**Validator** (execute + evidence, grok-build):
```
spawn_subagent with:
  prompt: |
    You are the Validator persona.

    Validate the change just made for: <task>
    1. Run typecheck if TS/JS changed.
    2. Run targeted tests for the changed files/behavior.
    3. Add or update tests that cover the new behavior.
    4. For each command report: exact command, exit_code, and **concise evidence** (last 5-8 lines or the lines with errors/warnings).
       - Use full tail only for failures or when claiming "all pass".
    "No test needed" requires explicit written justification.
    Only report success if you actually ran the commands and they passed.

    After your report, the lead may trigger an evidence audit that re-runs the exact commands you listed.
  subagent_type: general-purpose
  description: "Validate attempt N"
  capability_mode: execute   # read + shell, no edits
```

After validator:
- If `all_pass` (from its report): run an **evidence audit** — spawn another validator-like subagent (or use background) to re-execute the exact commands listed and confirm exit codes == 0.
- If not all_pass or audit fails: extract failures, loop back to coder with feedback.
- After max attempts or success → proceed to review.

Use `todo_write` in the lead session to track attempt number and status.

### Phase 4: Review (3-lens panel + verification)
Spawn **three in parallel** using `reviewer` persona.

Lenses:
- security (SQL param, perms, secrets, etc.)
- correctness (logic, error handling, contracts)
- conventions (style, patterns from AGENTS.md)

Example for one (repeat for three, or use background + collect):

```
spawn_subagent with:
  prompt: |
    You are a Reviewer (lens: SECURITY).

    Review **only the diff and targeted files** for: <task>
    Relevant Plan excerpt: <short section>
    Review ONLY through the SECURITY lens.
    For every finding quote offending code VERBATIM from the actual modified file.
    Use severity: critical | warning | nit.
    Return structured findings.

    Prefer reading the actual `git diff` and changed files from disk (in the provided cwd) rather than relying on pasted full code.
  subagent_type: general-purpose
  description: "Security review"
  capability_mode: read-only
```

After getting the three:

- For any **critical/warning** findings: spawn additional "adversarial verifier" subagents (general-purpose, read-only) with instructions to refute the finding if possible (check evidence char-by-char, look for guards, re-derive, etc.).
- Require 2-of-3 confirmation before counting a finding as real.
- Collect confirmed vs refuted.

Lead summarizes:
- status: approved | changes-requested | failed-validation
- validation evidence
- confirmed findings
- nits

## Practical Tips in Grok

- Run subagents in **background: true** when doing parallel reviews or to keep lead responsive, then `get_command_or_subagent_output`.
- Use `isolation: "worktree"` (or explicit `cwd`) for coder attempts. Recommended spawn flags for light roles: `--no-memory --no-leader --disable-web-search`. See token-efficiency.md for full list of recommended practices.
- Use `parallel(...)` pattern in your thinking if multiple spawns at once.
- Pass **high-signal context only**: the task, relevant plan section(s), current phase summary (from lead), scout highlights (not the full report), and `git diff` when reviewing. Write artifacts (plan.md, *-summary.md, scout-report.md) to the target directory and tell subagents to read them from disk. See token-efficiency.md.
- The lead (you) is the orchestrator. Do not expect subagents to call spawn_subagent (depth limit = 1).
- For trivial changes: still require Coder + Validator + Reviewer.

## Output at End
Return a structured summary:
- status
- attempts used
- validation runs (commands + results)
- review results (lenses, confirmed findings with evidence)
- next actions if changes-requested

See the personas in `.grok/personas/` for exact behavioral contracts.

This replaces the old `pipeline.js` + named `agent()` calls with native Grok primitives.
