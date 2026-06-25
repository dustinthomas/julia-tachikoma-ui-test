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
3. Identify and run **targeted** tests for the modified code. Prefer tests that use Tachikoma.TestBackend.
4. If no targeted tests exist or change is new (especially UI/view/update!), write or update tests that cover the behavior using TestBackend + handle_key! + direct update!.
5. Run full relevant suite only when requested.
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

## Tachikoma Testing Patterns (MANDATORY for UI work)
Use the excellent headless support:
- `tb = Tachikoma.TestBackend(w, h); render_widget!(tb, widget)`
- Inspect: `char_at(tb, x, y)`, `row_text(tb, y)`, `find_text(tb, "label")`, `style_at(...)`
- Simulate: `handle_key!(widget, KeyEvent(:down))` then re-render and assert
- App logic: direct `update!(model, KeyEvent(...))` then check fields + view
- Property tests with Supposition.jl for robustness (layouts, unicode, empty cases)

See test/test_tachikoma_basics.jl for patterns and the official docs: https://kahliburke.github.io/Tachikoma.jl/dev/testing

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
