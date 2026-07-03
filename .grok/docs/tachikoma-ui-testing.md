# Tachikoma UI Testing & Visual Verification Methodology

**This is the authoritative reference for confirming that Tachikoma TUI visuals are correctly created in this repo.**

All agentic workflows (pipeline, tdd, test, review, always-run rule) must follow these practices for UI work.

## Core Principle

UI correctness is verified **deterministically and headlessly** using `Tachikoma.TestBackend`. You drive the Elm-style model with `update!`, re-render, then inspect the resulting buffer.

Never rely on "it looks right when I run it manually" as the primary proof. Always produce TestBackend evidence.

## The Standard Pattern (TestBackend + Re-render)

```julia
using Tachikoma as T

# 1. Create backend of appropriate size (80x18, 90x20, 100x20 common)
tb = T.TestBackend(80, 18)
T.reset!(tb.buf)

# 2. Render the model (or widget)
T.view(m, T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), [], []))

# 3. Inspect (these are the primary tools)
@test T.find_text(tb, "Backlog") !== nothing
@test T.find_text(tb, "QCI-") !== nothing
row = T.row_text(tb, 8)
@test row !== nothing && occursin("▶ ", row) || occursin("title", row)
ch = T.char_at(tb, 3, 4)
@test ch isa Char

# 4. Mutate via the public API, then re-render + re-assert
T.update!(m, T.KeyEvent('l'))
T.update!(m, T.KeyEvent('j'))
T.reset!(tb.buf)
T.view(m, ...)
@test T.find_text(tb, ...) !== nothing
```

**Always re-render after `update!` or `handle_key!` before asserting visuals.**

## Project Helper: visual_rows

Defined in test suites (copy or require the pattern):

```julia
function visual_rows(m; w::Int = 80, h::Int = 20)
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), [], []))
    [T.row_text(tb, i) for i in 1:h]
end

rows = visual_rows(m; w=82, h=18)
@test any(occursin("Backlog", r) for r in rows)
@test !any(occursin("NEW CARD", r) for r in rows)  # no bleed example
```

Use `visual_rows` for quick "content present/absent" checks across the full screen. Follow with targeted `TestBackend + find_text` for precision.

## Driving Full App Flows (The Killer Pattern)

For complex UIs and especially the **login gate**:

1. Start from a **raw model**:
   ```julia
   m = KanbanModel()
   m.db_path = ":memory:"
   QciKanban.load_users!(m)   # or the project's load path
   ```

2. Drive the create/login flow explicitly (no pre-seeded users assumption):
   ```julia
   T.update!(m, T.KeyEvent('c'))
   for ch in collect("TestUserName"); T.update!(m, T.KeyEvent(ch)); end
   T.update!(m, T.KeyEvent(:enter))
   ```

3. After every state change: re-render with TestBackend and assert the **new visual state**.

4. Common assertions:
   - Gate visible, board content absent (`"QCI-"`, column headers)
   - After successful create/login: board headers + cards present, gate gone
   - Modals: specific labels present (`"NEW CARD"`, `"PRIORITY:"`), board text absent (no bleed)

See `qci-kanban/test/runtests.jl` (login gate suite) and `test_board_render.jl`, `test_modal_move.jl` for real examples.

## Login Gate / First-Time User Experience (Mandatory)

Per AGENTS.md and `.grok/rules/always-run-the-app-after-changes.md`:

- Fresh `KanbanModel()` + `:memory:` + `load_users!` **must** yield zero users on first run.
- Screen must show: "No users — press [c] to create account"
- Only `c` + name + enter creates a user and logs in.
- Non-create keys must be ignored; `q` is the only way to quit from gate.
- After any change to `KanbanModel`, `load_users!`, view gate code, or seeding: **re-verify the exact first-time screen**.

Use both TestBackend assertions **and** the live app run.

## Overlay / Modal Correctness ("No Bleed")

When a modal, help screen, or picker is open:

- Board or previous view content **must not** appear under the overlay.
- Common pattern:
  ```julia
  @test T.find_text(tb, "QCI-") === nothing
  @test T.find_text(tb, "Backlog") === nothing || ...
  @test T.find_text(tb, "NEW CARD") !== nothing || T.find_text(tb, "HELP") !== nothing
  ```

Check with both `find_text` (whole screen) and `visual_rows`.

## Small Terminal Guards

Render at very small sizes (`TestBackend(18,4)`, `TestBackend(20,6)`) and ensure graceful behavior (no crash, some content or "small" guard text visible).

## Recordings for Human / Demo Visual Verification

Outside of strict unit tests, use recordings:

```julia
QciKanban.record_demo("my-demo.tach"; width=78, height=20, frames=72, fps=8)
# or directly
Tachikoma.record_app(model, filename; frames=..., events=scripted_events)
```

`.tach` files are useful for:
- Demo capture
- Visual regression outside CI
- Sharing exact sequences

## Live App Verification (Mandatory Rule)

After **any** change to `src/`, models, `update!`/`view`, login gate, DB seeding, or tests affecting startup:

1. Run verification expression using raw model + TestBackend gate checks.
2. Start the real TUI in a terminal:
   ```bash
   julia --project=. -e 'using QciKanban; QciKanban.kanban()'
   ```
3. Confirm you land on the **first-time LOGIN screen** with the exact message "No users — press [c] to create account" and **zero pre-seeded users**.
4. Exercise the create flow at least once.
5. Capture evidence (stdout + any `.tach` files).

See `.grok/rules/always-run-the-app-after-changes.md` for the exact command patterns.

## For TDD and Validation Workflows

- **Red**: Test writer must produce failing `TestBackend` + `find_text`/`row_text`/`visual_rows` tests.
- **Green**: Code must make those visual assertions pass.
- **Validate gate**: Re-run the TestBackend tests + full suite + coverage. UI changes require exercised inspection calls.
- 100% coverage expectation on changed UI logic/visual paths.

## Quick Checklist (use in reviews and validation)

- [ ] Started from raw model where gate matters?
- [ ] `update!` + re-render after every key action?
- [ ] `find_text` or `row_text` assertions present?
- [ ] No-bleed checks for modals/overlays?
- [ ] Small size guard tested?
- [ ] `visual_rows` used for full-screen presence/absence?
- [ ] Live app run performed for gate/startup changes?
- [ ] Recording captured when useful for visual proof?
- [ ] Tests use `:memory:` DBs for isolation?

## References

- Official Tachikoma testing docs: https://kahliburke.github.io/Tachikoma.jl/dev/testing
- AGENTS.md (Julia + Tachikoma Specific Rules + mandatory UI coverage)
- `.grok/rules/always-run-the-app-after-changes.md`
- qci-kanban `test/runtests.jl` (visual_rows definition + gate tests)
- Project test files: `test_board_render.jl`, `test_modal_move.jl`, `test_users.jl`, `test_calendar.jl`

This methodology makes agentic TUI development reliable and repeatable. Use it for every UI change.