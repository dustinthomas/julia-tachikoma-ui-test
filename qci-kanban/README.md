# QCI Kanban

A Jira-grade Kanban TUI built with **Tachikoma.jl** — real login, a swimlane
board, backlog/sprints, calendar, Gantt, and QCI-branded graphics. Two apps ship
side by side:

- **`kanban2()`** — the v2 app (this README). Separate user/board databases,
  real JWT auth, focus-routed input, declarative keymap, graphics-polished logo
  and stats. Source under `src/ui/`, `src/store/`, `src/auth/`, `src/notify/`,
  `src/gfx/`.
- **`kanban()`** — the original v1 prototype, kept intact for reference.

## Run

```bash
# v2 (recommended)
julia --project=. -e 'using QciKanban; QciKanban.kanban2()'

# v1 prototype
julia --project=. -e 'using QciKanban; QciKanban.kanban()'
```

v2 stores data in `~/.qci-kanban/users.db` and `~/.qci-kanban/board.db`, seeds a
demo board (issues/epics/sprints/labels — **never users**) on first run, and
persists a session token to `~/.qci-kanban/session.jwt` (0600). First launch
shows the login gate: **no users → press `[c]` to create an account**.

## Features

- **Auth** — email + password sign-in against a separate user store (PBKDF2-SHA256
  hashing), HS256 JWT sessions with expiry, create-account flow, session restore
  on startup, log out from anywhere (`Ctrl-L`).
- **Board** — status columns × swimlanes (`:none | :assignee | :epic | :priority`,
  cycle with `s`) as a real card grid; rich cards (key, wrapped title, priority
  glyph, points, label chips, epic tag, assignee initials, due chip); WIP limits
  with over-limit styling; quick filters, full-text search, bulk select + bulk
  ops; card create/edit/delete/move/rank/assign.
- **Card detail** — description, fields, comments thread (add via focused text
  area), activity tail.
- **Backlog** — backlog + sprint sections, create/start/close sprints (close rolls
  incomplete issues back), move issues backlog ↔ sprint; a **burndown** footer for
  the active sprint.
- **Calendar** — month grid, due-date badges, day drill-down, month nav.
- **Gantt** — timeline bars from `start_date → due_date`, today marker, week/month
  zoom, horizontal scroll.
- **Graphics polish (Phase 5)** — layered QCI logo (kitty/sixel pixel canvas when
  the terminal supports it, braille/block vector art otherwise, text fallback at
  tiny sizes), a board **stats strip** (per-column sparkline + WIP gauge, toggle
  `t`), subtle animation-gated cyan glow + login spinner.
- **Notifications** — pluggable infrastructure (Null / Outbox / SMTP notifiers);
  nothing sends email until enabled in config.

## Keys

Bindings are declarative data (`src/ui/keymap.jl`); the in-app help (`?`) and the
status-bar hints are generated from the same table, so they never drift. The
**focused-editor-wins** rule means typing in any field never triggers a shortcut.

### Global (post-login)
| Key | Action |
|-----|--------|
| `q` / `Ctrl-C` | Quit |
| `?` | Help overlay |
| `B` | Board · `K` Backlog · `C` Calendar · `G` Gantt |
| `Ctrl-L` | Log out |

### Board
| Key | Action |
|-----|--------|
| `h j k l` / arrows | Move selection |
| `s` | Cycle swimlanes · `t` Stats strip |
| `n` new · `e` edit · `d` delete · `v`/`Enter` details |
| `a` | Assign to me |
| `<` / `>` | Move to prev/next status |
| `J` / `K` | Rank down/up |
| `Spc` | Toggle select · `M` bulk move · `A` bulk assign · `D` bulk delete |
| `/` | Search |
| `m` mine · `H` high · `u` due-soon · `p` sprint · `#` label | Quick filters |

> On the board, `K` is rank-up (view bindings beat global); reach the Backlog with
> `K` from any *other* view.

### Backlog
| Key | Action |
|-----|--------|
| `j k` / arrows | Move selection |
| `n` | New sprint |
| `>` / `<` | Move issue to sprint / backlog |
| `S` / `X` | Start / close sprint |
| `v`/`Enter` details · `e` edit · `d` delete |

### Calendar
| Key | Action |
|-----|--------|
| `h`/`l` or arrows | Prev / next month |
| `j`/`k` or arrows | Next / prev day |
| `n` | New issue (due = selected day) |
| `v`/`Enter` | Day's card details |

### Gantt
| Key | Action |
|-----|--------|
| `h`/`l` or arrows | Scroll timeline |
| `j`/`k` or arrows | Move row |
| `z` | Zoom week/month |
| `v`/`Enter` | Details |

### Modals
- **Card detail**: type a comment, `Enter` to add, `Esc` to close.
- **Card create/edit**: `Enter` save, `Esc` cancel (Tab cycles focus-routed fields).
- **Confirm**: `y`/`Enter` yes, `n`/`Esc` no.
- **Search**: `Enter` apply, `Esc` clear.

## Configuration (auth, remote DB, notifications)

v2 reads an optional TOML config plus environment overrides (`src/config.jl`).
Defaults are test-safe and require no setup. Notable knobs:

- **Databases** — `user_db` / `board_db` paths default under `~/.qci-kanban/`.
  A PostgreSQL adapter (`src/store/remote_store.jl`, LibPQ) exists for the
  "larger system" deployment; SQLite is the default.
- **JWT** — a secret is generated and persisted on first run if absent; token TTL
  is configurable. Tests inject `secret` / `token_path` so they never touch `~`.
- **SMTP notifications** — off by default (`NullNotifier`). Enabling `[smtp]` in
  config routes domain events (assigned / status-changed / comment / due-soon)
  through the outbox and `SMTPClient`. Until then nothing sends email.

## Demo recording

```bash
# v2 scripted tour → qci-kanban-v2-demo.tach (gate → account → board → swimlanes
# → card detail + comment → stats → calendar → backlog/start-sprint → gantt)
julia --project=. -e 'using QciKanban; QciKanban.record_demo2("qci-kanban-v2-demo.tach")'

# with an SVG export alongside the .tach (GIF export if the extension is present)
julia --project=. -e 'using QciKanban; QciKanban.record_demo2("tour.tach"; svg=true)'

# v1 demo
julia --project=. -e 'using QciKanban; QciKanban.record_demo("demo.tach")'
```

`.tach` files replay with Tachikoma tooling and are read back in tests via
`Tachikoma.load_tach`.

## Tests & visual verification

All UI is verified **headlessly and deterministically** with `Tachikoma.TestBackend`
(`view` into a buffer, then `find_text` / `row_text` / `char_at` / `style_at`;
re-render after every `update!`). Animations are gated by `animations_enabled()`
so renders are byte-stable in tests.

```bash
julia --project=. test/runtests.jl          # fast
julia --project=. -e 'using Pkg; Pkg.test()' # full, with resolution
```

## Branding

QCI navy + cyan palette lives in `src/ui/theme.jl` (the single source of color;
no raw `ColorRGB` outside it — test-enforced). The v2 logo (`src/gfx/logo.jl`)
adapts the vector logomark from the parent repo's `branding/` assets.

## Project

Self-contained Julia sub-project (own `Project.toml`) inside
`julia-tachikoma-ui-test`. No changes required to the parent repo.
