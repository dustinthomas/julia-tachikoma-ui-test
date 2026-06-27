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

On first launch (or no prior users) you see an explicit login picker or create form (with 'n' to create). Board is not shown/usable until you select or create a user. Last-used user is preselected (if `~/.qci-kanban/last_user` exists) but Enter is required.

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
- `<` / `>` : move card to prev/next column (adjacent)
- `m` : move to any lane (opens picker; j/k + enter)
- `n` : new card
- `Enter` : edit selected
- `d` : delete
- `r` : reload
- `u` : user picker (press 'n'/'c' inside to create new user)
- `b/c/l` : switch view
- `q` / `Esc` : quit

Keys (startup login / user picker):
- `j/k` or `↑/↓` : select user
- `Enter` : login / select
- `n` / `c` : create new user
- `q` / `Esc` : quit (or back from create)

Last user (if any) is pre-selected from `~/.qci-kanban/last_user` (for convenience); explicit `Enter` still required — no auto-login.

Data is seeded only on absolute first run (when both users and issues tables are empty on open). See last_user file note above.

## Project

Self-contained. Separate `Project.toml`. No changes required to the parent repo.

Tests:
```bash
julia --project=qci-kanban -e 'using Pkg; Pkg.test()'
```

## Branding

Uses QCI navy + cyan from `branding/bg-light-top-right.png` in parent.

Login screen shows dynamic "QCI KANBAN — LOGIN" title and tick-driven branding animation in `render_qci_logo`: stylized geometric box-drawing QCI mark, pulsing scan line (────/════), orbiting •○◉◎ decorations, and progressively typing "QCI KANBAN▌" tagline (lightweight, driven by m.tick). Animation visible only pre-login.

Release notes (PR6 polish): keys/Run updated for 'n' (picker create), last-user behavior (preselect + explicit confirm), branding animation (see above), clarified "seeded on first run" wording to "absolute first run", added note on `~/.qci-kanban/last_user`. Full test validation + manual smoke. record_demo and direct test paths unaffected.
