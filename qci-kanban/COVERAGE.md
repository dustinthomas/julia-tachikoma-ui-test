# Coverage policy — QCI Kanban v2

Phase 1 target: 100% line coverage of the new `src/` infrastructure files,
measured with

```bash
julia --project=. --code-coverage=user test/runtests.jl
# then analyse *.cov with Coverage.jl and delete them
```

## Documented exclusions

Only code that cannot run in the headless test environment is excluded. Each
excluded region is bracketed with `# COV_EXCL_START` / `# COV_EXCL_STOP`
comments in-source so the exclusion is auditable.

| File | Region | Why excluded |
|------|--------|--------------|
| `src/store/remote_store.jl` | `libpq_exec`, `connect_remote`, `RemoteUserStore(::AppConfig)`, `RemoteBoardStore(::AppConfig)` | Require a live PostgreSQL server + LibPQ connection. All SQL-building and row-mapping logic they feed is in pure functions covered 100% via `FakeExec`. |
| `src/notify/smtp.jl` | `SMTPTransport`, `SMTPTransport(::SmtpConfig)`, `send_mail(::SMTPTransport, …)` | Require a live SMTP server. The `SMTPNotifier` delivery path is fully covered via `FakeTransport`; the real transport is a thin SMTPClient shim. |

Everything else in the Phase 1 files (`domain.jl`, `config.jl`,
`auth/{password,jwt,session}.jl`, `store/{interface,sqlite_store}.jl`,
`store/remote_store.jl` pure functions, `notify/{interface,outbox}.jl`,
`notify/smtp.jl` fake path) is exercised by the test suite.

Pre-existing v1 files (`src/QciKanban.jl`, `src/db.jl`) are outside Phase 1
scope and are covered by the pre-existing v1 test suite.

## Phase 5 exclusions (graphics polish)

Phase 5 files (`src/gfx/logo.jl`, `src/gfx/charts.jl`) are exercised by
`test/test_gfx.jl`. `charts.jl` is fully covered. The only exclusions are glue
that cannot run under `TestBackend`:

| File | Region | Why excluded |
|------|--------|--------------|
| `src/gfx/logo.jl` | `_render_pixel_logo!` body + the `graphics_protocol() != gfx_none` branch in `render_qci_logo_v2!` (`# COV_EXCL_START/STOP`) | The kitty/sixel PixelCanvas path only runs on a graphics-capable terminal; `TestBackend` always reports `gfx_none`. The non-pixel canvas layer draws the identical geometry and is fully covered. |
| `src/ui/app.jl` | `export_gif_from_snapshots(...)` in `_export_demo` (`# COV_EXCL_LINE`) | Reached only when the optional GIF extension is loaded (`gif_extension_loaded()`), which is not a project dependency and is `false` headlessly. The SVG export path and the guarded `catch` are covered. |

Everything else added in Phase 5 (`spinner_glyph`, the canvas/text logo layers,
animation-gated glow/spinner, `column_counts`, `render_board_stats!`,
`burndown_series`, `render_burndown!`, `_toggle_stats!`, the `render_board!` /
`render_backlog!` wrappers, `record_demo2`, `_export_demo` svg+catch, and the
`t → :toggle_stats` binding) is exercised by the test suite.

## Startup-latency (TTFX) exclusion

| File | Region | Why excluded |
|------|--------|--------------|
| `src/precompile.jl` | Entire file (`# COV_EXCL_START/STOP`) | PrecompileTools workload: the `@compile_workload` body executes only while `Pkg.precompile` generates the pkgimage, never at runtime, so no coverage run can observe it. It re-drives the same headless tour the covered `record_demo2` and the test suite already exercise; any breakage in it fails package precompilation (and therefore every test run) loudly. |

## Phase 6 — coverage gate + final review

`test/coverage_gate.jl` is the machine-checked gate. It measures per-file line
coverage over ALL of `src/` with Coverage.jl, honours the in-source
`# COV_EXCL_START/STOP` and `# COV_EXCL_LINE` markers (plus the empty
`EXPLICIT_EXCLUSIONS` hook), REPORTS the v1-legacy files, and GATES the v2 files
at 100% — exiting nonzero with a per-file uncovered-line report otherwise.

### Running the gate

```bash
# One shot: run the suite under coverage, analyse, gate, clean up *.cov.
julia --project=. test/coverage_gate.jl

# Analyse *.cov produced by a prior run (skip the subprocess). Scope
# instrumentation to src/ so no *.cov leaks into test/ or the depot:
julia --project=. --code-coverage=@src test/runtests.jl
julia --project=. test/coverage_gate.jl --no-run
```

Coverage.jl is a test-only extra, so it is not on the load path under
`--project=.`; the gate transparently adds it to a throwaway environment
(offline, from the depot). The subprocess run uses `--code-coverage=@src` so the
only `*.cov` produced are under `src/`, and all are deleted on exit.

### Gated v2 files — 100% (final)

| File | cov/total |
|------|-----------|
| `domain.jl` | 43/43 |
| `config.jl` | 66/66 |
| `auth/jwt.jl` | 19/19 |
| `auth/password.jl` | 31/31 |
| `auth/session.jl` | 35/35 |
| `store/interface.jl` | 26/26 |
| `store/sqlite_store.jl` | 259/259 |
| `store/remote_store.jl` | 173/173 |
| `notify/interface.jl` | 27/27 |
| `notify/outbox.jl` | 11/11 |
| `notify/smtp.jl` | 11/11 |
| `ui/theme.jl` | 21/21 |
| `ui/focus.jl` | 46/46 |
| `ui/keymap.jl` | 35/35 |
| `ui/widgets.jl` | 68/68 |
| `ui/board.jl` | 344/344 |
| `ui/backlog.jl` | 100/100 |
| `ui/modals.jl` | 225/225 |
| `ui/calendar.jl` | 75/75 |
| `ui/gantt.jl` | 134/134 |
| `ui/app.jl` | 436/436 |
| `gfx/logo.jl` | 44/44 |
| `gfx/charts.jl` | 50/50 |

### v1-legacy files — reported, never gated

Per CLAUDE.md the v1 prototype (`src/QciKanban.jl`, `src/db.jl`) is untouched and
outside the v2 coverage contract. The gate measures and reports them but does not
gate on them: `QciKanban.jl` ≈ 807/965 (83.6%), `db.jl` ≈ 100/102 (98.0%).

### Phase 6 exclusion added

| File | Region | Why excluded |
|------|--------|--------------|
| `src/ui/app.jl` | `kanban2(...)` entry point (`# COV_EXCL_START/STOP`) | Live terminal loop glue: constructs the real-DB `AppModel` and hands off to Tachikoma's interactive `app` run loop, which requires a live terminal and never returns under headless tests. The scripted headless tour (`record_demo2`) exercises the same rendering/update paths and is fully covered; `AppModel` construction is covered by every UI test. |

No `EXPLICIT_EXCLUSIONS` entries were needed — the sole added exclusion is an
auditable in-source marker.

### Note — no exclusion for the `focusable` trait methods

`Tachikoma.focusable(::Selector)` / `(::MultiSelect)` are exercised by
`test/test_widgets.jl`, but as single-line literal-returning methods Julia emits
no coverage-trackable lowered code for them (the call constant-folds), so the
definition line never registered a hit. Rather than exclude tested code, they
were rewritten in multi-line `function … return true … end` form, which Coverage
tracks correctly — both now count as genuinely covered (no marker).
