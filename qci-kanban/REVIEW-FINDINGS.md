# QCI Kanban v2 — Consolidated Review Findings (Phase 6)

Three adversarial review lenses (correctness, security, UI-contract) + coverage
gate. Each finding verified against source by the reviewer. Fix in priority
order; every fix is TDD (regression test first, then fix), suite stays green,
gated-file coverage stays 100%. v1 untouched.

## TIER 1 — must fix (crashes / auth bypass / data loss)

- **[C1/U1] Unicode byte-slicing crash (CRITICAL, cross-confirmed).** Truncation
  helpers slice by codepoint count used as a byte index → `StringIndexError`
  on any non-ASCII title/user name/epic/sprint name/search query beyond column
  width; app dies on next `view()`. Sites: `board.jl:424` `_short`,
  `board.jl:345-364` `_wrap_title`, `board.jl:384`, `app.jl:654` `_clip`,
  `app.jl:558,561,595,615,685`, `widgets.jl:54` (`◄` 3-byte), `gantt.jl:222`
  (`▸`), `calendar.jl:161`, `backlog.jl:154`. Fix: width-aware truncation
  (iterate chars / use `nextind`/`textwidth`), ideally one shared helper.
  Then EXTEND the Supposition sweep (`features/phase2_shell.jl:117`) beyond
  ASCII 32-126 to include multibyte + emoji, and add fixture cards/names with
  non-ASCII. Also guard `_short(s, n<=0)` (U9) — writes 2 cells at n≤0.
- **[U2] Quit unreachable inside every modal; Ctrl-C swallowed (HIGH).**
  `context_stack` (`app.jl:163-181`) omits `:global` for modal contexts and no
  modal binds `:ctrl_c`/`q`. Fix: ensure `:ctrl_c`→quit reaches dispatch from
  any modal (append `:global` to the stack, or bind `:ctrl_c` in a base
  context). Add test: Ctrl-C from an open card modal quits.
- **[S1] Deactivated user retains access via session restore (HIGH).**
  `session.jl:67-90` rebuilds `current_user` from JWT claims, hard-codes
  `active=true`, never re-checks the store. Fix: after `verify_jwt`, load user
  by `sub`; reject if missing/`active==false`; build from DB row. Test with a
  deactivated user + valid token.
- **[C6] Invalid date text silently erases existing date (MAJOR).**
  `modals.jl:126,140-160` → `parse_date` returns `nothing` on parse failure →
  bound as NULL, "Saved" message. Fix: distinguish empty (clear) from
  malformed (keep old value + show error, don't save). Test both.
- **[C7] Bulk ops act on filtered-out / invisible selections (MAJOR).**
  `selected_ids` never pruned on filter/search/swimlane change; `_bulk_move!`
  moves hidden cards; `_confirm_yes!` overcounts deletes. Fix: restrict bulk
  actions to currently-visible ids (or prune selection on filter change);
  count only successful deletes. Test: select 3, filter to hide 2, bulk-move →
  only visible act (or define+test the chosen semantics).

## TIER 2 — should fix (real, mostly cheap)

- **[U6] Enter stolen from description TextArea — multi-line impossible (MED).**
  `focus.jl:106` treats `:enter` structural in all contexts. Decide + implement:
  Enter inserts newline in a focused TextArea, save via a dedicated key
  (e.g. Ctrl+S) — update card-edit save binding + tests accordingly.
- **[U5] Selection escapes visible region; destructive ops on off-screen cards
  (MED).** Board "+N more" hides cursor; backlog/gantt/calendar no scroll-follow.
  Fix: clamp selection to visible rows or add scroll-follow so the cursor is
  always rendered. Test at short terminal + many issues.
- **[U4] Board columns overwrite right border at width ~24-43 (MED).**
  `col_w = max(8, width÷5)` overflows body. Fix: clamp column count / widen the
  small-board guard. No-bleed test at `TestBackend(38,24)`.
- **[S3] Timing oracle in `authenticate` — user enumeration (MED).** Unknown
  email returns instantly; known runs 100k PBKDF2. Fix: constant-work dummy
  verify on absent/inactive email. (Sqlite + remote.)
- **[S4] SMTP header injection via issue title/recipient (MED, gated path).**
  `notify/interface.jl:20-33` interpolates raw title; no CRLF strip before
  `send_mail`. Fix: strip CR/LF/control chars in key/title/recipient; validate
  recipient. Test the renderer strips newlines.
- **[C2/C3/C4/C5] Remote (Postgres) store defects (MAJOR but latent — backend
  unreachable).** Random `QCI-$(rand(100:999))` keys (C2), constant position 0
  (C2), non-dense move/rank/delete (C3), missing status/priority validation
  (C4), and AppModel hard-typed to SQLite so `cfg.backend=:remote` is dead (C5).
  Fix: mirror sqlite semantics in remote_store (MAX+1 keys, append position,
  sibling-shift, validation) and type AppModel fields to the abstract store
  contracts + honor `cfg.backend` in the constructor/`kanban2`. Extend FakeExec
  tests to assert semantics, not just SQL strings.
- **[S7] Plaintext password lingers after successful login (LOW-MED, cheap).**
  `_complete_login!`/`_create_submit!` don't clear `password_input` on success.
  Fix: `set_text!(m.password_input,"")` after success. Test buffer empty.
- **[S5] `verify_password` trusts stored `iterations` — no floor/ceiling
  (MED-LOW).** Login-DoS via huge value; accepts downgrade. Fix: clamp/validate
  to `[100_000, MAX]`, reject outside. Test.
- **[S8] JWT with no `exp` accepted forever (LOW, cheap).** `jwt.jl:48-52`. Fix:
  require `exp`. Test a no-exp token is rejected.
- **[S9] JWT secret: no min-length/non-empty guard on ENV/TOML override (LOW,
  cheap).** `config.jl`. Fix: reject secrets < 32 chars. Test.
- **[S6] Token/secret files: chmod-after-write TOCTOU + symlink follow
  (LOW-MED).** `session.jl:28-36`, `config.jl:129-137`. Fix: write to 0600 temp
  in same dir + rename; reject symlinks on read.

## TIER 3 — minor / cosmetic (fix if cheap; else document)

- **[U3] Login status hints advertise dead `c`/`q` (MED contract violation).**
  With ≥1 user the email input is focused so c/q type into it, but hints show
  them. Fix: generated hints must respect the focused-editor context.
- **[U7] Theme-enforcement test doesn't grep `src/gfx/` and is non-recursive
  (LOW, latent).** Extend `test_theme.jl` to cover gfx (currently clean).
- **[U8/U10] Status-bar + help overflow with no prioritization/scroll (LOW).**
  Prioritize hints; add a "more" indicator or scroll to help overlay.
- **[C8] Sprint single-active is check-then-act, not DB-enforced (MINOR).**
  Add `AND state='future'` guard + wrap start/close in a transaction; order
  `active_sprint` deterministically.
- **[C9] WIP header count reflects true store, disagrees with filtered grid
  (MINOR cosmetic).** Enforcement over true contents is correct; show filtered
  count separately or annotate.
- **[C10] Issue keys reused after deleting the highest-numbered issue (MINOR).**
  Use a monotonic counter (max-ever, not max-surviving) so keys are never
  recycled.
- **[S2] Logout doesn't revoke token; 7-day TTL, no revocation (MED-HIGH but
  larger change).** Add per-user `token_version`/`session_epoch` asserted in
  restore; bump on logout/deactivate. Consider shorter default TTL.
- **[S10] PG conninfo string interpolation unescaped (LOW, remote-only).** Use
  libpq keyword/value form or quote-escape.

## Verified CLEAN (do not re-hunt)
- JWT alg-confusion / `alg=none` — rejected by JSONWebTokens (verified).
- SQL injection — all queries parameterized; dynamic SET uses a symbol
  whitelist; ORDER BY literals only (verified).
- Modal bleed — `view()` clears full content area before overlays (verified).
- Empty-FocusState modals — printables inert, no leak (verified).
- Calendar month-nav day clamp, gantt state re-derive on switch, div-by-zero
  guards, v1/v2 method dispatch (no piracy/ambiguity) — all clean.
