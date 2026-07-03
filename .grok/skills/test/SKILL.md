---
name: test
description: Run relevant tests and type checks for changes. Provide verbatim results. Use to validate implementation.
when-to-use: After code changes, or when user says "run tests" or "/test".
user-invocable: true
allowed-tools: run_terminal_command, read_file, grep
---

# Test & Validation Skill (Julia + Tachikoma focused)

Execute tests and static checks with full evidence.

## Process
1. Detect changed areas (use `git diff --name-only` or context).
2. For Julia: run `julia --project=. -e 'using Pkg; Pkg.test()' ` (or targeted).
3. **Always run the app** (see .grok/rules/always-run-the-app-after-changes.md) for startup/login/UI changes: use a julia expr exercising the real kanban() path or default DB + gate + create flow (or QciKanban.record_demo). When possible run the live `julia --project=. -e 'using QciKanban; QciKanban.kanban()'` in a terminal to see the screen.
4. Identify and run **targeted** tests for the modified code. Prefer tests that use Tachikoma.TestBackend.
5. If no targeted tests exist or change is new (especially UI/view/update!), write or update tests that cover the behavior using TestBackend + handle_key! + direct update!.
6. Run full relevant suite only when requested.
6. For every command executed, report:
   - The exact command
   - exit_code
   - Verbatim evidence (concise: key lines or errors; full tail on failure or "all pass" claim for audit).

## Rules
- Never claim "tests pass" without having run the command in this session.
- "No test needed" requires explicit justification in the report.
- **For any Tachikoma UI change: tests MUST exercise TestBackend inspection (char_at / row_text / find_text) or direct model state after update! + re-render.**
- If tests fail, provide root cause analysis + suggested fix.
- Always use `julia --project=.` .

## Julia + Tachikoma Commands
- Full package tests: `julia --project=. -e 'using Pkg; Pkg.test()'`
- Direct (very common for experiments): `julia --project=. test/runtests.jl`
- With specific testset filter (Julia 1.10+): `julia --project=. -e 'using Pkg; Pkg.test(; test_args=["--testset=TextInput"])' `
- Check package quality (add Aqua.jl later): `julia --project=. -e 'using Aqua, TachikomaUITest; Aqua.test_all(TachikomaUITest)'`

## Tachikoma UI Testing Methodology (MANDATORY for all UI work)

Follow the full methodology in `.grok/docs/tachikoma-ui-testing.md`.

Core rules:
- **Primary verification**: `TestBackend(w, h)` + render (via `view` or `render_widget!`) + re-render **after every** `update!` / `handle_key!`.
- Inspection: `find_text(tb, "text")`, `row_text(tb, n)`, `char_at(tb, x, y)`.
- Full-app models: use (or replicate) the `visual_rows(m; w=80, h=20)` helper that renders the model and returns all row strings.
- Login/first-time gate: always drive from raw `KanbanModel() + :memory: + load_users!`. Assert the exact "No users — press [c] to create account" prompt with zero users.
- Overlays/modals: require "no bleed" checks (board content absent while modal labels are present).
- Always run live app verification for gate/startup changes (see always-run-the-app-after-changes.md).
- Supplement with `record_demo` / `record_app` for human visual evidence when appropriate.

Minimal example pattern:
```julia
tb = T.TestBackend(80, 18)
T.reset!(tb.buf)
T.view(m, T.Frame(...))
@test T.find_text(tb, "EXPECTED") !== nothing
T.update!(m, T.KeyEvent('j'))
T.reset!(tb.buf); T.view(m, ...)
@test ...
```

See also:
- qci-kanban tests (runtests.jl for `visual_rows` + gate suites, test_board_render.jl, test_modal_move.jl)
- Official docs: https://kahliburke.github.io/Tachikoma.jl/dev/testing

## Report Structure
## Validation Report
### Checks Run
- command: ...
  exit: ...
  output: ...

### Failures (if any)
...

### Verdict
PASS / FAIL + next actions
```

Demand real execution evidence. 
