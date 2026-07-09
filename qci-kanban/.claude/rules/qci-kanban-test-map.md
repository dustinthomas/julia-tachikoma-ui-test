---
paths:
  - "src/**"
  - "test/**"
  - "qci-kanban/src/**"
  - "qci-kanban/test/**"
---

# QCI Kanban test-impact map

Before changing a file under `qci-kanban/src/`, know which tests exercise it; after changing it, run those tests FIRST (fast feedback), then the full suite before claiming done. Evidence: supplying targeted test-impact context cut agent-caused regressions ~70% (TDAD, arXiv 2603.17973); procedural TDD instructions *without* this context made regressions worse.

Run from `qci-kanban/`: `julia --project=. test/runtests.jl` (full suite). Most UI test files depend on helpers defined at the top of `test/runtests.jl` (`visual_rows`, `board_after_keys`, `fresh_logged_model`) — run them through `runtests.jl`.

## v2 app (current — `kanban2()`)

| Source file | Primary tests | Also touched by |
|---|---|---|
| `src/domain.jl` | `test_domain.jl` (incl. `issues_to_csv`) | `test_stores.jl`, `test_gfx.jl` |
| `src/config.jl` | `test_stores.jl` | `test_notify.jl` |
| `src/auth/*` (password, jwt, session) | `test_auth.jl` | `test_fixwave.jl` |
| `src/store/*` (sqlite, remote, interface) | `test_stores.jl` | nearly all view tests (fixtures seed via Stores) |
| `src/notify/*` (outbox, smtp) | `test_notify.jl` | `test_card_modals.jl` |
| `src/ui/app.jl` (AppModel, dispatch, login gate, project switcher/create, CSV export) | `test_app_shell.jl`, `features/multi_project.jl`, `features/project_switcher_export.jl` | `test_fixwave.jl`, `test_focus.jl` |
| `src/ui/theme.jl` | `test_theme.jl` (incl. raw-ColorRGB grep enforcement) | — |
| `src/ui/focus.jl`, `src/ui/keymap.jl` | `test_focus.jl` | `test_app_shell.jl`, `features/project_switcher_export.jl` |
| `src/ui/board.jl` | `test_board_view.jl` | `test_focus.jl`, `test_notify.jl`, `test_stores.jl` |
| `src/ui/backlog.jl` | `test_backlog.jl` | `test_gfx.jl` (burndown footer), `features/project_switcher_export.jl` (E export) |
| `src/ui/calendar.jl` | `test_calendar_view.jl` | — |
| `src/ui/gantt.jl` | `test_gantt.jl` | — |
| `src/ui/modals.jl` | `test_card_modals.jl` | `test_backlog.jl`, `test_board_view.jl` (no-bleed), `features/project_switcher_export.jl` |
| `src/ui/widgets.jl` | `test_widgets.jl` | all view tests indirectly |
| `src/gfx/*` (logo, charts) | `test_gfx.jl` | `test_app_shell.jl` (header logo) |
| `src/precompile.jl` | none directly (precompile-time-only workload, coverage-excluded) — a broken workload fails `Pkg.precompile`, so any test run catches it | — |

## v1 app (legacy — `kanban()`, do not modify)

| Source file | Tests |
|---|---|
| `src/QciKanban.jl` (v1 KanbanModel/update!/view) | `test_board_render.jl`, `test_modal_move.jl`, `test_users.jl`, `test_calendar.jl` |
| `src/db.jl` | `test_db.jl` (standalone: `julia --project=. test/test_db.jl`) |

## Cross-cutting gates (any `src/` change)

- **Login gate / startup**: `test_app_shell.jl` + `test_users.jl` assert the exact zero-users first-run screen — run both if you touched seeding, auth, or `update!` dispatch.
- **Run-the-app gate**: after any change to `src/`, DB seeding, login gate, or `update!`/`view` — see the run-the-app rule; a live `kanban()`/`kanban2()` run or headless `record_demo`/`record_demo2` is mandatory.
- Keep this map current: when adding a source file or test file, add its row here in the same change.
