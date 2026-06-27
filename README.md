# julia-tachikoma-ui-test

Agentic coding environment for **Julia + Tachikoma.jl TUI** experiments and high-quality development. Replicated from `test-grok-cli`.

**Current primary demo (MVP)**: QCI-themed local AI Metrics dashboard for Grok Build (HEHS, tokens, efficiency stats). Pure Julia, rich widgets, full TestBackend.

Run:
```
julia --project=. -e 'using TachikomaUITest; TachikomaUITest.run_ai_metrics_dashboard()'
```
Keys: r=refresh/ingest, j/k nav, q quit.

See plan in .grok session for small-units breakdown.

## How the Metrics Hub Works (Grok Build + Terminal Logs)

The dashboard is a **local viewer** only. Real data flows like this:

1. **Login / Account**: Use the outer `grok` CLI (or the Grok environment running this session). Auth is handled there (first run or `grok login` equivalent). Your sessions use `grok-build` (lead) etc. as configured in `.grok/personas/*.toml`.
2. **Logging (the "hooks hub" producer)**: The Grok CLI "shell" automatically emits structured events to `~/.grok/logs/unified.jsonl` on inference turns (`shell.turn.inference_done` + model/ctx events). See exact shapes in `test/test_ai_metrics_dashboard.jl:350`.
3. **Attributions (manual credit)**: `~/.ai-metrics/data.json` stores per-sid `hehsManual` / `hehsActual` + `outcome` ("merged-clean" | "merged-rework"). Only these are credited in HEHS/value.
4. **Ingestion**: Press `r` in the TUI (or `load_data!` in code/tests). Pure Julia parsers + calculators (ported from the original ai-metrics TS) compute everything.
5. **Fallback**: If no real files or empty, shows safe dummy data for demos/tests.

Current gaps (addressed in ongoing work): transparency (REAL/DEMO indicator), interactive tagging UI, onboarding docs. The actual log emission and primary auth live in the Grok CLI (replicated from test-grok-cli).

To populate real numbers: do real Grok Build work (using the personas here), then tag outcomes in data.json (future: do it from the TUI).

This workspace is set up with the full Grok-native multi-agent pipeline:

- `.grok/` — personas (planner, scout, coder, validator, reviewer), skills (pipeline, prime, review, test, commit, caveman), config, safety hooks
- Structured workflow: Plan → Scout → Implement/Validate loop → Review
- Token efficiency practices and verbatim evidence requirements
- **Julia-first**: Project.toml + test/ harness using Tachikoma's excellent `TestBackend` for deterministic headless widget + app testing
- Safety hooks + .env support for custom models (BYOM like Mercury-2)

## Quick Start (Agentic Workflow)

```bash
# In a fresh grok session:
# 1. Prime context
/prime

# 2. For non-trivial work use the full pipeline
/pipeline Add X feature to the Julia UI

# Or trivial mechanical change:
/pipeline trivial: true Fix typo in README
```

Available skills (slash or direct):
- `/pipeline`
- `/prime`
- `/review`
- `/test`
- `/commit`
- caveman mode for terse output

## Environment Replication

Replicated files from `test-grok-cli`:
- `.grok/config.toml`, `personas/*.toml`, `skills/*/SKILL.md`, `hooks/`
- `AGENTS.md`
- `.gitignore`, `.env`
- Helper scripts (legacy node scripts removed; this is a native Julia project)

See `AGENTS.md` for full model routing, BYOM instructions, and workflow rules.

## Project Goals

- Build real, rich Julia TUIs with Tachikoma.jl using the structured agentic pipeline (Plan/Scout/Implement/Validate/Review) or the 2026 TDD Orchestration workflow (hierarchical + scoped sub-agents + strict coverage gate — see AGENTS.md and .grok/docs/tdd-workflow.md)
- Leverage Tachikoma's **TestBackend** (headless rendering + KeyEvent injection + inspection APIs) for fully deterministic, CI-friendly, tty-free UI tests — this is what enables consistent high-quality agentic TUI work
- Maintain excellent test coverage, style, and architecture using Julia idioms and Tachikoma patterns (Elm Model/Update/View + widgets/layouts)

## Quick Dev Commands (Julia + Tachikoma)

```bash
# Always use project
julia --project=.

# Run the test harness (uses TestBackend extensively)
julia --project=. -e 'using Pkg; Pkg.test()'
# or directly
julia --project=. test/runtests.jl

# Run a TUI (example after you implement one)
julia --project=. -e '
using Tachikoma
@tachikoma_app
# ... define your Model + methods ...
app(MyModel())
'
```

See `test/test_tachikoma_basics.jl` for current TestBackend + model testing examples.

Full Tachikoma docs: https://kahliburke.github.io/Tachikoma.jl/dev/ (especially /testing, /architecture, /getting-started, widgets + layout).

## Testing Strategy (Critical for Quality)

- Widget rendering + interaction: `TestBackend`, `render_widget!`, `char_at`/`find_text`/`row_text`, `handle_key!`, re-render + assert.
- App logic: direct `update!(model, KeyEvent(...))`.
- Layouts, unicode, edges: Supposition.jl property-based tests.
- This replaces brittle "run the TUI and watch" with reproducible evidence — perfect for the validator persona.

## Container Notes

None. This is a native Julia terminal application. 

- Run directly with `julia --project=.` in any modern terminal (Kitty, WezTerm, iTerm2, etc. recommended for full graphics support).
- CI uses standard `julia-actions` (see .github/workflows/CI.yml). TestBackend makes testing fully headless and reproducible.
- No Docker, containers, or external services are required or used.

## Next

- `/prime` to orient.
- For real work: `/pipeline Build a <feature> TUI screen with full TestBackend coverage`

## Also available

**qci-kanban** (self-contained sub-project at `qci-kanban/`):

Jira-inspired Kanban TUI (board + calendar, SQLite, login/users, full TestBackend).

```bash
julia --project=qci-kanban -e 'using QciKanban; QciKanban.kanban()'
```

See [qci-kanban/README.md](qci-kanban/README.md).

Edit `.grok/personas/*.toml` (especially coder/validator) or skills if you need to tune.

---

Replicated/adapted: 2026-06-24 for Julia + Tachikoma TUI agentic development.
