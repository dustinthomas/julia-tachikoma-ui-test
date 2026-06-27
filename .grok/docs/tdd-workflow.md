# TDD Workflow (Detailed)

This document + `tdd-3-actions.md` + the `tdd` skill define how to run strict hierarchical TDD.

## Invocation
```
/tdd <task description>   # e.g. "Add move-to-any-lane via picker modal (m key)"
/tdd trivial: true <small change>
```

The lead (you when using the skill, or the tdd-orchestrator persona) drives the entire process.

## State Machine (simplified)
Setup → Red → Green (loop) → Validate Gate → (on pass) Review (optional) → Final
On gate fail → decide (more Red or more Green) and loop

Use `todo_write` with clear phase ids.

## Step-by-Step

### 1. Setup Phase
- Read AGENTS.md, relevant plan/design if present, and Julia/Tachikoma rules.
- Decide on feature slug for logs: e.g. `2026-06-27-move-lane-tdd`
- `mkdir -p agent_logs/<slug>`
- Write initial plan (scoped phases) → `agent_logs/<slug>/plan.md` or `tdd-plan.json`
- Initialize `todo_write`:
  - setup
  - red
  - green-1, green-2, ...
  - validate
  - final
- Write `checkpoint-setup-plan.md`
- Record starting state in `state.json`

### 2. Red Phase (Action 1)
Spawn test-writer with narrow prompt:
"Write only failing tests for: <task>. Use TestBackend for all UI. Output diff + summary."

- Apply the tests (search_replace or write).
- Run targeted tests (expect red). Record evidence.
- Write `red-tests.diff` + `checkpoint-red.md` (what tests, why they fail, commands + output).
- Mark todo red complete, update state.

### 3. Green Phase (Action 2, repeatable)
For each green attempt:
- Prepare very narrow context: the exact failing tests + tiny relevant excerpt + "make these pass with minimal code".
- Spawn coder (or general-purpose with coder persona).
- Apply the resulting diff.
- Run tests (via validator or direct). Record.
- If green: write `coder-greenN.diff` + `checkpoint-greenN.md`
- If not: feed the exact failure back and loop (or decide more red needed).

Limit attempts. Prefer small focused greens.

### 4. Validate Gate (Action 3)
- Spawn validator with full instruction: run relevant tests + coverage on the changed areas.
- Require:
  - All targeted + relevant tests pass
  - Coverage >= 100% on touched logic (or justified)
  - For UI: TestBackend assertions exercised in the run
- Capture strict gate result + verbatim evidence.
- Write `checkpoint-validateN.md` + `validation-evidence.md`
- If gate not passed: orchestrator decides next action (more red/green) and loops with clear feedback.
- Only advance when gate is satisfied.

### 5. Post-Gate Polish / Review (optional)
- After gate is green, you may selectively run reviewer lenses on the final diffs.
- Only refactor after the gate is green (tests must stay green).

### 6. Final
- Write `final-summary.md` containing:
  - Original task
  - Phases + attempts
  - Key commands + results (with exit codes and concise evidence)
  - Coverage achieved
  - Files changed
  - Outstanding risks / follow-ups
  - Path to all artifacts
- Update `state.json` to completed.
- Return clear status to the caller.

## Checkpoint File Conventions
Keep them short and high-signal (use summaries per token-efficiency practices).

Example files produced during a real run:
- checkpoint-setup-plan.md
- checkpoint-red.md
- red-tests.diff
- checkpoint-green1.md
- coder-green1.diff
- checkpoint-validate1.md
- validation-evidence.md
- final-summary.md
- state.json

## Integration Notes
- When using with execute-plan, each PR can have its own agent_logs subdir or reuse a top-level one with subdirs per PR.
- The orchestrator can be the top-level lead in an execute-plan DAG step.
- Always leave the working tree in a clean, reproducible state (tests green when claiming success).

Follow this workflow for any work where you want ironclad TDD + coverage evidence.
