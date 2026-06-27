# AGENTS.md (Grok project rules)

**This workspace replicates the agentic coding environment from `test-grok-cli`.**

Project: **julia-tachikoma-ui-test**

It includes the full `.grok/` native personas, skills (pipeline, prime, review, test, commit, caveman), safety hooks, and model routing.

Use this for developing and testing Julia + UI/agentic coding experiments with the structured Grok multi-agent workflow (Plan → Scout → Implement/Validate → Review).

## Current Quick-Win Setup

- Grok automatically loads permissions and some hooks from `~/.claude/settings.local.json` and Claude plugins (compat layer is active).
- We have a `.grok/` directory with:
  - `config.toml` — subagent model routing between `grok-build` (lead/orchestrator) and `grok-composer-2.5-fast` (faster model for light roles).
- Custom models (BYOM) are registered in the user `~/.grok/config.toml` using `[model.<name>]` sections. Mercury 2 (Inception Labs) has been added as an example fast reasoning model.
  - `personas/`, `agents/`, `skills/`, `hooks/`, `rules/` — ready for native ports.
- Use `/config-agents`, `/personas`, `/skills`, `grok inspect`, and `/plan` for management.

## Model Assignment Strategy (mirroring the original team)

- **Lead / Orchestrator**: `grok-build` — strong coding model.
- **Scout / Explorer / Reviewer (lightweight)**: `grok-composer-2.5-fast` — fast model.
- **Coder**: `grok-composer-2.5-fast` (Composer 2.5 Fast). Mercury-2 (BYOM) can be used but subagent calls to it are often unreliable (env inheritance, client overhead).
- **Coder / Validator / Planner (heavy)**: `grok-build` or appropriate override.

BYOM example: Mercury 2 (`mercury-2`) from Inception Labs is registered globally as a fast OpenAI-compatible diffusion model (see `~/.grok/config.toml` and `.grok/config.toml`).

**Using the key via .env (preferred):**
- Add `INCEPTION_API_KEY=...` to a `.env` file in the project (`.env` is gitignored).
- Start Grok with `source .env && grok ...` (or use direnv).
- Assign per persona: edit `model = "..."` in .grok/personas/NAME.toml. Or `-m` for lead.

Current persona models (edit `model =` line in .grok/personas/*.toml to switch):
- coder    = grok-composer-2.5-fast
- reviewer = grok-composer-2.5-fast
- scout    = grok-composer-2.5-fast
- planner/validator = grok-build

You can achieve this via:
- `[subagents.models]` in config
- Personas with a `model` field
- Custom roles/agents in `.grok/agents/`

## Pipeline Philosophy (from the original .claude setup)

Every significant change should go through a structured process:
1. Plan (or use `/plan`)
2. Scout / research context
3. Implement (with clear evidence of changes)
4. Validate (run real commands + tests, provide high-signal evidence)
5. Review (multiple lenses + verification of findings)

See `.grok/docs/token-efficiency.md` for the current practices that reduce token usage (phase summaries, artifact files in the target dir, concise validator output, minimal context to subagents, diff-focused reviews) while preserving quality and the high reasoning effort on the coder persona.

We will encode this as native Grok skills + personas + explicit use of `spawn_subagent`.

## Conventions

- Keep skills focused and version-controllable.
- Prefer explicit `spawn_subagent` with `capability_mode` and personas over vague delegation.
- Document model choices and why.
- Use `todo_write` for multi-step work.
- Follow `.grok/docs/token-efficiency.md` for context hygiene (phase summaries, artifact files in target dir, concise validator output, minimal context to subagents, diff-focused reviews).

## Julia + Tachikoma Specific Rules

- Always invoke Julia with `julia --project=.`.
- Tachikoma apps follow Elm: `mutable struct X <: Model`, `should_quit`, `update!(m, KeyEvent)`, `view(m, Frame)`. Use `@tachikoma_app`.
- **UI changes require TestBackend coverage** (see https://kahliburke.github.io/Tachikoma.jl/dev/testing). Validator will execute render + char_at / find_text / row_text / handle_key! + re-render checks.
- Use widgets + layouts (Block, render, split_layout, constraints) heavily.
- Test logic directly with `update!` on models; render widgets headless.
- Property-based tests with Supposition.jl are encouraged for layouts/unicode/edge cases.
- Recording (`record_app`, `record_widget`) useful for demos and visual verification outside strict tests.
- Run `julia --project=. -e 'using Pkg; Pkg.test()'` or `julia --project=. test/runtests.jl` for validation.
- The TestBackend + scripted injection is the killer feature that makes agentic TUI development reliable and repeatable.

## TDD Orchestration Architecture & 2026 Best Practices (Hierarchical + Scoped)

This project adopts the hybrid hierarchical pattern shown effective in 2025–2026 research and practice (orchestrator-worker superiority, TDD loops, context isolation, tool-heavy execution, persistent repo state).

**Dedicated TDD Agent**
- Use the `tdd-orchestrator` persona (strong model) when you want a lead whose entire job is to run the new workflow: it delegates to the three core actions, iterates strictly on validator/testing feedback, suggests next steps, and drives implementation until the coverage gate passes.
- The invocable workflow is the `tdd` skill (`/tdd <task>`).

See:
- `.grok/personas/tdd-orchestrator.toml`
- `.grok/skills/tdd/SKILL.md`
- `.grok/docs/tdd-3-actions.md` (the three actions contract)
- `.grok/docs/tdd-workflow.md`

**Core structure (Grok Build native)**
- Orchestrator (lead on grok-build): owns the goal, TDD Red-Green-Refactor state machine, global state, checkpoints. Delegates **only scoped work**.
- Specialized sub-agents (routed models):
  - Test Writer (new persona, fast): given task + gaps → produces **failing tests only** (unified diff + JSON summary).
  - Coder (grok-composer-2.5-fast native): receives **only** failing tests + relevant diff + plan excerpt. Writes the **minimal** code to pass. Outputs diff + JSON.
  - Validator (grok-build): executes real `julia --project=.` tests + coverage measurement (Pkg.test(coverage=true) or Coverage.jl). Emits **strict JSON gate**: `{tests_passed, coverage_percent, failing_tests, coverage_gaps, overall_status}`. Loops until green **and** >=100% coverage (or escalates).
  - Reviewers (fast): triggered **selectively** by orchestrator on significant diffs. Receive **diff + relevant tests + guidelines only**. Structured JSON findings.
- Swarm/parallel: only for independent reviewers or when orchestrator explicitly launches multiple.

**Mandatory efficiency rules (token bloat fixes)**
- Every subagent handoff uses **scoped context only**: failing tests summary + unified diff (or targeted excerpts) + task/plan summary + latest checkpoint. Instruct: "Read plan.md and agent_logs/<slug>/checkpoint-*.md from disk."
- Handoff formats: unified diffs **or** small JSON objects. Never paste full files or full prior conversation.
- Persistent truth = git repo + `agent_logs/<feature-or-run>/` (tdd-plan.json, checkpoints, coverage-report.json, changes.diff, state.json).
- `todo_write` tracks TDD phase (Red / Green / Refactor + sub-tasks).
- Checkpoints after every major phase (lead writes concise summary.md + updates state).
- Use `isolation:"worktree"`, `resume_from`, `cwd`, background + wait where helpful (see bundled skills for patterns).

**Coverage & TDD enforcement**
- 100% coverage target on changed logic/UI (non-negotiable except with explicit justification).
- Validator must actually run coverage and block until met.
- UI work: **always** exercise Tachikoma.TestBackend (render + char_at/find_text/row_text after update!/handle_key! + re-render).
- Strict loop: tests first (failing) → minimal code → refactor only after green.

**agent_logs convention**
Create `agent_logs/<feature-slug>/` (or uuid) for a run. Orchestrator and instructed sub-agents write checkpoints and artifacts there. Can be gitignored or committed selectively. Reference paths in all follow-up prompts.

**When to use which workflow (pragmatic)**
- Trivial mechanical (typo, small guard): direct edit + `/test` or `/review`.
- Small-medium feature/bug: `/implement [--effort 2|3]` (or the evolved local pipeline).
- Ambitious / multi-file / risky: `/design "..."` (gets reviewed PR-plan DAG) then `/execute-plan path --concurrency 4` (worktree-isolated, resumable, parallel levels, mandatory per-PR review until 0 issues).
- Explicit TDD experiment or local default: follow the TDD Orchestrator prompt + personas below (Test Writer → Coder → Validator gate).

The local `.grok/skills/pipeline` and personas are being evolved to support the TDD loop explicitly while the bundled skills already provide excellent isolation/resumability/memory.

See the new comprehensive reference:
- `.grok/docs/tdd-architecture.md` — full architecture, diagrams, and usage guide
- `.grok/docs/tdd-workflow.md` — copy-paste prompts and schemas
- `.grok/docs/tdd-3-actions.md` — the three core actions contract

## Model routing + custom models (BYOM)

See `.grok/config.toml` for the project-scoped routing.

Custom models (e.g. Mercury 2) are configured in your global `~/.grok/config.toml`.

**Loading keys via .env (preferred):**
- Put `INCEPTION_API_KEY=...` in `.env`.
- Launch reliably: `set -a; source .env; set +a; grok ...`
- Verify models: `grok inspect` / `grok models`

See `.grok/config.toml` and the personas for current defaults.
The replicated environment already includes full pipeline, prime, test, review, commit, and caveman skills.
