# AGENTS.md (Grok project rules)

**This workspace replicates the agentic coding environment from `test-grok-cli`.**

Project: **julia-tachikoma-ui-test**

It includes the full `.grok/` native personas, skills (pipeline, prime, review, test, commit, caveman, tdd), safety hooks, and model routing.

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

## TDD Orchestration Architecture & 2026 Best Practices (Hierarchical + Scoped)

This project supports a dedicated hierarchical TDD workflow in addition to the core pipeline.

**Dedicated TDD Agent**
- Use the `tdd-orchestrator` persona (strong model) when you want a lead whose entire job is to run the new workflow: it delegates to the three core actions, iterates strictly on validator/testing feedback, suggests next steps, and drives implementation until the coverage gate passes.
- The invocable workflow is the `tdd` skill (`/tdd <task>`).

See:
- `.grok/personas/tdd-orchestrator.toml`
- `.grok/skills/tdd/SKILL.md`
- `.grok/docs/tdd-3-actions.md` (the three actions contract)
- `.grok/docs/tdd-architecture.md`
- `.grok/docs/tdd-workflow.md`

**Core structure (Grok Build native)**
- Orchestrator (lead on grok-build): owns the goal, TDD Red-Green-Refactor state machine, global state, checkpoints. Delegates **only scoped work**.
- Specialized sub-agents (routed models):
  - Test Writer (new persona, fast): given task + gaps → produces **failing tests only** (unified diff + JSON summary).
  - Coder (grok-composer-2.5-fast native): receives **only** failing tests + relevant diff + plan excerpt. Writes the **minimal** code to pass.
  - Validator (grok-build): executes real `julia --project=.` tests + coverage. Emits strict gate result. Loops until green **and** >=100% coverage on changed logic/UI.
- UI work: **always** exercise Tachikoma.TestBackend (render + char_at/find_text/row_text after update!/handle_key! + re-render).
- `todo_write` tracks TDD phase (Red / Green / Refactor + sub-tasks).
- Persistent artifacts written to `agent_logs/<feature-slug>/` (checkpoints, diffs, validation-evidence, state.json, final-summary.md).

**Mandatory rules**
- 100% coverage target on changed logic/UI (non-negotiable except with explicit justification).
- Strict loop order: tests first (failing) → minimal code → refactor only after green + gate.
- Every handoff uses scoped context + instructs subagents to read plan/checkpoint artifacts from disk.
- Checkpoints after every major phase.

Use `/tdd` for feature slices where you want ironclad red-first TDD + coverage evidence. It pairs well with `/execute-plan` for PR stacks and `/pipeline` for broader flows.

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

## Model routing + custom models (BYOM)

See `.grok/config.toml` for the project-scoped routing.

Custom models (e.g. Mercury 2) are configured in your global `~/.grok/config.toml`.

**Loading keys via .env (preferred):**
- Put `INCEPTION_API_KEY=...` in `.env`.
- Launch reliably: `set -a; source .env; set +a; grok ...`
- Verify models: `grok inspect` / `grok models`

See `.grok/config.toml` and the personas for current defaults.
The replicated environment includes the core skills (pipeline, prime, review, test, commit, caveman) plus the dedicated `/tdd` hierarchical TDD orchestration workflow with supporting personas (`tdd-orchestrator`, `test-writer`) and docs in `.grok/docs/tdd-*.md`. See AGENTS.md section on TDD Orchestration and `.grok/skills/tdd/SKILL.md`.
