# AGENTS.md (Grok project rules)

**This workspace replicates the agentic coding environment from `test-grok-cli`.**

Project: **julia-tachikoma-ui-test**

It includes the full `.grok/` native personas, skills (pipeline, prime, review, test, commit, caveman), safety hooks, and model routing.

Use this for developing and testing Julia + UI/agentic coding experiments with the structured Grok multi-agent workflow (Plan → Scout → Implement/Validate → Review).

## Current Quick-Win Setup

- Grok automatically loads permissions and some hooks from `~/.claude/settings.local.json` and Claude plugins (compat layer is active).
- We have a `.grok/` directory with:
  - `config.toml` — subagent model routing between `grok-build` (lead/orchestrator) and `grok-composer-2.5-fast` (faster model).
- Custom models (BYOM) are registered in the user `~/.grok/config.toml` using `[model.<name>]` sections. Mercury 2 (Inception Labs) has been added as an example fast reasoning model.
  - `personas/`, `agents/`, `skills/`, `hooks/`, `rules/` — ready for native ports.
- Use `/config-agents`, `/personas`, `/skills`, `grok inspect`, and `/plan` for management.

## Model Assignment Strategy (mirroring the original team)

- **Lead / Orchestrator**: `grok-build` — strong coding model.
- **Scout / Explorer / Reviewer (lightweight)**: `grok-composer-2.5-fast` — fast model.
- **Coder**: `grok-composer-2.5-fast` (reliable fast default). Mercury-2 (BYOM) can be used but subagent calls to it are often unreliable (env inheritance, client overhead).
- **Coder / Validator / Planner (heavy)**: `grok-build` or appropriate override.

BYOM example: Mercury 2 (`mercury-2`) from Inception Labs is registered globally as a fast OpenAI-compatible diffusion model (see `~/.grok/config.toml` and `.grok/config.toml`).

**Using the key via .env (preferred):**
- Add `INCEPTION_API_KEY=...` to a `.env` file in the project (`.env` is gitignored).
- Start Grok with `source .env && grok ...` (or use direnv).
- Assign per persona: edit `model = "..."` in .grok/personas/NAME.toml. Or `-m` for lead.

Current persona models (edit `model =` line in .grok/personas/*.toml to switch):
- coder    = grok-composer-2.5-fast   (reliable; mercury-2 was unreliable for subagents)
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

## Model routing + custom models (BYOM)

See `.grok/config.toml` for the project-scoped routing.

Custom models (e.g. Mercury 2) are configured in your global `~/.grok/config.toml`.

**Loading keys via .env (preferred):**
- Put `INCEPTION_API_KEY=...` in `.env`.
- Launch reliably: `set -a; source .env; set +a; grok ...`
- Verify models: `grok inspect` / `grok models`

See `.grok/config.toml` and the personas for current defaults.
The replicated environment already includes full pipeline, prime, test, review, commit, and caveman skills.
