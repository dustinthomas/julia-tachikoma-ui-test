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
