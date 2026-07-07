# QCI Kanban v2 — Phase Briefs

Companion to DESIGN.md. Each phase is implemented TDD (failing tests first),
lands with the FULL suite green, and is reviewed before the next phase starts.
Baseline before Phase 1: 529 passing assertions (all green, commit e069619).

Conventions for every phase:
- Drive all UI tests exclusively via `update!(m, KeyEvent(...))` + TestBackend
  re-render; assert presence AND absence (no-bleed).
- `:memory:` SQLite for isolation; never touch `~/.qci-kanban/`.
- New text-entry surfaces MUST route through the focus router (Phase 2) —
  never add per-field guard flags.
- BDD acceptance specs live in `test/features/`, Given/When/Then testsets.
- Run `julia --project=. test/runtests.jl` before claiming done.

---

## Phase 1 — Core infrastructure (no UI)

New files: `src/domain.jl`, `src/config.jl`, `src/auth/{password,jwt,session}.jl`,
`src/store/{interface,sqlite_store,remote_store}.jl`,
`src/notify/{interface,outbox,smtp}.jl`. Old `src/db.jl` stays until Phase 3
migrates the UI, then is deleted.

### 1a Domain types (`domain.jl`)
Plain structs + constructors/validators: `User`, `Issue`, `Epic`, `Sprint`,
`Comment`, `Label`, `ActivityEvent`, `NotificationEvent`. Issue gains:
`story_points::Union{Int,Nothing}`, `epic_id`, `sprint_id`, `reporter_id`,
`start_date`, `due_date`, `labels::Vector{String}` (ids). Sprint state machine:
`future → active → closed`, only one active sprint at a time.

### 1b Store interface + SQLite impl
`AbstractUserStore`: `create_user!(store; email, name, password) → User`,
`authenticate(store, email, password) → User|nothing`, `get_user`, `list_users`,
`deactivate_user!`. `AbstractBoardStore`: full CRUD for issues/epics/sprints/
labels/comments + `log_activity!`/`list_activity`, `rank_issue!` (position
shifting done CORRECTLY — siblings shift, no collisions; this fixes the v1
position-collision bug), `move_issue!(store, id; status, position)`,
`issues_for_sprint`, `backlog_issues`, `set_labels!`, `add_comment!`.
SQLite impl in TWO databases: `users.db` and `board.db` (`:memory:` capable
via separate handles). Schema per DESIGN.md. Demo seeding: issues + epics +
sprints + labels, ZERO users (preserve v1 first-run gate contract).

### 1c Auth
- `password.jl`: PBKDF2-HMAC-SHA256, 16-byte random salt, ≥100k iters,
  constant-time compare. Pure SHA stdlib — no fragile deps.
- `jwt.jl`: real HS256 JWT — header/payload base64url, HMAC-SHA256 signature,
  `iat`/`exp` claims, `verify(token, secret) → claims|nothing` rejecting bad
  signature, expired, malformed, alg=none. Secret from config (generated and
  persisted on first run if absent).
- `session.jl`: `login!(sess, userstore, email, password)`,
  `restore(sess, token)`, `logout!`, token file `~/.qci-kanban/session.jwt`
  (path injectable for tests), 0600 perms.

### 1d Notification infrastructure
`NotificationEvent` kinds: `:assigned, :status_changed, :comment_added,
:due_soon, :mentioned`. `NullNotifier` (default), `OutboxNotifier` (durable
rows in board.db outbox), `SMTPNotifier(config, transport)` where transport
is injectable — `FakeTransport` for tests records sends; real transport
uses SMTPClient only when `config.smtp.enabled`. `flush_outbox!` drains
pending rows through a notifier. Renderers: subject/body templates per kind.

### Acceptance (BDD)
- Given a fresh user store, creating a user and authenticating with the right
  password yields the user; wrong password/email yields nothing; the stored
  hash is not the password and differs per-salt for identical passwords.
- JWT round-trips claims; tampered payload/signature/alg=none/expired all
  verify to nothing.
- Given an issue moved between statuses, activity log records it and an
  OutboxNotifier row exists; flush through FakeTransport marks it sent.
- rank_issue! keeps positions dense and collision-free under arbitrary moves
  (Supposition property test).
- 100% line coverage on all new files.

---

## Phase 2 — UI shell: theme, focus router, login, app frame

### 2a Theme (`ui/theme.jl`)
All palette constants from scout report; semantic accessors
(`col_bg, col_surface, col_primary, col_accent, col_text, col_text_dim,
col_ok, col_warn, col_err, col_sel, priority_color(p), epic_color(e)`).
No `ColorRGB` literals outside theme.jl (enforced by a test that greps src/).

### 2b Focus router (`ui/focus.jl`, `ui/keymap.jl`)
`FocusState` (which editor, if any, owns input), `route_key!(m, evt)`
implementing DESIGN.md dispatch order. Declarative keymap table:
`(context, key) → action symbol`; help overlay + status-bar hints generated
from the table. Kills the v1 bugs: digits typable in title/desc (priority is
edited via a dropdown/selector field, not global 1/2/3 while typing);
single source of truth for "is an input focused" (no duplicated q-guard).

### 2c Login screens
Email + password (masked) inputs, create-account form (email/name/password),
error line on bad credentials, session restore on startup (valid token skips
login), logout key from anywhere post-login. First-run contract preserved:
zero users → "No users — press [c] to create account".

### 2d App frame
`AppModel` replaces `KanbanModel` internals incrementally: view router
(board/backlog/calendar/gantt), header with QCI logo area (graphics-capable,
text fallback), status bar with contextual hints from keymap, message/toast
line, small-terminal guard.

### Acceptance (BDD)
- Property test: for EVERY context with a focused editor, ANY printable char
  mutates only that editor's text — board/view/global state unchanged
  (Supposition over chars × contexts). Digits included.
- Login: wrong password shows error and stays gated; correct login lands on
  board; restart with persisted valid token skips login; expired/tampered
  token → login screen.
- Full-suite green + 100% coverage on new files.

---

## Phase 3 — Jira board

- Swimlane grid: lanes (`:none|:assignee|:epic|:priority`) × status columns,
  REAL card cells per (lane, column) — each lane is a horizontal band with
  its own mini-columns; selection = (lane, col, idx); `s` cycles lane mode,
  lane headers show name + count. Lane-by-assignee shows user NAMES.
- Rich cards: key, title (wrapping 2-line), priority glyph, story points
  badge, label chips (colored), epic tag, assignee initials, due chip
  (red when overdue).
- Card detail modal: full fields + comments thread (add via focused TextArea)
  + activity tail; edit modal with title/desc/priority/points/epic/sprint/
  labels/assignee/dates via focus-routed fields (Tab cycles).
- Board ops: create/edit/delete(confirm)/move(&lt; &gt;)/rank(J/K)/assign/watch;
  bulk select (Space) + REAL bulk actions (move/assign/delete); search (/)
  across title+key+desc+labels; quick filters (Mine/High/Due Soon/label);
  WIP limits enforced with warning + over-limit styling.
- Backlog view: backlog list + sprints (create/start/close), move issues
  backlog↔sprint, active-sprint filter on board.
- v1 `db.jl` fully replaced by stores; old flat update! replaced by keymap
  dispatch. All existing v1 test intents preserved or consciously superseded.

### Acceptance (BDD)
- Given swimlane-by-epic with issues in multiple epics and statuses, the grid
  shows each epic band with cards in the correct status cells; navigation
  reaches any card; moving a card changes only its cell.
- Bulk: select 3 cards, bulk-move → all 3 in target column, activity logged.
- WIP: moving into a full column warns and styles over-limit.
- Sprint: create sprint, add issues, start it; board "active sprint" filter
  shows only its issues; closing rolls incomplete issues back to backlog.
- No-bleed for every modal at 3 sizes; 100% coverage on new/changed files.

---

## Phase 4 — Calendar + Gantt

- Calendar: month grid (Calendar widget), due badges, day selection shows
  that day's cards, month nav, create-with-due-date shortcut.
- Gantt: timeline view; rows = issues (grouped by epic/sprint), bars from
  start_date→due_date rendered with canvas/graphics primitives per scout
  report (braille/block canvas; pixel backend where supported, text fallback
  ALWAYS correct under TestBackend); today marker; zoom (day/week/month);
  horizontal scroll; sprint bands shaded.
  **Visual polish completed (PR1–PR6)**: weekend shading (`░`), ruler/axis
  (month labels + `┬`), upgraded today (`┃` + label), bar ends (`▌▐`)/density
  (`▓` status fills)/inside labels, selection bar accents + epic tree indents,
  selected footer + richer empty, sprint polish + adaptive left width + legend
  + unicode/responsive fallbacks. All TestBackend-covered; 100% on gantt.jl.

### Acceptance
- Deterministic TestBackend assertions on bar extents (row_text patterns) for
  known dates at fixed sizes; today marker column correct; zoom changes scale.
- Calendar day drill-down lists exactly that day's issues.
- 100% coverage on new files.

---

## Phase 5 — Graphics polish + demos

- Pixel/kitty/sixel QCI logo on login + header (per scout APIs), text-art
  fallback identical layout; optional subtle animation (tick-driven) where
  cheap; sparkline/gauge widgets for board stats (per-column counts,
  burndown for active sprint in backlog view).
- `record_demo` scripted tour: login → board → swimlanes → card detail →
  backlog/sprint → calendar → gantt; produce .tach artifact.
- Live-app verification per repo rule; update README + CLAUDE.md.

---

## Phase 6 — Coverage gate + final review

- `test/coverage_gate.jl`: run with `--code-coverage`, Coverage.jl analysis,
  fail below 100% of src/ lines (documented exclusions only for the live
  terminal loop glue, which record_demo exercises).
- Fable adversarial review of the full diff; fix-forward; final green run;
  final live-app check (first-run login contract).
