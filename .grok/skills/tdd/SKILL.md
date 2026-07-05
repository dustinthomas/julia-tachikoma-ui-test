---
name: tdd
description: Single-agent red-first TDD with test-impact context and an independent verifier gate (2026-07 revision). You write the failing test, watch it fail, make it pass minimally, then hand to a verifier. Replaces the deprecated 3-agent test-writer/coder/validator choreography.
when-to-use: Behavioral changes where a failing-test-first loop adds safety — bug fixes with a reproducible symptom, new update!/view behavior, contract changes. Use /tdd <task description>.
user-invocable: true
allowed-tools: run_terminal_command, read_file, grep, write, search_replace, todo_write, spawn_subagent
---

# TDD Skill — Single-Agent Red-First with Impact Context (2026-07)

**What changed and why:** the old version of this skill split RED (test-writer agent), GREEN (coder agent), and the gate (validator agent) across three subagents. Verified research (TDAD, arXiv 2603.17973; see `.grok/docs/agentic-workflow-2026-07.md`) found that *procedural TDD instructions without targeted test context made regressions worse than no intervention*, while supplying a code→tests impact map cut regressions ~70%. So: **you do the whole loop yourself in one context**, the impact map supplies the targeted context, and the only subagent is the independent verifier at the end.

## The loop (you, the lead, in one context)

1. **Orient** — consult the test-impact map (`qci-kanban/.claude/rules/qci-kanban-test-map.md`) for every file you expect to touch. Run those targeted tests BEFORE changing anything to confirm the baseline is green (`julia --project=. test/runtests.jl` for suites that need the runtests helpers). Record the baseline.
2. **RED** — write the failing test(s) yourself, in the correct existing test file per the map. For UI: TestBackend, driven through `update!(m, KeyEvent(...))`, re-render before every assertion, no-bleed checks for modals, raw-model start for gate tests. User-facing features also get Given/When/Then acceptance coverage in `test/features/` (extend the phase file, or add one and wire it into `runtests.jl`). Run them; **confirm they fail for the expected reason** (a test that fails for the wrong reason proves nothing). Record the failure output.
3. **GREEN** — write the minimal production change to pass. Run the targeted tests; iterate until green. Resist scope creep: anything beyond the failing tests' scope goes in the plan, not this diff.
4. **Refactor** — only after green. Keep the targeted tests green throughout.
5. **Full suite + app gate + coverage gate** — `julia --project=. test/runtests.jl` in full; if `src/` changed, run the app gate (`record_demo2`/`record_demo` or scripted startup check, confirm the zero-users first-run login screen) AND the coverage gate (`julia --project=. test/coverage_gate.jl` — must print `GATE PASSED`; 100% line coverage on gated v2 files, exclusions only via justified in-source `COV_EXCL` markers).
6. **Independent verify** — spawn ONE verifier subagent (validator persona, `capability_mode: execute`) with: the task, changed files, your baseline/red/green evidence, and explicit criteria — re-run the complete suite, re-run the app gate and the coverage gate, check red-first evidence is present and user-facing features extended `test/features/`, review the actual `git diff` from disk, verbatim quotes with file:line, exact command + exit code per check, verdict APPROVED only on full green + all gates + zero critical/warning findings. Fix findings; re-verify with `resume_from`.

## State & artifacts (lightweight)

- `todo_write`: baseline / red / green / full-suite+gates / verify.
- For multi-session work, write `agent_logs/<date-slug>/notes.md` with baseline evidence, red output, and decisions — enough to resume, not a checkpoint ceremony.
- Every claim of red/green backed by a command you actually ran in this session: exact command + exit code + the relevant output lines.

## Coverage

Coverage **is a gate** in `qci-kanban` (revised 2026-07-05): `julia --project=. test/coverage_gate.jl` must pass — 100% line coverage on every gated v2 file, exclusions only via auditable in-source `COV_EXCL` markers documented in `COVERAGE.md`. Use per-file uncovered-line output from the gate to find untested branches in code you touched, and close behavioral gaps with real tests, never with markers. Canonical policy for TDD/BDD/coverage: `qci-kanban/.claude/rules/tdd-bdd-coverage-gates.md` (shared by both tools).

## When NOT to use this skill

Pure refactors with existing coverage, doc/config changes, or visual polish with no behavioral contract — use the normal Tier 0/1 workflow from AGENTS.md. TDD earns its cost when there's a falsifiable behavior to pin down first.
