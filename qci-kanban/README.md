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

v2 stores data in `~/.qci-kanban/users.db` and `~/.qci-kanban/board.db`, and
persists a session token to `~/.qci-kanban/session.jwt` (0600). First launch
shows the login gate: **no users → press `[c]` to create an account**.

Demo board seeding (issues/epics/sprints/labels — **never users**) is controlled
by `AppConfig.seed_demo` (default **true** for local demo ergonomics). Plant /
production installs should set `seed_demo = false` via
`config/maintenance.toml.example` or `QCI_SEED_DEMO=0` so the board stays empty.
New projects can receive ops labels (PM/CM/Safety/Critical) when
`seed_ops_labels = true` (default) via the app-layer create helper.

### Rich playground seed (multi-project, people, 3+ months)

For a fuller sandbox (7 people, 4 projects, ~60 dated issues spanning ~4 months
for board / calendar / Gantt play):

```bash
julia --project=. scripts/seed_playground.jl          # additive / idempotent
julia --project=. scripts/seed_playground.jl --fresh   # wipe DBs, then seed
# login: alex@qci.demo / demo
```

Projects: **QCI** (product), **MNT** (plant maintenance WOs), **RND** (firmware),
**OPS** (line ops). Does not change the tiny default `seed_demo!` used by tests.

## Features

- **Auth** — email + password sign-in against a separate user store (PBKDF2-SHA256
  hashing), HS256 JWT sessions with expiry, create-account flow, session restore
  on startup, log out from anywhere (`O` or `Ctrl-L`).
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
- **Calendar** — month grid, due-date badges, day drill-down, month nav;
  `n` new (due = day), `e` edit day's issue, `v`/Enter details.
- **Gantt** — timeline bars from `start_date → due_date` with full modern visual polish (PR1–PR6), today marker, day/week/month
  zoom, horizontal scroll; `e` edit selected row, `v`/Enter details.
  See "Gantt visuals" table below for weekend shading, ruler/axis/today, bar ends/density/labels, selection+indents, footer+rich empty, sprint/legend/fallbacks.
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
| `P` | Switch project |
| `R` | Soft refresh (reload projects, re-clamp selection) |
| `O` / `Ctrl-L` | Log out (`O` preferred — many terminals steal Ctrl-L as clear-screen) |

### Board
| Key | Action |
|-----|--------|
| `h j k l` / arrows | Move selection |
| `s` | Cycle swimlanes · `t` Stats strip |
| `n` new · `e` edit · `d` delete · `v`/`Enter` details |
| `a` | Assign to me |
| `<` / `>` | Move to prev/next status |
| `J` / `I` | Rank down/up |
| `Spc` | Toggle select · `M` bulk move · `A` bulk assign · `D` bulk delete |
| `/` | Search |
| `m` mine · `H` high · `u` due-soon · `p` sprint · `#` label | Quick filters |

> `K` always opens Backlog (including from the board). Rank uses `J` / `I`.

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
| `e` | Edit first issue due on selected day (no-op if none) |
| `v`/`Enter` | Day's card details |

### Gantt
| Key | Action |
|-----|--------|
| `h`/`l` or arrows | Scroll timeline |
| `j`/`k` or arrows | Move row |
| `z` | Zoom day/wk/mo |
| `e` | Edit selected row's issue (no-op if none) |
| `v`/`Enter` | Details |

### Gantt visuals (PR1–PR6)

| PR | Feature | Visual elements (modern TUI Gantt) |
|----|---------|------------------------------------|
| PR1 | Weekend shading + week-separator grid lines | `░` (dim, muted) shading on Sat/Sun columns for all grid rows; `┆` (dim) vertical week-boundary separators drawn before bars (sprint band row also shaded for consistency). |
| PR2 | Ruler/axis + today marker + layout accounting | Dedicated ruler row (h ≥ 8): month spans (e.g. "Mar 2026") + `┬` week ticks via `gantt_axis_labels`; today upgraded to `▼` (band) + thick `┃` (or fallback) + optional "TODAY" label (primary_hi); adaptive `has_ruler`/`has_footer` + nshow math; guards for h=6/8/10, w<60. |
| PR3 | Refined bar ends, status density fills, inside labels | BlockCanvas base `█` preserved; post-overlay `▌`/`▐` end-caps; `▓` density portion (status map: Done=1.0 full, Review=0.85, In Progress=0.55, else ~0.25); short key/title inside when bar wide (≥4–5 cols) using dim (or primary_hi bold when selected row). |
| PR4 | Selection accent on bars + improved epic hierarchy indents | Selected row accents bar (hi-contrast left/end or segment via priority/epic tint); epic rows `▬ ` (epic_color, bold); issues under use tree indents (`  ├─ ` / `  └─ ` style) for visual hierarchy on j/k navigation. |
| PR5 | Selected-item footer details + richer empty state | When h≥10 + rows fit: 1-line footer e.g. `QCI-123: 2026-03-12 → 2026-03-16 (5d) • In Progress • High • Alice` (dim text, priority_color on pri); empty state richer + hint "(press e on board or n on calendar to date items)". Responsive hide on narrow. (Gantt also binds `e` → edit selected issue — same as Board/Backlog.) |
| PR6 | Sprint band polish + responsive label width + legend + unicode fallbacks | Sprint bands improved (edges/position/underline); adaptive left label width `gantt_left_width` (14–24 cols based on content, min chart guarantee); compact legend in header/scale; unicode fallbacks (e.g. ┃→│, ┆→|, ▓→#, ▌→[, ▐→], ┬→+ for w<60 or font issues); narrow TestBackend cases. |

All visuals are additive, 100% TestBackend-covered (re-render + `find_text`/`row_text`/`char_at`/`maxrun`/`visual_rows` after every `update!`), use only theme accessors (no raw ColorRGB), preserve public `render_gantt!` + key contract. See `src/ui/gantt.jl`, `test/test_gantt.jl`, `test/features/phase4_timeline.jl`.

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
- **Seed controls** — `seed_demo` (bool, default true; ENV `QCI_SEED_DEMO`) gates
  software-demo issues on `kanban2()` / `AppModel`. `seed_ops_labels` (default true)
  seeds PM/CM/Safety/Critical labels after app-layer project create (not inside
  the store). See `config/maintenance.toml.example` for a plant template
  (`seed_demo = false`, 8h TTL).
- **SMTP notifications** — off by default (`NullNotifier`). Enabling `[smtp]` in
  config routes domain events (assigned / status-changed / comment / due-soon)
  through the outbox and `SMTPClient`. Until then nothing sends email.

## Manufacturing / plant install

For shop-floor maintenance boards (not the software-demo seed):

1. **Config template** — copy and point `kanban2` at it:

   ```bash
   mkdir -p ~/.qci-kanban
   cp config/maintenance.toml.example ~/.qci-kanban/config.toml
   # edit paths / TTL as needed, then:
   julia --project=. -e 'using QciKanban; QciKanban.kanban2(; config_path=expanduser("~/.qci-kanban/config.toml"))'
   ```

   Or override only the seed flag: `QCI_SEED_DEMO=0 julia --project=. -e 'using QciKanban; QciKanban.kanban2()'`.

2. **Recommended plant values** (`config/maintenance.toml.example`):
   - `seed_demo = false` — empty board on first open (no software-demo issues).
   - `seed_ops_labels = true` — new projects get PM / CM / Safety / Critical labels.
   - `token_ttl_seconds = 28800` — 8-hour shop sessions (code default is 7 days).
   - `velocity_unit = "points"` — burndown/velocity prefer story points.
   - Optional future (see H1 roles/idle PR when merged): `idle_logout_seconds`,
     `enforce_roles` — **not present in this build**; document only when those
     config fields exist.

3. **SQLite on local disk only** — v2 opens with `PRAGMA journal_mode=WAL` and
   `busy_timeout=5000` for light multi-seat use on the **same host**. Do **not**
   put `users.db` / `board.db` on NFS or other network filesystems (WAL is unsafe
   there). Multi-host → Postgres remote backend, not shared SQLite.

4. **Backup before upgrades**:

   ```bash
   cp -a ~/.qci-kanban ~/.qci-kanban.bak-$(date +%Y%m%d)
   ```

5. **Shared kiosk / multi-user seat**:
   - `O` (or `Ctrl-L`) log out between operators.
   - Per-seat session file via `session_token_path` / `QCI_SESSION_TOKEN_PATH`
     so two terminals do not clobber the same JWT file.
   - Soft refresh `R` after another seat writes (reloads project cache + clamps
     selection; does not re-seed or restart).

6. **Ops keys**: `P` project switcher · `E` export CSV (Backlog) · `R` refresh ·
   `O` / `Ctrl-L` logout. Work-order fields (`asset_tag`, `location`, `work_type`) live
   on the card create/edit form.

## Demo recording

```bash
# v2 scripted tour → qci-kanban-v2-demo.tach (gate → account → board → swimlanes
# → card detail + comment → stats → edit → project switcher → calendar/e →
# backlog/start-sprint → gantt/e → soft refresh R → board)
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
