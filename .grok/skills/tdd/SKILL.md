---
name: tdd
description: Run the strict hierarchical TDD workflow (Test Writer → Coder → Validator gate) using the 2026 scoped agentic pattern. Loops on real test + coverage feedback until green + 100% coverage. Writes checkpoints to agent_logs/. Use for features where you want testing to drive implementation.
when-to-use: Any non-trivial change where you want explicit Red-Green-Refactor with coverage gate. Supports "trivial: true" for very small things. Prefer this or bundled /implement over the old flat pipeline for quality.
user-invocable: true
---

# TDD Skill — Hierarchical 3-Action Workflow

This skill turns the lead (ideally using the `tdd-orchestrator` persona) into a **TDD Workflow Agent** that follows the architecture we set up:
- Orchestrator owns state + loop (thin).
- Delegates to the 3 core specialized actions (see `.grok/docs/tdd-3-actions.md`).
- Every handoff is **scoped** (failing tests + diff + summaries).
- Validator JSON is the source of truth for iteration.
- Everything lands in git + `agent_logs/<run-id>/`.

## The 3 Core Actions (reference)

1. **Test Writer** (`test-writer` persona) — Red: produce failing tests + JSON.
2. **Coder** (`coder` persona) — Green: minimal code to pass the tests + JSON.
3. **Validator** (`validator` persona) — Gate: run tests + coverage, emit strict JSON decision, force TestBackend for UI.

Reviewers (security/correctness) are selective and always diff-only.

Full role details, input/output contracts, and JSON schemas live in `.grok/docs/tdd-3-actions.md`.

## Prerequisites
- Read AGENTS.md (TDD section) and `.grok/docs/tdd-3-actions.md`.
- Current personas must be present: `tdd-orchestrator.toml` (recommended for the lead role), `test-writer.toml`, `coder.toml`, `validator.toml`.
- For best results, run the lead using the `tdd-orchestrator` persona when the system supports per-persona assignment for the main session.
- Always `julia --project=.` for all execution.
- `todo_write` is your primary state machine.

## Invocation
```
/tdd Add a status filter dropdown to the metrics table with full TestBackend coverage

/tdd trivial: true Fix a small label
```

The rest of the text is the task.

## Detailed Flow (Orchestrator Steps)

### 0. Setup
- Generate a short `RUN_ID` (uuid slice or timestamp).
- Create `agent_logs/<RUN_ID>/`
- Write initial `tdd-plan.json` or markdown summary of the task + acceptance criteria + coverage target (100%).
- `todo_write` with canonical phases:
  - setup
  - red (test-writer)
  - green-N (coder + validator attempts)
  - review (if triggered)
  - checkpoint
  - finalize

### 1. Plan (light, or reuse existing plan.md)
If no good plan exists, spawn a quick planner or do it yourself concisely:
- Break task into ordered sub-tasks.
- Define test strategy and coverage goals.
- Write `agent_logs/<RUN_ID>/plan.md` (short).

### 2. Red Phase — Spawn Test Writer
```
spawn_subagent:
  prompt: |
    <full instructions or reference to .grok/personas/test-writer.toml>

    Current task: <task>
    Relevant plan excerpt: ...
    Previous coverage gaps (if any): ...

    Follow the Test Writer contract exactly (see tdd-3-actions.md).
    Output only the diff + JSON summary.
  subagent_type: general-purpose
  description: "[test-writer] Red phase for <task>"
  capability_mode: all   # or read + edit in test dir
  cwd: <current>
```

- Save the diff it produced.
- Write `checkpoint-red.md` + append to `state.json`.
- Update todo.

### 3. Green Phase Loop — Coder + Validator
While not (tests_passed && coverage >= 100):

**a. Coder**
Use the latest failing tests + previous diff + validator feedback.
Spawn with strong scoping instructions.

```
spawn_subagent:
  prompt: |
    You are the Coder (TDD Green).

    Scoped input only:
    - Failing tests: <paste the key failing tests or point to file>
    - Recent diff: <unified diff or "see changes since last checkpoint">
    - Plan excerpt + current checkpoint summary

    Write the MINIMAL code to make these tests pass.
    Output diff + the required JSON (see tdd-3-actions.md).
    Then hand off.
  ...
  description: "[coder] Green attempt N"
  capability_mode: all
```

**b. Validator**
Spawn validator with execute capability.

```
spawn_subagent:
  prompt: |
    You are the Validator (TDD gate).

    Run the relevant tests + coverage.
    For any UI: drive TestBackend and assert.

    Return the EXACT JSON gate + commands + concise evidence.
    (See validator persona + tdd-3-actions.md)
  subagent_type: general-purpose
  description: "[validator] Gate after coder N"
  capability_mode: execute
```

- Parse (or copy) the JSON.
- If green + >=100%: break.
- Else: feed the `failing_tests`, `coverage_gaps`, `recommendations` back to next coder (or test-writer if tests need augmentation).
- Write `checkpoint-green-N.md` and update `state.json` after every attempt.
- Limit: reasonable max attempts (default 5), then summarize and escalate.

### 4. Refactor (optional)
Only after green + coverage gate.
Orchestrator can decide to allow a small scoped refactor pass (still against the same tests).

### 5. Selective Review (optional but recommended for anything non-trivial)
If changes are significant:
- Run `git diff` (or the range since last checkpoint).
- Spawn 1-2 reviewers in parallel with **only** the diff + passing tests + guidelines.
- Use the `reviewer` persona.

### 6. Checkpoints & Finalize
After every major transition (and on success):
- Write a short `checkpoint-<phase>.md` in the run dir (what happened, decisions, open items, HEHS if tracked).
- Update a `state.json`.
- At end: write `final-summary.md` + ensure `validation-evidence.md` style report lives in the run dir or root.

Always leave artifacts that a future human or agent can resume from with minimal context.

## Efficiency & Scoping Rules (enforce on every spawn)
- Never paste full previous conversation or entire files.
- Tell every subagent: "Read plan.md / agent_logs/<RUN_ID>/checkpoint-*.md and the relevant test files from disk."
- Prefer unified diffs for code/test handoff.
- Use `todo_write` frequently.
- `isolation: "worktree"` for risky coder attempts when supported.

## Julia + Tachikoma Enforcement
- Every validator step must use `julia --project=.`
- UI changes require real TestBackend execution in the validator report.
- Coverage >= 100% on changed code is the gate (use coverage=true or Coverage.jl).

## Output at End
Return:
- Status (success / needs-human)
- RUN_ID and location of `agent_logs/<RUN_ID>/`
- Final validator JSON
- Summary of files changed
- Suggested next (commit, review, more work)

## Relationship to Other Skills
- This is the **testing-driven** path.
- For larger work you can still start with `/design` then feed the PR plan into this skill or `/execute-plan` with extra TDD instructions.
- The old `/pipeline` is being phased toward this pattern.

See also:
- `.grok/docs/tdd-3-actions.md` (the contract for the three actions)
- `.grok/docs/tdd-workflow.md`
- AGENTS.md (TDD Orchestration section)
- The `test-writer`, `coder`, and `validator` personas

Use this skill when you want the tests (and coverage) to be the driver instead of the lead guessing at implementation.
