# QCI Kanban

Jira-inspired Kanban TUI built with **Tachikoma.jl**.

- Board with 5 columns + keyboard move (h/l/j/k or arrows, < > for status)
- Card create ('n'), edit (Enter), delete ('d')
- Modal form (title + desc + priority 1/2/3)
- Calendar view ('c') using native Calendar widget + due marks
- User switching ('u') + assignee display on cards
- SQLite persistence (`~/.qci-kanban/kanban.db`)
- Full TestBackend coverage

## Run

```bash
julia --project=qci-kanban -e 'using QciKanban; QciKanban.kanban()'
```

## Visual verification & recordings

All UI uses **Tachikoma.TestBackend** (headless render + `row_text` / `find_text` / `char_at` + `update!` + re-render).

For demo / outside inspection:

```bash
julia --project=qci-kanban -e '
using QciKanban
QciKanban.record_demo("my-demo.tach"; frames=80, fps=8)
# produces my-demo.tach (playable with Tachikoma tooling or convert via record_gif)
'
```

See tests (e.g. `test_board_render.jl`) for examples using the `visual_rows` helper.

Keys (board):
- `h/l` or `←/→` : column
- `j/k` or `↑/↓` : card
- `<` / `>` : move card to prev/next column
- `n` : new card
- `Enter` : edit selected
- `d` : delete
- `r` : reload
- `u` : user picker
- `b/c/l` : switch view
- `q` / `Esc` : quit

Data is seeded on first run.

## Project

Self-contained. Separate `Project.toml`. No changes required to the parent repo.

Tests:
```bash
julia --project=qci-kanban -e 'using Pkg; Pkg.test()'
```

## Branding

Uses QCI navy + cyan from `branding/bg-light-top-right.png` in parent.
