# Plan: TDD changes for smaller centered login modal, new user creation, wipe test users, JWT login, admin page

## Goal kind
code-change

## Acceptance criteria
1. The login user selection UI renders as a smaller centered block (using reduced dimensions and center offset calc in the frame) instead of full content area; observable directly after loading a fresh KanbanModel and driving with update! + TestBackend render.
2. New users can create a login: from the initial gated login state, a name entry flow creates a user record in the DB, adds it to selectable list, and permits successful login using the created user.
3. Test users can be wiped via dedicated action from login/admin: the seeded demo users are removed (list shrinks, names no longer selectable), new or remaining users function for login, and effects visible after update! + re-render + DB inspection.
4. Login (select or create) uses JWT: a JWT-formatted token (containing user identity) is produced and held for the authenticated session; it is the observable credential set on successful login path.

## Verification plan
1. gating: execute `julia --project=qci-kanban -e 'using Pkg; Pkg.test()' 2>&1 | tee {SCRATCH}/test-output.log`; must exit with code 0; all suites (including new/updated login, users, db tests) pass with no failures.
2. gating: drive from raw `KanbanModel()` (set db_path=":memory:", call load_users!, sequence of KeyEvent updates for select/nav/create/wipe/login), followed by TestBackend view + assertions on find_text/row_text for smaller/centered login indicators, "create" or name input prompts, absence of wiped user names, presence of board content only post-login, and JWT token string matching JWT structure; re-render after each key mutation; repeat for create-user path.
3. gating: run a direct julia expression loading QciKanban, creating model, exercising create-user + wipe + login sequences, print/inspect model state for JWT token and user list post-wipe; redirect stdout/stderr to {SCRATCH}/jwt-wipe-login.log and confirm non-empty correct outcomes (e.g. token starts with typical base64 segments, specific names gone).
4. evidence: re-execute the simulation command from step 3 at least twice; captured output in {SCRATCH} must be consistent (same primary observables); inspect source for centered rect logic and JWT issuance present.
5. evidence: run `julia --project=qci-kanban -e 'using QciKanban; m = QciKanban.KanbanModel(); m.db_path=":memory:"; QciKanban.load_users!(m); println("loaded"); println("users=", length(m.users)); QciKanban.update!(m, QciKanban.KeyEvent(:enter)); println("post-login current=", m.current_user_id)' 2>&1 | tee {SCRATCH}/entry-launch.log`; observe successful load + state mutation without crash (primary observable: non-empty user list and post-gate user id or token).

See the session plan at .grok/sessions/.../plan.md for full details (implementation approach, task checklist, non-goals, scope, risks). This root file contains only the current TDD objective.

## 2026-06-30 update: fixed bottom key hint extension beyond LOGIN modal (the reported "help button" artifact)
- Used pure shared gate_frame_areas + plan_gate_modal_layout (no modal_area special case).
- Fixed by aligning inner text writes to inn.x in render_gate_modal! (prevents legend chars landing on right border col), and using width-aware short hint for first-time on narrow (<50) to guarantee full contained strings without truncation or bleed.
- Hardened AC visual + assert_gate_hint_contained to enforce y-range, x-strict-inside, char_at(border)==border.
- All steps re-ran: Pkg.test green, raw 40/60/80 + post-c, record x2, mandated live exprs (USERS=0 + full prompt visible + borders intact), visual_rows evidence saved to scratch. Full AC1 prompt + hint strictly inside rect on all sizes. App verif executed.

## Post-rejection closure (skeptic gaps fixed)
- Overwrote 40-60-80-current.log, live-gate.log (rich dump + full rows + USERS=0 + prompt), gate-visual*.log, ac-visual-green.log etc with fresh evidence from real raw path.
- 40x12 now: row8="│No users — press [c] to create account│" (full), hint contained, right border='│'.
- Planner: prompt priority + never-slice for AC1 body; test: strict full string in row + plan.body_rows + early plan calc.
- All verif plan steps + observations confirmed in verif-plan-full.log (1-5 PASS, full pkg green, 151 AC).
- Targeted tests after every edit; final mandated verif (USERS=0 + prompt + c flow) passed.
- Ready for completion.

## Closure after rejection (narrow hint + test search + full evidence)
- Changed narrow first-time hint to "[c] create  [a] [w] [q]" (includes a/w/q keys, fits fully in 40ca avail without planner slice or render truncate).
- Planner now forces w also for the passed hint len so plan.hint_row hs is the full intended.
- AC visual test now verifies hint row using plan.hint_row[1] + occursin(hs, rendered_row) + assert_gate (always executes for narrow); removed fragile findfirst("admin"/"wipe") that returned nothing on short.
- Fresh overwrites of 40-60-80-current.log, 40col-*, gate-visual.log, live-gate.log, ac1-4-final.log etc all show: full prompt + full (appropriate) hint inside borders, right_border='│', hint_full_in_row=true.
- AC1-4 151/151 green, full Pkg.test green.
- Verif plan steps executed + "ALL OBSERVATIONS HOLD" in verif-plan-full.log (incl step2 80/60 with [a] etc, step5 40 contained, USERS=0 + prompt).
- All per AGENTS: targeted after edits, real raw paths, scratch only, verif before claim.
