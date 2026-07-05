# AGENTS.md (Grok project rules)

Project: **julia-tachikoma-ui-test** — Julia + Tachikoma.jl TUI experiments (main sub-project: `qci-kanban/`).

**Workflow policy (2026-07 revision):** see `.grok/docs/agentic-workflow-2026-07.md` for the full rationale and verified evidence. Summary: single agent by default, context-centric decomposition, one independent verifier, no role-play pipelines. The old `/pipeline` persona pipeline and 3-agent `/tdd` choreography are **deprecated** (kept on disk for reference).

**MANDATORY RULE (see .grok/rules/always-run-the-app-after-changes.md):**
After ANY change to src/, db seeding, login gate, KanbanModel/AppModel, update!/view, or tests that affect startup:
- Run a real app verification (live `julia --project=. -e 'using QciKanban; QciKanban.kanban()'` or headless `record_demo`/`record_demo2`) and confirm the first-time "No users — press [c] to create account" screen with ZERO pre-seeded users.
- Save evidence. Never finish without starting/verifying the app.

## Tiered Workflow (the default process)

Work is tiered by size. The lead does the work itself in one context; **the agent that implements a feature also writes its tests**. Never split plan/code/test across separate agents by role — every handoff loses context.

**Tier 0 — trivial** (typo, label, one-line guard): direct edit + the targeted tests from the test-impact map. No subagents.

**Tier 1 — normal feature/bugfix (default):**
1. *Scout (optional)*: if broad codebase context is needed, spawn ONE read-only explore subagent that returns a condensed summary (~1–2k tokens, file:line + short snippets). Don't fold file dumps into the lead context. If you already know the files, just read them.
2. *Plan inline*: short written plan (plan.md for larger work). No separate planner agent.
3. *Implement + test in the same context*: write the change AND its TestBackend tests yourself — red-first for behavioral changes, BDD acceptance specs in `test/features/` for user-facing features (see `qci-kanban/.claude/rules/tdd-bdd-coverage-gates.md`, canonical for both tools). Consult the test-impact map (`qci-kanban/.claude/rules/qci-kanban-test-map.md` — canonical for both tools) and run the targeted tests as you go, then the full suite.
4. *Verify independently*: spawn ONE verifier subagent (validator persona, `capability_mode: execute`) with the task description + changed-file list and **explicit criteria**: run the complete test suite (`julia --project=. test/runtests.jl`), run the app gate AND the coverage gate (`julia --project=. test/coverage_gate.jl`) if src/ changed, review the actual `git diff` from disk, quote findings verbatim with file:line, severity critical/warning/nit, exact command + exit code for every check. Verdict APPROVED only on full-suite green + app gate + coverage gate + zero critical/warning findings. Fix findings, re-verify (use `resume_from` so the verifier keeps its context).

**Tier 2 — large multi-part work:** `/design`-style short design doc with a PR plan (DAG of small, independently reviewable slices) → user buy-in → each slice implemented as a Tier-1 unit, `isolation: "worktree"` when slices run in parallel (bundled `/execute-plan` fits here). Each slice's implementer owns its tests; each slice gets its own verifier.

For medium tasks the bundled `/implement --effort 1..2` (implementer ↔ reviewer with `resume_from`) is an acceptable Tier-1 variant — prefer low effort; 3+ reviewers only for genuinely high-risk changes.

## TDD (revised — see .grok/skills/tdd/SKILL.md)

Red-first is a *discipline inside the single agent*, not a multi-agent ceremony: for behavioral changes, write the failing test first, watch it fail, make it pass minimally, refactor after green. What measurably reduces regressions is the **test-impact map** (know which tests cover what you're touching and run them first), not procedural TDD role-play. In `qci-kanban`, coverage IS a gate: `julia --project=. test/coverage_gate.jl` must pass (100% line coverage on gated v2 files, exclusions only via justified in-source `COV_EXCL` markers) alongside full-suite green + the app gate. User-facing features additionally require Given/When/Then BDD acceptance specs in `test/features/` (see `qci-kanban/.claude/rules/tdd-bdd-coverage-gates.md`).

## Verification culture (non-negotiable, any tier)

- Never claim green without running the commands yourself in this session; exact command + exit_code, concise evidence (error lines or last 5–8 lines; full tail only on failure or "all pass" claims).
- Re-audit "all pass" claims by re-running the exact commands.
- Reviewer/verifier findings quote code verbatim from disk.
- After `src/` changes, three gates before done: full suite + run-the-app + coverage gate (100% on gated v2 files).
- Escalate to adversarial re-verification (independent refutation attempt, 2-of-3) only for critical findings.
- "No test needed" requires explicit written justification.

## Token discipline

- Artifact-first: durable state goes to disk (plan.md, `agent_logs/<slug>/`), subagents are told to read files from disk, not fed pastes.
- Prefer `git diff` and targeted excerpts over whole-file dumps.
- Subagents exist for context isolation (exploration, independent verification) — not role-play. Spawn flags for light roles: `--no-memory --no-leader --disable-web-search` where safe.
- `todo_write` tracks phases; pass current todos only, not history.

## Model Assignment

- **Lead / verifier**: `grok-build` (strong model — the lead does the actual implementation now, so it gets the strong model).
- **Scout / explore subagents**: `grok-composer-2.5-fast`.
- Routing lives in `.grok/config.toml` (`[subagents.models]`) and persona `model =` lines. BYOM (mercury-2) is registered globally but unused.
- Legacy personas (`planner`, `scout`, `coder`, `reviewer`, `test-writer`, `tdd-orchestrator`) remain for the deprecated skills; `validator` doubles as the Tier-1 verifier persona.

## Julia + Tachikoma Specific Rules

**Before substantial Tachikoma UI work** (new views, modals, focus/keymap changes), read:
- `.grok/docs/tachikoma-core.md`
- `.grok/docs/tachikoma-ui-testing.md`
- `.grok/docs/kanban-beauty-plan.md` (Kanban feature work)
Small tweaks to existing patterns don't require a full re-read — the distilled rules below suffice.

- Always invoke Julia with `julia --project=.`.
- Tachikoma apps follow Elm: `mutable struct X <: Model`, `should_quit`, `update!(m, KeyEvent)`, `view(m, Frame)`. Use `@tachikoma_app`.
- UI verification is headless and deterministic: `Tachikoma.TestBackend` + `find_text`/`row_text`/`char_at` + **re-render after every `update!`** before asserting. Prefer the project `visual_rows(m; w, h)` helper.
- Drive flows exclusively through `update!(m, KeyEvent(...))` — no direct mutation of fields the user couldn't reach.
- Login-gate tests start from raw `KanbanModel()` + `:memory:` + `load_users!` and verify the exact first-time zero-users screen.
- Modals and overlays require "no bleed" assertions.
- UI changes require TestBackend coverage; the verifier must execute render + assertion + `update!` + re-render checks.
- Property-based tests with Supposition.jl encouraged for layouts/unicode/edge cases.
- `record_app`/`record_widget`/`record_demo` for demos and visual verification outside strict tests.
- Full suite: `julia --project=. test/runtests.jl` (or `Pkg.test()`).
- v1 (`src/QciKanban.jl` v1 sections, `src/db.jl`) is legacy — do not modify; new work targets v2. Raw `ColorRGB` only in `src/ui/theme.jl`.

## Skills

- `/tdd` — revised single-agent TDD discipline (red-first + impact map + verifier gate).
- `/review` — strict single-verifier review of the working tree.
- `/test`, `/commit`, `/prime`, `/caveman` — unchanged utilities.
- `/pipeline` — **DEPRECATED**; kept for reference. Use the tiered workflow above.
- Bundled: `/implement`, `/design`, `/execute-plan` (see `~/.grok/bundled/skills/`).

## Conventions

- Keep skills focused and version-controllable; document model choices.
- Prefer explicit `spawn_subagent` with `capability_mode` over vague delegation; depth limit = 1 (subagents don't spawn subagents).
- Keep this file under 200 lines (always-loaded instruction files lose adherence past that).
- When workflow policy changes, update `.claude/` (CLAUDE.md, rules, agents) and `.grok/` together — they encode the same process.
