# TDD Orchestration Architecture (2026 Hierarchical + Scoped)

This project adopts the hybrid hierarchical pattern shown effective in 2025–2026 research and practice (orchestrator-worker superiority, strict TDD loops, context isolation, tool-heavy execution, persistent repo state).

## Dedicated TDD Agent
Use the `tdd-orchestrator` persona (strong model) when you want a lead whose entire job is to run the new workflow: it delegates to the three core actions, iterates strictly on validator/testing feedback, suggests next steps, and drives implementation until the coverage gate passes.

The invocable workflow is the `tdd` skill (`/tdd <task>`).

See:
- `.grok/personas/tdd-orchestrator.toml`
- `.grok/skills/tdd/SKILL.md`
- `.grok/docs/tdd-3-actions.md` (the three actions contract)
- `.grok/docs/tdd-workflow.md`

## Core Structure (Grok Build native)
- **Orchestrator** (lead on grok-build): owns the goal, TDD Red-Green-Refactor state machine, global state, checkpoints. Delegates **only scoped work**.
- **Specialized sub-agents** (routed models):
  - Test Writer (new persona, fast): given task + gaps → produces **failing tests only** (unified diff + JSON summary).
  - Coder (grok-composer-2.5-fast native): receives **only** failing tests + relevant diff + plan excerpt. Writes the **minimal** code to pass. Outputs diff + JSON.
  - Validator (grok-build): executes real `julia --project=.` tests + coverage measurement (Pkg.test(coverage=true) or Coverage.jl). Emits **strict JSON gate**: `{tests_passed, coverage_percent, failing_tests, coverage_gaps, overall_status}`. Loops until green **and** >=100% coverage (or escalates).
  - Reviewers (fast): triggered **selectively** by orchestrator on significant diffs. Receive **diff + relevant tests + guidelines only**. Structured JSON findings.

Swarm/parallel: only for independent reviewers or when orchestrator explicitly launches multiple.

## Mandatory Efficiency Rules (token bloat fixes)
- Every subagent handoff uses **scoped context only**: failing tests summary + unified diff (or targeted excerpts) + task/plan summary + latest checkpoint. Instruct: "Read plan.md and agent_logs/<slug>/checkpoint-*.md from disk."
- Handoff formats: unified diffs **or** small JSON objects. Never paste full files or full prior conversation.
- Persistent truth = git repo + `agent_logs/<feature-or-run>/` (tdd-plan.json, checkpoints, coverage-report.json, changes.diff, state.json).
- `todo_write` tracks TDD phase (Red / Green / Refactor + sub-tasks).
- Checkpoints after every major phase (lead writes concise summary.md + updates state).
- Use `isolation:"worktree"`, `resume_from`, `cwd`, background + wait where helpful (see bundled skills for patterns).

## Coverage & TDD Enforcement
- 100% coverage target on changed logic/UI (non-negotiable except with explicit justification).
- Validator must actually run coverage and block until met.
- UI work: **always** exercise Tachikoma.TestBackend (render + char_at/find_text/row_text after update!/handle_key! + re-render).
- Strict loop: tests first (failing) → minimal code → refactor only after green.

## agent_logs convention
Create `agent_logs/<feature-slug>/` (or uuid) for a run.

Typical contents:
- checkpoint-setup-plan.md
- checkpoint-red.md + red-tests.diff
- checkpoint-greenN.md + coder-greenN.diff
- checkpoint-validateN.md + validation-evidence.md
- plan.md / tdd-plan.json
- state.json
- final-summary.md
- coverage reports, diffs, etc.

The orchestrator (and only the orchestrator) manages this directory and the state machine.

## Integration with Other Skills
- Often used together with `/execute-plan` for PR DAGs (each PR can be driven with its own `/tdd` scoped task).
- Complements `/pipeline` (use pipeline for broad flow, tdd when you want explicit red-first + coverage gate per slice).
- `/test` remains the general validation skill; TDD skill owns the red-first loop.

This architecture keeps the lead focused on orchestration and evidence while specialized workers stay narrowly scoped, dramatically improving focus, test quality, and coverage reliability.
