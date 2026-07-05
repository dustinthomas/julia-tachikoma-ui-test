---
paths:
  - "**/*.jl"
---

# Julia + Tachikoma rules

- Always invoke Julia with `julia --project=.` (from the sub-project dir) or `--project=<subdir>` from the repo root.
- Tachikoma apps follow Elm: `mutable struct X <: Model`, `should_quit`, `update!(m, KeyEvent)`, `view(m, Frame)`. Business logic mutates the model only inside `update!`; views are pure renders.
- **All UI verification is headless and deterministic** via `Tachikoma.TestBackend` — never "run it and look":

```julia
tb = T.TestBackend(80, 20)
T.reset!(tb.buf)
T.view(m, T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), [], []))
@test T.find_text(tb, "Backlog") !== nothing   # also: row_text, char_at
T.update!(m, T.KeyEvent('l'))                   # drive via public API only
T.reset!(tb.buf); T.view(m, ...)                # ALWAYS re-render after update! before asserting
```

- Drive flows exclusively through `update!(m, KeyEvent(...))` — never mutate model fields the user couldn't reach.
- Tests use `:memory:` DBs and go through the real login gate; use `fresh_logged_model()` from `test/runtests.jl`. Login-gate tests start from a raw model and assert the exact zero-users first-run screen.
- Modals/overlays need "no bleed" assertions (assert absent text via `visual_rows`).
- Property-based tests with Supposition.jl are encouraged for layout/unicode edge cases.
- Full methodology reference (read when doing substantial UI work, not needed for small tweaks): `.grok/docs/tachikoma-core.md` and `.grok/docs/tachikoma-ui-testing.md`. Kanban feature roadmap: `.grok/docs/kanban-beauty-plan.md`.
