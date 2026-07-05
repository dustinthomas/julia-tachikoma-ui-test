# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

QCI Kanban — a Jira-grade Kanban TUI (board + backlog/sprints + calendar + Gantt, real login, SQLite/Postgres persistence, notifications) built with **Tachikoma.jl**. It is a self-contained Julia sub-project (own `Project.toml`) inside the parent repo `julia-tachikoma-ui-test`, which holds the broader agentic setup and reference docs.

**Two apps ship side by side.** `kanban2()` is the current **v2** app (modular `src/ui/`, `src/store/`, `src/auth/`, `src/notify/`, `src/gfx/`). `kanban()` is the original **v1** prototype, kept intact and green (single-file `src/QciKanban.jl` + `src/db.jl`). New work targets v2; do not touch v1.

## Commands

Run from this directory (`qci-kanban/`); from the parent repo use `--project=qci-kanban` instead of `--project=.`.

```bash
# Full test suite
julia --project=. -e 'using Pkg; Pkg.test()'
# or directly (faster iteration, skips Pkg resolution)
julia --project=. test/runtests.jl

# Run v2 (real terminal; DBs at ~/.qci-kanban/{users,board}.db, demo board seeded — never users)
julia --project=. -e 'using QciKanban; QciKanban.kanban2()'

# Run v1 prototype
julia --project=. -e 'using QciKanban; QciKanban.kanban()'

# Headless demo recording (produces a .tach file; read back via Tachikoma.load_tach)
julia --project=. -e 'using QciKanban; QciKanban.record_demo2("qci-kanban-v2-demo.tach")'   # v2 scripted tour (+ svg=true for SVG)
julia --project=. -e 'using QciKanban; QciKanban.record_demo("demo.tach"; frames=80, fps=8)' # v1

# Coverage (Phase 6 gate): analyze .cov after a coverage run
julia --project=. --code-coverage=user test/runtests.jl
```

Single test file: `test_db.jl` is standalone (`julia --project=. test/test_db.jl`). The UI test files (`test_board_render.jl`, `test_modal_move.jl`, `test_users.jl`, `test_calendar.jl`) depend on helpers defined at the top of `test/runtests.jl` (`visual_rows`, `board_after_keys`, `fresh_logged_model`) — run them through `runtests.jl`, or paste those helpers first when running one in isolation.

## Architecture

The `QciKanban` module (`src/QciKanban.jl`) hosts both apps. It includes the v1 code inline, then the v2 submodules/files, wires branding, and exports both entry points (`kanban`, `kanban2`).

### v2 (current) — `AppModel`, entry `kanban2()`

Elm-style single `AppModel <: Model` (`src/ui/app.jl`) wired to Phase 1 infrastructure. Layout mirrors `DESIGN.md`:

- `src/domain.jl` — pure types (`Issue`, `Epic`, `Sprint`, `Comment`, `Label`, …); `Domain.STATUSES`.
- `src/config.jl` — `AppConfig` (db paths, JWT secret/TTL, SMTP) from TOML + ENV.
- `src/auth/{password,jwt,session}.jl` — PBKDF2-SHA256 hashing, HS256 JWT, session restore/persist.
- `src/store/{interface,sqlite_store,remote_store}.jl` — `AbstractUserStore`/`AbstractBoardStore`; SQLite (separate `users.db`/`board.db`) + LibPQ Postgres adapter. `Stores.seed_demo!` seeds **issues/epics/sprints/labels, never users**.
- `src/notify/{interface,outbox,smtp.jl}` — pluggable notifiers (Null default, Outbox, SMTP-gated).
- `src/ui/theme.jl` (`module Theming`) — QCI palette; **the only file with raw `ColorRGB`** (test-enforced grep over `src/ui/`). Use accessors (`col_primary()`, `priority_color(p)`, …) everywhere else.
- `src/ui/focus.jl` + `src/ui/keymap.jl` — focus router (focused editor wins) + declarative `KEYMAP` data; help overlay and status hints are **generated** from the table (`help_lines`, `status_hints`).
- `src/ui/{board,backlog,calendar,gantt,modals,widgets}.jl` — the views + modals.
- `src/gfx/logo.jl` — layered QCI logo: PixelCanvas (kitty/sixel, gated on `graphics_protocol()`) → braille/block vector art → text fallback, all one footprint. `render_qci_logo_v2!` is called from the app header.
- `src/gfx/charts.jl` — board **stats strip** (`column_counts`, `render_board_stats!` — sparkline + WIP gauge, toggle `t` → `show_stats`) and **burndown** (`burndown_series` pure + `render_burndown!` in the backlog footer).

Dispatch order in `update!(m, evt)`: focused editor → modal → view → global, via `context_stack(m)` + `lookup_action`. **Login gate**: until `m.current_user` is set only the login/create-account context works; first-run shows "No users — press [c] to create account". Board state: `swimlane_by`, `sel_lane/sel_col/sel_idx`, `selected_ids`, `active_filters`, `wip_limits`, `show_stats`. The board grid renders bordered swimlane panels + bordered task cards (selected card: bright border, raised bg, ▸ arrow on the frame); lanes too short for a bordered card degrade to flat cards so the cursor card is always visible (U5). Subtle animation (logo glow, login spinner, gauge shimmer) is gated by `animations_enabled()` so renders are byte-stable in tests.

`record_demo2(filename; svg=false, gif=false)` drives the scripted v2 tour headlessly and writes a `.tach` (SVG/GIF export guarded on extension availability).

### v1 (legacy, do not modify) — `KanbanModel`, entry `kanban()`

- `src/QciKanban.jl` — the original single-file Elm app (`KanbanModel`, monolithic `update!`/`view`), plus branding constants and both `record_demo`/`record_demo2`.
- `src/db.jl` — `DB` submodule (single-file SQLite, `QCI-NNN` keys, `seed_demo!` issues-only).

Branding assets (QCI navy/cyan, logo art) live in the parent repo's `branding/`; v1 includes `branding/qci-canvas-logos.jl` with silent text-art fallback.

## UI testing methodology (mandatory)

All UI verification is headless and deterministic via `Tachikoma.TestBackend` — never "run it and look". The authoritative references are in the parent repo and must be read before Tachikoma UI work:

- `../.grok/docs/tachikoma-core.md` — Tachikoma Elm architecture, model contract, widgets/layout
- `../.grok/docs/tachikoma-ui-testing.md` — the testing methodology below in full
- `../.grok/docs/kanban-beauty-plan.md` — feature roadmap when working on Kanban features
- `../AGENTS.md` — parent repo agentic rules

The standard pattern:

```julia
tb = T.TestBackend(80, 20)
T.reset!(tb.buf)
T.view(m, T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), [], []))
@test T.find_text(tb, "Backlog") !== nothing        # also: row_text, char_at
T.update!(m, T.KeyEvent('l'))                        # drive via public API only
T.reset!(tb.buf); T.view(m, ...)                     # ALWAYS re-render after update! before asserting
```

Rules that tests here enforce and new work must follow:
- Drive flows exclusively through `update!(m, KeyEvent(...))` — no direct mutation of model fields the user couldn't reach.
- Tests use `m.db_path = ":memory:"` for isolation and go through the real login gate (`load_users!` → `'c'` → typed name → `:enter`) to reach board state; use `fresh_logged_model()` from `runtests.jl`.
- Login-gate tests must start from a raw `KanbanModel()` and verify the exact zero-users first-time screen.
- Modals/overlays need "no bleed" assertions (assert absent text via `visual_rows`).
- Property-based tests with Supposition.jl are encouraged for layout/unicode edge cases.

**After any change to `src/`, DB seeding, the login gate, or `update!`/`view`**: run the full test suite AND a real app verification (live `kanban()` run, or `record_demo` headless) confirming the first-time login screen appears with zero pre-seeded users (see `../.grok/rules/always-run-the-app-after-changes.md`).
