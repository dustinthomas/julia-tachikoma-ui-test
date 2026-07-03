---
name: tdd
description: Run the strict hierarchical TDD workflow (Test Writer → Coder → Validator gate) using the 2026 scoped agentic pattern. Loops on real test + coverage feedback until green + 100% coverage. Writes checkpoints to agent_logs/. Use when: Any non-trivial change where you want explicit Red-Green-Refactor with coverage gate. Supports "trivial: true" for very small things. Prefer this or bundled /implement for feature work requiring strong validation.
when-to-use: For non-trivial work requiring strict TDD red-first, coverage gates, and detailed checkpointing (especially UI or logic with TestBackend requirements). Use /tdd <task description>.
user-invocable: true
allowed-tools: run_terminal_command, read_file, grep, write, search_replace, todo_write, spawn_subagent
---

# TDD Skill — Hierarchical Red-Green-Refactor with Coverage Gate (2026 Pattern)

Strict Test-Driven Development orchestrator. The lead owns the TDD state machine and only delegates **scoped work** to specialized sub-agents. Never implement yourself as lead. Always produce artifacts in `agent_logs/<slug>/`.

**Primary invocation**
```
/tdd Add the ability for the user to move a task to any lane via picker (m key)

 /tdd trivial: true Small guard tweak
```

## Core Principles (non-negotiable)
- **Tests first (Red)**: Write failing tests that prove the gap before any production change.
- **Minimal to Green**: Coder receives *only* the failing tests + scoped context and writes the smallest code to make them pass.
- **Coverage gate**: 100% coverage on changed logic/UI (Julia coverage + Tachikoma.TestBackend assertions). Validator emits strict gate JSON.
- **Checkpoints & state**: After every major phase the lead writes concise checkpoint + updates state in `agent_logs/`.
- **Evidence only**: Validator and lead only claim green after real `julia --project=.` runs + re-auditable output.
- **UI rule**: Every interactive or view change **must** follow the full Tachikoma UI Testing Methodology in `.grok/docs/tachikoma-ui-testing.md`:
  Use `TestBackend` + `find_text`/`row_text`/`char_at` + `visual_rows` + re-render after `update!`. Gate tests start from raw model. No-bleed checks required for modals.

## Roles (use these personas)
- `tdd-orchestrator` (grok-build): You. Owns goal, TDD loop (Red → Green → gate), `todo_write`, checkpoint writing, final summary. Delegates only.
- `test-writer` (fast): Produces **failing tests only**.
- `coder` (grok-composer-2.5-fast native, existing): Minimal code to pass the supplied red tests.
- `validator` (grok-build, existing): Executes tests + coverage, returns strict gate result.
- `reviewer` (fast): Lens reviews when orchestrator decides (selective).

See:
- `.grok/personas/tdd-orchestrator.toml`
- `.grok/personas/test-writer.toml`
- `.grok/docs/tdd-3-actions.md` (the three core action contracts)
- `.grok/docs/tdd-workflow.md`
- `.grok/docs/tdd-architecture.md`

## Loop Structure (lead orchestrates)

1. **Setup**
   - Read AGENTS.md + relevant docs.
   - Create `agent_logs/<feature-slug>/` (use date + short descriptive slug, e.g. `2026-06-27-move-lane-tdd`).
   - Write `tdd-plan.json` or `plan.md` (scoped phases).
   - `todo_write` with phases: Red, Green(s), Validate, Review, Final.
   - Write initial `checkpoint-setup-plan.md`.

2. **RED (Test Writer)**
   - Spawn `test-writer` (read-only or limited) with task + current gaps + plan excerpt.
   - Goal: only failing tests (new or extended). Must use TestBackend for UI.
   - Receive unified diff or test file content + summary.
   - Apply via search_replace/write.
   - Run tests → expect **failure** (record evidence).
   - Write `checkpoint-red.md` + `red-tests.diff`.
   - Update todo.

3. **GREEN (Coder + minimal iterations)**
   - Pass *only* the failing tests + tiny relevant context + plan excerpt to coder.
   - Coder must produce **minimal** diff to make tests pass.
   - Apply changes.
   - Immediately run validator or targeted test.
   - If not green: feed validator output back to coder (loop limited).
   - On green: write `coder-greenN.diff` + `checkpoint-greenN.md`.

4. **VALIDATE GATE (strict)**
   - Spawn validator (execute mode).
   - Must run:
     - `julia --project=. -e 'using Pkg; Pkg.test()'`
     - Targeted test file
     - Coverage (Pkg.test(coverage=true) or Coverage.jl)
   - Require: all new/changed logic tests pass **and** coverage >= 100% on touched code (or explicit justified exception).
   - Validator returns structured gate result.
   - If gate fails → back to appropriate phase (usually more red or green).
   - On success: write `checkpoint-validateN.md` + `validation-evidence.md` + coverage report.

5. **Refactor / Polish (only after gate)**
   - Only after green + gate. Keep all tests green.
   - Selective reviewer lens review on significant diffs.

6. **Final**
   - Write `final-summary.md` (task, phases, commands run with evidence, coverage, files changed, next actions).
   - Update `state.json`.
   - Lead returns structured result with links to artifacts.

## Checkpoint Convention
`agent_logs/<slug>/` contains:
- plan.md or tdd-plan.json
- checkpoint-setup-plan.md
- checkpoint-red.md + red-tests.diff
- checkpoint-greenN.md + coder-greenN.diff
- checkpoint-validateN.md + validation-evidence.md
- coverage-report.json (if generated)
- state.json (current phase, attempts, gate results)
- final-summary.md

Lead **always** writes a short phase summary after major steps (see token-efficiency.md).

## Efficiency & Handoff Rules
- Hand off **scoped context only**: failing tests summary + unified diff excerpts + latest checkpoint + plan phase.
- Instruct subagents: "Read files from disk: plan.md, agent_logs/<slug>/checkpoint-*.md, relevant test files."
- Prefer `isolation: "worktree"` for coder/validator runs when doing long TDD.
- Use `todo_write` for Red/Green/Refactor/subtasks.
- Background + `get_command_or_subagent_output` for parallel validators or reviewers.

## Julia + Tachikoma Requirements
- Always: `julia --project=.`
- For UI: mandatory TestBackend in the red tests you (as orchestrator) drive.
- Direct model tests + render + inspection after events.
- Follow Elm Model/Update/View.

## Example Full Run (lead thinking outline)
```
/tdd Move lane via modal picker

Setup → RED (test-writer writes failing modal + navigation + move tests) → run (red) → checkpoint-red
GREEN (coder given only red tests) → apply minimal → run (green) → checkpoint-green
VALIDATE → full test + coverage gate → green + 100% → checkpoint-validate
(If needed more GREEN or polish)
Final summary + artifacts
```

Demand real execution at every gate. Never claim green without running the commands in this session and recording evidence.

This skill is the dedicated TDD counterpart to `/pipeline` and `/test`.
