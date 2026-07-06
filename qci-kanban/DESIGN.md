# QCI Kanban v2 — Architecture & Design

Complete overhaul of the concept prototype into a Jira-grade Kanban TUI.
This document is the contract for all implementation phases. Sections marked
`[SCOUT]` are finalized from scouting reports before Phase 1 begins.

## Goals (from product owner)

1. Real user login; user data lives in a **separate user database** that can be
   part of a larger system → JWT auth + remote-DB-capable persistence.
2. Heavy Jira inspiration; all major standard board features.
3. Swimlanes that contain **actual cards** (lane × column grid of card cells),
   not a flat list.
4. QCI company theming (quantumcomputinginc.com palette).
5. Calendar view and Gantt chart view.
6. Email-notification infrastructure (pluggable, not yet activated).
7. Zero key-binding conflicts — typing in a field never triggers shortcuts.
8. Full use of Tachikoma's graphics & pixel rendering backend.
9. 100% test coverage on `src/`, TDD + BDD style, all UI verified headlessly
   via TestBackend.

## Module layout

```
src/
  QciKanban.jl          # module root: includes, exports, kanban() entry
  domain.jl             # pure types: User, Issue, Epic, Sprint, Comment, Label, ActivityEvent
  config.jl             # AppConfig: db backends, smtp, jwt secret; from TOML + ENV
  auth/
    password.jl         # PBKDF2-SHA256 salted hashing (SHA stdlib)
    jwt.jl              # real JWT (HS256) via JSONWebTokens.jl (v1.1.2), issue/verify with expiry
    session.jl          # login/logout/current-user; token persistence
  store/
    interface.jl        # AbstractUserStore + AbstractBoardStore APIs
    sqlite_store.jl     # local impl; users.db SEPARATE from board.db
    remote_store.jl     # PostgreSQL adapter via LibPQ.jl (v1.18, verified installable)
  notify/
    interface.jl        # AbstractNotifier + NotificationEvent types
    outbox.jl           # durable outbox table; enqueue on domain events
    smtp.jl             # SMTPNotifier (config-gated); NullNotifier default
  ui/
    theme.jl            # QCI palette [SCOUT], Style helpers
    focus.jl            # focus router — the no-conflict keymap core
    keymap.jl           # declarative bindings per (view, modal, focus) context
    app.jl              # AppModel, update!, view, should_quit
    views/board.jl      # columns × swimlanes card grid
    views/backlog.jl    # backlog + sprint planning
    views/calendar.jl   # month calendar + due cards
    views/gantt.jl      # Gantt timeline [SCOUT: canvas APIs]
    modals/…            # card detail, create/edit, user picker, help, confirm
  gfx/
    logo.jl             # pixel/kitty/sixel QCI logo w/ text-art fallback
    charts.jl           # sparklines/gauges/burndown helpers
```

## Data model (Jira-inspired)

Separate stores, separate databases:

**UserStore** (`users.db` locally; remote in the larger system):
- `users(id, email, name, password_hash, salt, created, active)`
- Auth API: `authenticate(store, email, password) → User | nothing`,
  `create_user!`, `get_user`, `list_users`.

**BoardStore** (`board.db`):
- `issues(id, key, title, description, status, priority, story_points,
  epic_id, sprint_id, assignee_id, reporter_id, start_date, due_date,
  position, created, updated)`
- `epics(id, key, name, color, created)`
- `sprints(id, name, goal, start_date, end_date, state)`  — state: future/active/closed
- `labels(id, name, color)` + `issue_labels(issue_id, label_id)`
- `comments(id, issue_id, author_id, body, created)`
- `activity(id, issue_id, actor_id, kind, detail, created)` — audit log
- `outbox(id, event_kind, recipient_email, subject, body, created, sent_at)`

`assignee_id`/`reporter_id` reference users **by id only** — no FK across
databases; the board store never joins into the user store.

## Auth flow

1. Login screen: email + password fields (real focus routing).
2. `authenticate` against UserStore → PBKDF2 verify → issue JWT (HS256,
   configurable secret + expiry, `sub`=user id, `name`, `exp`).
3. Token held in model; persisted to `~/.qci-kanban/session.jwt` (0600) for
   re-login; verified (signature + expiry) on startup — invalid → login screen.
4. Create-account flow from login screen (kept from v1, now with password).
5. Until authenticated: only login-screen keys work; everything else inert.

## Key routing — the no-conflict contract

Single dispatch order in `update!(m, evt)`:

1. **Focused editor wins.** If any TextInput/TextArea is focused, the event
   goes to `handle_key!(input, evt)` first. Printable chars, backspace,
   arrows-in-text NEVER reach shortcuts. Only `Esc` (unfocus/cancel) and
   `Tab`/`Shift-Tab` (move focus) and `Enter` (commit, context-defined) are
   intercepted before the input.
2. **Modal handler.** An open modal consumes everything except what it
   explicitly delegates; board underneath receives nothing.
3. **View handler.** Active view (board/backlog/calendar/gantt) bindings.
4. **Global bindings.** View switching, help, quit.

Bindings are **declarative data** (`keymap.jl`): context → key → action name.
Tests assert the contract property-style: for every focused-input context,
feeding any printable char changes only the input's text, never view state
(Supposition.jl generator over chars × contexts).

## Views

- **Board**: Jira board. Columns = statuses (Backlog/To Do/In Progress/Review/Done).
  Swimlanes = `:none | :assignee | :epic | :priority`; each swimlane is a
  horizontal band containing REAL card cells per column (multi-line rich cards:
  key, title, priority glyph, points, labels, avatar initials, due chip).
  Selection is (lane, column, card). WIP limits per column with over-limit
  styling. Quick filters (Mine / High / Due Soon / label), full-text search.
  Bulk select + bulk move/assign. Card ops: create, edit, delete (confirm),
  move (< >), rank up/down, assign, watch.
- **Card detail modal**: description, epic, sprint, points, labels, dates,
  reporter/assignee, comments thread (add comment), activity tail.
- **Backlog**: sprint list + backlog grooming — create sprint, drag issues
  between backlog and sprints (keyboard), start/close sprint.
- **Calendar**: month grid, due-date badges, day drill-down list, navigation.
- **Gantt**: horizontal timeline; issue/epic bars from `start_date→due_date`,
  today marker, sprint bands; zoom week/month. Bars via `BlockCanvas`
  (quadrant blocks, gap-free, same API as braille `Canvas`: `set_point!`,
  `line!`, `rect!`) — renders into ordinary text cells, so fully
  TestBackend-assertable. Pixel backends are Phase 5 polish only.
  **PR1–PR6 visual completion** (see README "Gantt visuals" table):
  weekend shading, ruler/axis/today, bar ends/density/labels, selection+indents,
  footer+rich empty, sprint/legend/fallbacks + responsive. (Foundation in
  PHASES.md:149-158; no data model or public API changes.)
- **Help** overlay generated from the declarative keymap (always accurate).

## Theme (final)

quantumcomputinginc.com is a minimal light site; its brand identity is the
QCI cyan + navy (confirmed in `../branding/` assets). Terminal apps read best
dark, so the TUI is a dark navy theme with cyan as the brand accent:

| role        | rgb             | use |
|-------------|-----------------|-----|
| bg          | (13, 17, 33)    | app background wash |
| surface     | (24, 28, 52)    | cards, modals |
| surface_hi  | (30, 32, 75)    | raised/selected surfaces (QCI navy) |
| primary     | (0, 188, 212)   | QCI cyan — borders, titles, selection accents |
| primary_hi  | (77, 216, 235)  | hover/active accent |
| text        | (230, 237, 243) | primary text |
| text_dim    | (140, 150, 180) | secondary text |
| text_muted  | (100, 110, 165) | hints, inactive |
| ok          | (78, 204, 94)   | success, Low priority |
| warn        | (240, 198, 116) | warnings, Medium priority |
| err         | (224, 60, 49)   | errors, High priority, overdue |
| sel         | cyan-on-navy    | selection style |
| epic ramp   | violet/teal/orange/pink/blue | epic tags, 5-color cycle |

Single `theme.jl`; no raw `ColorRGB` literals outside it (test-enforced).

## Tachikoma API notes (verified against installed v2, `~/.julia/packages/Tachikoma/35crv`)

- **Focus**: `FocusRing` + `Container` + `focusable` + `handle_key!` exist —
  build `ui/focus.jl` on `FocusRing` (`next!`/`prev!`/`current`) instead of
  hand-rolled flags.
- **Forms**: `Form`/`FormField`, `DropDown`, `Checkbox`, `Button` — use for the
  card edit modal (priority/epic/sprint selectors as DropDowns; no more
  global 1/2/3).
- **Board/data**: `SelectableList`, `DataTable`, `TabBar`, `ScrollPane`,
  `Modal`, `Paragraph` (word_wrap for card titles).
- **Charts**: `Gauge`, `Sparkline`, `BarChart`, `Chart` for board stats and
  burndown.
- **Graphics**: `Canvas` (braille 2×4 dots/cell), `BlockCanvas` (quadrant),
  `PixelCanvas`/`PixelImage` + `GraphicsProtocol` (kitty/sixel with
  `gfx_none` fallback) for the Phase 5 logo.
- **Testing**: TestBackend also exposes `style_at` — color/style assertions
  are possible and REQUIRED for theme-critical elements (priority colors,
  over-WIP styling, selection).
- **Demos**: `EventScript` (`key`, `chars`, `seq`, `Wait`) + `record_app` /
  `record_gif` / `export_svg` for the scripted tour.
- **Deps to add** (all verified installing + loading cleanly): JSONWebTokens
  1.1.2, SHA, LibPQ 1.18, SMTPClient 0.6.5; test-only: Coverage 1.7 (+
  existing Supposition). TOML config via stdlib `TOML`. HTTP/JSON3 not needed.

## Notifications

Domain events (issue assigned, status changed, comment added, due-soon) →
`notify!(notifier, event)`. Default `NullNotifier` (logs to activity only).
`OutboxNotifier` writes durable rows; a `flush_outbox!(smtp_notifier)` sends
via SMTPClient when config enables it. Nothing sends email until
`[smtp] enabled=true` in config. All infrastructure fully tested with a
`FakeTransport`.

## Testing strategy

- **TDD**: every slice lands as failing test → minimal code → refactor.
- **BDD**: acceptance specs in `test/features/*.jl` written as
  Given/When/Then nested testsets driving the app purely via
  `update!(m, KeyEvent(...))` + TestBackend assertions.
- **Unit**: store, auth, notify, domain — direct, `:memory:` SQLite.
- **UI**: TestBackend render + `find_text`/`row_text`/`char_at`, presence AND
  absence (no-bleed), multiple sizes incl. tiny; re-render after every event.
- **Property**: Supposition.jl for key-routing no-conflict contract, layout
  at arbitrary sizes, unicode titles.
- **Coverage**: `Pkg.test(coverage=true)` + Coverage.jl gate script
  (`test/coverage_gate.jl`) failing under 100% of `src/` lines (with a
  documented, minimal exclusion list only for terminal-only entry glue like
  `kanban()`'s live loop, which is exercised by `record_demo` instead).
- **Live rule**: after any change to src/, run the app (or `record_demo`)
  and verify the first-run login screen per `.grok/rules/always-run-the-app-after-changes.md`.

## Delegation model

Fable (this session): architecture, creative direction, phase orchestration,
adversarial review of every phase diff, final verification. Opus subagents:
implementation of each phase strictly against this document, TDD, returning
diffs + test evidence. No phase merges without my review + green suite +
coverage report.
