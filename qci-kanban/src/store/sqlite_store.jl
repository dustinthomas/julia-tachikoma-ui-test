# ═══════════════════════════════════════════════════════════════════════
# store/sqlite_store.jl — local SQLite implementation of both store contracts.
#
# users.db and board.db are SEPARATE handles (both `:memory:`-capable). The
# board store never joins into the user store — assignee/reporter are ids only.
# Positions are kept dense (0..n-1 per status) and collision-free by rank/move.
# ═══════════════════════════════════════════════════════════════════════

using SQLite
using DBInterface
using Tables
using Dates

export SQLiteUserStore, SQLiteBoardStore, open_sqlite_stores, close!

# ── Store types ────────────────────────────────────────────────────────
struct SQLiteUserStore <: AbstractUserStore
    db::SQLite.DB
end
struct SQLiteBoardStore <: AbstractBoardStore
    db::SQLite.DB
end

function SQLiteUserStore(path::AbstractString = ":memory:")
    db = _open_db(path)
    init_user_schema!(db)
    SQLiteUserStore(db)
end
function SQLiteBoardStore(path::AbstractString = ":memory:")
    db = _open_db(path)
    init_board_schema!(db)
    SQLiteBoardStore(db)
end

"Open both stores from an AppConfig (paths from config)."
open_sqlite_stores(cfg::AppConfig) =
    (SQLiteUserStore(cfg.users_db_path), SQLiteBoardStore(cfg.board_db_path))

close!(s::SQLiteUserStore) = (try SQLite.close(s.db) catch end; nothing)
close!(s::SQLiteBoardStore) = (try SQLite.close(s.db) catch end; nothing)

function _open_db(path::AbstractString)::SQLite.DB
    if path != ":memory:"
        dir = dirname(path)
        isempty(dir) || isdir(dir) || mkpath(dir)
    end
    db = SQLite.DB(path)
    # PRAGMA foreign_keys must be set per connection (SQLite default is OFF).
    DBInterface.execute(db, "PRAGMA foreign_keys = ON")
    db
end

_exec(db, sql) = DBInterface.execute(db, sql)
_exec(db, sql, params) = DBInterface.execute(db, sql, params)
_query(db, sql) = DBInterface.execute(db, sql) |> Tables.columntable
_query(db, sql, params) = DBInterface.execute(db, sql, params) |> Tables.columntable

# ── Schema ────────────────────────────────────────────────────────────────
function init_user_schema!(db::SQLite.DB)
    _exec(db, """
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            email TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            iterations INTEGER NOT NULL,
            created TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            token_version INTEGER NOT NULL DEFAULT 0
        )
    """)
end

# Base board tables (pre-multi-project). Migrations v1–v5 add projects,
# nullable project_id columns, Default backfill, and the proj-status index.
# Ranking remains global (per status only) until PR-M2 — temporary debt that is
# safe because only Default has data right after migrate.
const DEFAULT_PROJECT_KEY = "QCI"
const DEFAULT_PROJECT_NAME = "Default"
const BOARD_SCHEMA_TARGET = 5   # PR-M1 stops at v5; v6 (metrics backfill) is PR-M4

function init_board_schema!(db::SQLite.DB)
    _exec(db, """
        CREATE TABLE IF NOT EXISTS issues (
            id TEXT PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            description TEXT,
            status TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'Medium',
            story_points INTEGER,
            epic_id TEXT,
            sprint_id TEXT,
            assignee_id TEXT,
            reporter_id TEXT,
            start_date TEXT,
            due_date TEXT,
            position INTEGER NOT NULL DEFAULT 0,
            created TEXT NOT NULL,
            updated TEXT NOT NULL
        )
    """)
    _exec(db, "CREATE INDEX IF NOT EXISTS idx_issues_status_pos ON issues(status, position)")
    # C10: monotonic key counter (max-ever per prefix, never recycled).
    _exec(db, "CREATE TABLE IF NOT EXISTS key_seq (prefix TEXT PRIMARY KEY, last INTEGER NOT NULL)")
    _exec(db, """
        CREATE TABLE IF NOT EXISTS epics (
            id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL, color TEXT NOT NULL, created TEXT NOT NULL
        )
    """)
    _exec(db, """
        CREATE TABLE IF NOT EXISTS sprints (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, goal TEXT,
            start_date TEXT, end_date TEXT, state TEXT NOT NULL
        )
    """)
    _exec(db, "CREATE TABLE IF NOT EXISTS labels (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL)")
    _exec(db, """
        CREATE TABLE IF NOT EXISTS issue_labels (
            issue_id TEXT NOT NULL, label_id TEXT NOT NULL,
            PRIMARY KEY (issue_id, label_id)
        )
    """)
    _exec(db, """
        CREATE TABLE IF NOT EXISTS comments (
            id TEXT PRIMARY KEY, issue_id TEXT NOT NULL,
            author_id TEXT NOT NULL, body TEXT NOT NULL, created TEXT NOT NULL
        )
    """)
    _exec(db, """
        CREATE TABLE IF NOT EXISTS activity (
            id TEXT PRIMARY KEY, issue_id TEXT NOT NULL, actor_id TEXT,
            kind TEXT NOT NULL, detail TEXT, created TEXT NOT NULL
        )
    """)
    _exec(db, """
        CREATE TABLE IF NOT EXISTS outbox (
            id TEXT PRIMARY KEY, event_kind TEXT NOT NULL,
            recipient_email TEXT NOT NULL, subject TEXT NOT NULL,
            body TEXT NOT NULL, created TEXT NOT NULL, sent_at TEXT
        )
    """)
    migrate_board_schema!(db)
end

function _schema_version(db::SQLite.DB)::Int
    tables = _query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'")
    isempty(tables.name) && return 0
    r = _query(db, "SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations")
    Int(r.v[1])
end

board_schema_version(store::SQLiteBoardStore)::Int = _schema_version(store.db)

function _record_migration!(db::SQLite.DB, version::Int)
    _exec(db, "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
          [version, _dt_str(Dates.now(UTC))])
end

"""
    migrate_board_schema!(db) -> Int

Apply board migrations v1–v5 (transaction per version). Returns the version after
migrate. Does **not** run v6 (sprint_metrics backfill — owned by PR-M4).
"""
function migrate_board_schema!(db::SQLite.DB)::Int
    v = _schema_version(db)

    if v < 1
        SQLite.transaction(db) do
            _exec(db, """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL
                )
            """)
            _record_migration!(db, 1)
        end
        v = 1
    end

    if v < 2
        SQLite.transaction(db) do
            _exec(db, """
                CREATE TABLE IF NOT EXISTS projects (
                    id TEXT PRIMARY KEY,
                    key TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    color TEXT NOT NULL DEFAULT 'blue',
                    archived INTEGER NOT NULL DEFAULT 0,
                    created TEXT NOT NULL
                )
            """)
            # Empty shell for PR-M4 velocity; no rows until metrics land.
            _exec(db, """
                CREATE TABLE IF NOT EXISTS sprint_metrics (
                    sprint_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    planned_units INTEGER NOT NULL DEFAULT 0,
                    completed_units INTEGER NOT NULL DEFAULT 0,
                    completed_count INTEGER NOT NULL DEFAULT 0,
                    incomplete_count INTEGER NOT NULL DEFAULT 0,
                    unit_kind TEXT NOT NULL DEFAULT 'points',
                    closed_at TEXT NOT NULL
                )
            """)
            _record_migration!(db, 2)
        end
        v = 2
    end

    if v < 3
        SQLite.transaction(db) do
            # Nullable at DB level (SQLite cannot ALTER … SET NOT NULL later without rebuild).
            _exec(db, "ALTER TABLE issues ADD COLUMN project_id TEXT")
            _exec(db, "ALTER TABLE epics ADD COLUMN project_id TEXT")
            _exec(db, "ALTER TABLE sprints ADD COLUMN project_id TEXT")
            _exec(db, "ALTER TABLE labels ADD COLUMN project_id TEXT")
            _record_migration!(db, 3)
        end
        v = 3
    end

    if v < 4
        SQLite.transaction(db) do
            existing = _query(db, "SELECT id FROM projects WHERE key = ? LIMIT 1", [DEFAULT_PROJECT_KEY])
            pid = if isempty(existing.id)
                id = new_id()
                _exec(db, """
                    INSERT INTO projects (id, key, name, description, color, archived, created)
                    VALUES (?, ?, ?, '', 'blue', 0, ?)
                """, [id, DEFAULT_PROJECT_KEY, DEFAULT_PROJECT_NAME, _dt_str(Dates.now(UTC))])
                id
            else
                String(existing.id[1])
            end
            for tbl in ("issues", "epics", "sprints", "labels")
                _exec(db, "UPDATE $(tbl) SET project_id = ? WHERE project_id IS NULL", [pid])
            end
            _record_migration!(db, 4)
        end
        v = 4
    end

    if v < 5
        SQLite.transaction(db) do
            _exec(db, """
                CREATE INDEX IF NOT EXISTS idx_issues_proj_status_pos
                ON issues(project_id, status, position)
            """)
            _record_migration!(db, 5)
        end
        v = 5
    end

    # BOARD_SCHEMA_TARGET is the highest version this migrator applies (PR-M1 = 5;
    # PR-M4 will raise the target when it registers v6). Allow v > target if a
    # newer migrator already ran on this file.
    v < BOARD_SCHEMA_TARGET &&
        error("board schema migration incomplete: version $v < $BOARD_SCHEMA_TARGET")
    v
end

# ═══════════════════════════ USER STORE ═══════════════════════════════════
function create_user!(store::SQLiteUserStore; email::AbstractString, name::AbstractString,
                      password::AbstractString)::User
    valid_email(email) || throw(ArgumentError("invalid email: $email"))
    existing = _query(store.db, "SELECT id FROM users WHERE email = ? LIMIT 1", [email])
    isempty(existing.id) || throw(ArgumentError("email already registered: $email"))
    id = new_id()
    created = Dates.now(UTC)
    ph = hash_password(password)
    _exec(store.db, """
        INSERT INTO users (id, email, name, password_hash, salt, iterations, created, active)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1)
    """, [id, email, name, ph.hash_hex, ph.salt_hex, ph.iterations, _dt_str(created)])
    User(; id = id, email = email, name = name, active = true, created = created)
end

function authenticate(store::SQLiteUserStore, email::AbstractString, password::AbstractString)
    r = _query(store.db, """
        SELECT id, email, name, password_hash, salt, iterations, created, active
        FROM users WHERE email = ? LIMIT 1
    """, [email])
    # S3: constant-work dummy verify so absent/inactive email costs the same as
    # a real one — no timing oracle for user enumeration.
    (isempty(r.id) || r.active[1] != 1) && (_dummy_verify(password); return nothing)
    ph = PasswordHash(String(r.password_hash[1]), String(r.salt[1]), Int(r.iterations[1]))
    verify_password(password, ph) || return nothing
    User(; id = String(r.id[1]), email = String(r.email[1]), name = String(r.name[1]),
         active = true, created = parse_dt(r.created[1]))
end

function get_user(store::SQLiteUserStore, id::AbstractString)
    r = _query(store.db, "SELECT id, email, name, created, active FROM users WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    User(; id = String(r.id[1]), email = String(r.email[1]), name = String(r.name[1]),
         active = r.active[1] == 1, created = parse_dt(r.created[1]))
end

function get_token_version(store::SQLiteUserStore, id::AbstractString)::Int
    r = _query(store.db, "SELECT token_version FROM users WHERE id = ? LIMIT 1", [id])
    isempty(r.token_version) ? 0 : Int(r.token_version[1])
end

function bump_token_version!(store::SQLiteUserStore, id::AbstractString)::Int
    _exec(store.db, "UPDATE users SET token_version = token_version + 1 WHERE id = ?", [id])
    get_token_version(store, id)
end

function list_users(store::SQLiteUserStore)::Vector{User}
    r = _query(store.db, "SELECT id, email, name, created, active FROM users ORDER BY name")
    [User(; id = String(r.id[i]), email = String(r.email[i]), name = String(r.name[i]),
          active = r.active[i] == 1, created = parse_dt(r.created[i])) for i in eachindex(r.id)]
end

function deactivate_user!(store::SQLiteUserStore, id::AbstractString)::Bool
    # Bump token_version too so any outstanding token for this user is orphaned.
    _exec(store.db, "UPDATE users SET active = 0, token_version = token_version + 1 WHERE id = ?", [id])
    true
end

# ═══════════════════════════ BOARD STORE ══════════════════════════════════
_str_or_empty(x) = (x === missing || x === nothing) ? "" : String(x)

# List filters: `nothing` *and* empty string mean unfiltered (same as create's
# "omit → Default" empty-string handling on the write path, but lists do not
# invent a Default filter).
_norm_project_filter(project_id::Nothing) = nothing
_norm_project_filter(project_id::AbstractString) =
    isempty(String(project_id)) ? nothing : String(project_id)

function _project_from(r, i)::Project
    color = _str_or_empty(r.color[i])
    isempty(color) && (color = "blue")
    Project(; id = String(r.id[i]), key = String(r.key[i]), name = String(r.name[i]),
            description = _str_or_empty(r.description[i]), color = color,
            archived = let a = r.archived[i]; a === missing ? false : (a == 1 || a === true) end,
            created = parse_dt(r.created[i]))
end

function _issue_from(r, i)::Issue
    Issue(; id = String(r.id[i]), key = String(r.key[i]), title = String(r.title[i]),
          description = r.description[i] === missing ? "" : String(r.description[i]),
          status = String(r.status[i]), priority = String(r.priority[i]),
          story_points = parse_points(r.story_points[i]),
          epic_id = r.epic_id[i] === missing ? nothing : String(r.epic_id[i]),
          sprint_id = r.sprint_id[i] === missing ? nothing : String(r.sprint_id[i]),
          assignee_id = r.assignee_id[i] === missing ? nothing : String(r.assignee_id[i]),
          reporter_id = r.reporter_id[i] === missing ? nothing : String(r.reporter_id[i]),
          start_date = parse_date(r.start_date[i]), due_date = parse_date(r.due_date[i]),
          position = Int(r.position[i]), labels = String[],
          created = parse_dt(r.created[i]), updated = parse_dt(r.updated[i]),
          project_id = _str_or_empty(hasproperty(r, :project_id) ? r.project_id[i] : nothing))
end

# C10: bump a monotonic per-prefix counter. Seeds from max(stored key_seq,
# existing_max, 99) so a stale key_seq.last below the true row MAX cannot
# collide; then only ever increases — deleted numbers are never recycled.
function _next_seq!(db, prefix::AbstractString, existing_max::Union{Nothing,Missing,Integer})::Int
    row = _query(db, "SELECT last FROM key_seq WHERE prefix = ? LIMIT 1", [prefix])
    emax = (existing_max === nothing || existing_max === missing) ? nothing : Int(existing_max)
    stored = isempty(row.last) ? nothing : Int(row.last[1])
    # base is 100 → floor 99; always honour row MAX when provided.
    last = max(99, something(stored, 99), something(emax, 99))
    n = last + 1
    _exec(db, """
        INSERT INTO key_seq (prefix, last) VALUES (?, ?)
        ON CONFLICT(prefix) DO UPDATE SET last = ?
    """, [prefix, n, n])
    n
end

"""Max numeric suffix for issue keys `{project_key}-{n}` (reject multi-hyphen)."""
function _max_issue_num(db, project_key::AbstractString)
    r = _query(db, "SELECT key FROM issues WHERE key LIKE ?", [project_key * "-%"])
    maxn = nothing
    # project keys are [A-Z0-9]+ so a plain Regex is safe (no metacharacters).
    re = Regex("^" * project_key * "-(\\d+)\$")
    for k in r.key
        m = match(re, String(k))
        m === nothing && continue
        n = parse(Int, m.captures[1])
        maxn = maxn === nothing ? n : max(maxn, n)
    end
    maxn
end

"""Max numeric suffix for epic keys `{project_key}-E-{n}`."""
function _max_epic_num(db, project_key::AbstractString)
    r = _query(db, "SELECT key FROM epics WHERE key LIKE ?", [project_key * "-E-%"])
    maxn = nothing
    re = Regex("^" * project_key * "-E-(\\d+)\$")
    for k in r.key
        m = match(re, String(k))
        m === nothing && continue
        n = parse(Int, m.captures[1])
        maxn = maxn === nothing ? n : max(maxn, n)
    end
    maxn
end

function _generate_issue_key(db, project_key::AbstractString)::String
    n = _next_seq!(db, project_key, _max_issue_num(db, project_key))
    "$(project_key)-$(n)"
end

function _generate_epic_key(db, project_key::AbstractString)::String
    n = _next_seq!(db, "$(project_key)#EPIC", _max_epic_num(db, project_key))
    "$(project_key)-E-$(n)"
end

# Dense ranks are per (project_id, status) — PR-M2 Key Decision #7.
_status_count(db, project_id::AbstractString, status) =
    Int(_query(db, "SELECT COUNT(*) AS c FROM issues WHERE project_id = ? AND status = ?",
               [project_id, status]).c[1])

# ── Projects ──────────────────────────────────────────────────────────────
function create_project!(store::SQLiteBoardStore; key::AbstractString, name::AbstractString,
                         description::AbstractString = "",
                         color::AbstractString = "blue")::Project
    valid_project_key(key) || throw(ArgumentError("invalid project key: $key"))
    isempty(strip(name)) && throw(ArgumentError("project name must not be empty"))
    existing = _query(store.db, "SELECT id FROM projects WHERE key = ? LIMIT 1", [key])
    isempty(existing.id) || throw(ArgumentError("project key already exists: $key"))
    id = new_id(); created = Dates.now(UTC)
    _exec(store.db, """
        INSERT INTO projects (id, key, name, description, color, archived, created)
        VALUES (?, ?, ?, ?, ?, 0, ?)
    """, [id, key, name, description, color, _dt_str(created)])
    Project(; id = id, key = key, name = name, description = description,
            color = color, archived = false, created = created)
end

function get_project(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM projects WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    _project_from(r, 1)
end

function list_projects(store::SQLiteBoardStore; include_archived::Bool = false)::Vector{Project}
    r = include_archived ?
        _query(store.db, "SELECT * FROM projects ORDER BY key") :
        _query(store.db, "SELECT * FROM projects WHERE archived = 0 ORDER BY key")
    [_project_from(r, i) for i in eachindex(r.id)]
end

function archive_project!(store::SQLiteBoardStore, id::AbstractString)::Project
    p = get_project(store, id)
    p === nothing && throw(ArgumentError("no such project: $id"))
    p.archived && return p
    act = _query(store.db,
        "SELECT id FROM sprints WHERE project_id = ? AND state = 'active' LIMIT 1", [id])
    isempty(act.id) || throw(ArgumentError("cannot archive project with an active sprint"))
    _exec(store.db, "UPDATE projects SET archived = 1 WHERE id = ?", [id])
    get_project(store, id)
end

function _default_project(db::SQLite.DB)::Project
    r = _query(db, "SELECT * FROM projects WHERE key = ? LIMIT 1", [DEFAULT_PROJECT_KEY])
    isempty(r.id) && throw(ErrorException("Default project missing — run migrations"))
    _project_from(r, 1)
end

"""Resolve optional project_id to a real non-archived project id (Default if omitted)."""
function _resolve_project_id(db::SQLite.DB, project_id::Union{AbstractString,Nothing})::Tuple{String,String}
    if project_id === nothing || isempty(String(project_id))
        p = _default_project(db)
        # Archive semantics apply to Default too — omit/empty must not bypass.
        p.archived && throw(ArgumentError("project is archived: $(p.id)"))
        return (p.id, p.key)
    end
    r = _query(db, "SELECT * FROM projects WHERE id = ? LIMIT 1", [project_id])
    isempty(r.id) && throw(ArgumentError("no such project: $project_id"))
    p = _project_from(r, 1)
    p.archived && throw(ArgumentError("project is archived: $project_id"))
    (p.id, p.key)
end

"""Throw if `project_id` names an archived project (no-op for empty/missing id)."""
function _assert_project_writable!(store::SQLiteBoardStore, project_id::AbstractString)
    isempty(project_id) && return nothing
    p = get_project(store, project_id)
    p === nothing && return nothing
    p.archived && throw(ArgumentError("project is archived: $project_id"))
    nothing
end

"""
Cross-project FK integrity (Key Decision #8): epic/sprint/labels must live in
the same project as the issue. Throws `ArgumentError` on mismatch or missing ref.
"""
function _assert_issue_refs!(store::SQLiteBoardStore, project_id::AbstractString;
                             epic_id = nothing, sprint_id = nothing,
                             labels::Union{Vector{String},Nothing} = nothing)
    if epic_id !== nothing && epic_id !== missing
        e = get_epic(store, String(epic_id))
        e === nothing && throw(ArgumentError("no such epic: $epic_id"))
        e.project_id == project_id ||
            throw(ArgumentError("epic belongs to another project: $epic_id"))
    end
    if sprint_id !== nothing && sprint_id !== missing
        s = get_sprint(store, String(sprint_id))
        s === nothing && throw(ArgumentError("no such sprint: $sprint_id"))
        s.project_id == project_id ||
            throw(ArgumentError("sprint belongs to another project: $sprint_id"))
    end
    if labels !== nothing
        for lid in labels
            l = _get_label(store, lid)
            l === nothing && throw(ArgumentError("no such label: $lid"))
            l.project_id == project_id ||
                throw(ArgumentError("label belongs to another project: $lid"))
        end
    end
    nothing
end

function _get_label(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM labels WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    Label(; id = String(r.id[1]), name = String(r.name[1]), color = String(r.color[1]),
          project_id = _str_or_empty(hasproperty(r, :project_id) ? r.project_id[1] : nothing))
end

function create_issue!(store::SQLiteBoardStore; title::AbstractString, description::AbstractString = "",
                       status::AbstractString = "Backlog", priority::AbstractString = "Medium",
                       story_points::Union{Int,Nothing} = nothing,
                       epic_id::Union{AbstractString,Nothing} = nothing,
                       sprint_id::Union{AbstractString,Nothing} = nothing,
                       assignee_id::Union{AbstractString,Nothing} = nothing,
                       reporter_id::Union{AbstractString,Nothing} = nothing,
                       start_date::Union{Date,Nothing} = nothing,
                       due_date::Union{Date,Nothing} = nothing,
                       labels::Vector{String} = String[],
                       project_id::Union{AbstractString,Nothing} = nothing)::Issue
    valid_status(status) || throw(ArgumentError("invalid status: $status"))
    valid_priority(priority) || throw(ArgumentError("invalid priority: $priority"))
    pid, pkey = _resolve_project_id(store.db, project_id)
    _assert_issue_refs!(store, pid; epic_id = epic_id, sprint_id = sprint_id, labels = labels)
    id = new_id()
    key = _generate_issue_key(store.db, pkey)
    now = Dates.now(UTC)
    position = _status_count(store.db, pid, status)   # append within (project, status)
    _exec(store.db, """
        INSERT INTO issues (id, key, title, description, status, priority, story_points,
            epic_id, sprint_id, assignee_id, reporter_id, start_date, due_date, position,
            created, updated, project_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [id, key, title, description, status, priority, story_points, epic_id, sprint_id,
          assignee_id, reporter_id, _date_str(start_date), _date_str(due_date), position,
          _dt_str(now), _dt_str(now), pid])
    isempty(labels) || set_labels!(store, id, labels)
    get_issue(store, id)
end

function get_issue(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM issues WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    iss = _issue_from(r, 1)
    _issue_with_labels(store, iss)
end

function _issue_with_labels(store, iss::Issue)::Issue
    lbls = labels_for_issue(store, iss.id)
    Issue(; id = iss.id, key = iss.key, title = iss.title, description = iss.description,
          status = iss.status, priority = iss.priority, story_points = iss.story_points,
          epic_id = iss.epic_id, sprint_id = iss.sprint_id, assignee_id = iss.assignee_id,
          reporter_id = iss.reporter_id, start_date = iss.start_date, due_date = iss.due_date,
          position = iss.position, labels = lbls, created = iss.created, updated = iss.updated,
          project_id = iss.project_id)
end

function list_issues(store::SQLiteBoardStore;
                     status::Union{AbstractString,Nothing} = nothing,
                     project_id::Union{AbstractString,Nothing} = nothing)::Vector{Issue}
    project_id = _norm_project_filter(project_id)
    r = if project_id === nothing && status === nothing
        _query(store.db, "SELECT * FROM issues ORDER BY status, position, key")
    elseif project_id === nothing
        _query(store.db, "SELECT * FROM issues WHERE status = ? ORDER BY position, key", [status])
    elseif status === nothing
        _query(store.db, "SELECT * FROM issues WHERE project_id = ? ORDER BY status, position, key",
               [project_id])
    else
        _query(store.db,
               "SELECT * FROM issues WHERE project_id = ? AND status = ? ORDER BY position, key",
               [project_id, status])
    end
    [_issue_with_labels(store, _issue_from(r, i)) for i in eachindex(r.id)]
end

const _ISSUE_UPDATE_FIELDS = (:title, :description, :status, :priority, :story_points,
    :epic_id, :sprint_id, :assignee_id, :reporter_id, :start_date, :due_date, :position)

function update_issue!(store::SQLiteBoardStore, id::AbstractString; kwargs...)
    # Archive write guard (design § archive semantics): block updates on archived projects.
    iss0 = get_issue(store, id)
    iss0 === nothing && return nothing
    _assert_project_writable!(store, iss0.project_id)
    move_status = nothing; move_pos = nothing
    # Cross-project FK integrity on epic/sprint when those kwargs are present.
    kw_epic = get(kwargs, :epic_id, :__absent__)
    kw_sprint = get(kwargs, :sprint_id, :__absent__)
    if kw_epic !== :__absent__ || kw_sprint !== :__absent__
        _assert_issue_refs!(store, iss0.project_id;
                            epic_id = kw_epic === :__absent__ ? nothing : kw_epic,
                            sprint_id = kw_sprint === :__absent__ ? nothing : kw_sprint)
    end
    fields = String[]; vals = Any[]
    for (k, v) in kwargs
        k in _ISSUE_UPDATE_FIELDS || continue
        if k === :status
            valid_status(v) || throw(ArgumentError("invalid status: $v"))
            move_status = v; continue
        elseif k === :position
            move_pos = v; continue
        elseif k === :priority
            valid_priority(v) || throw(ArgumentError("invalid priority: $v"))
        end
        push!(fields, "$(k) = ?")
        push!(vals, (v isa Date) ? string(v) : v)
    end
    if !isempty(fields)
        push!(vals, _dt_str(Dates.now(UTC))); push!(vals, id)
        _exec(store.db, "UPDATE issues SET $(join(fields, ", ")), updated = ? WHERE id = ?", vals)
    end
    # C4: route status/position through move_issue! so positions stay dense
    # (0..n-1) and a status change reindexes both columns — never a raw write.
    if move_status !== nothing || move_pos !== nothing
        move_issue!(store, id; status = move_status, position = move_pos)
    end
    get_issue(store, id)
end

function delete_issue!(store::SQLiteBoardStore, id::AbstractString)::Bool
    iss = get_issue(store, id)
    iss === nothing && return false
    _assert_project_writable!(store, iss.project_id)
    _exec(store.db, "DELETE FROM issues WHERE id = ?", [id])
    _exec(store.db, "DELETE FROM issue_labels WHERE issue_id = ?", [id])
    _reindex_status!(store, iss.project_id, iss.status)
    true
end

# ── Dense, collision-free ranking (scoped by project_id + status) ─────────
function _set_status_pos!(store, id, status, pos)
    _exec(store.db, "UPDATE issues SET status = ?, position = ?, updated = ? WHERE id = ?",
          [status, pos, _dt_str(Dates.now(UTC)), id])
end

"Renumber a project's status column to dense 0..n-1 (PR-M2 Key Decision #7)."
function _reindex_status!(store, project_id::AbstractString, status)
    r = _query(store.db,
               "SELECT id FROM issues WHERE project_id = ? AND status = ? ORDER BY position, key",
               [project_id, status])
    for (i, iid) in enumerate(r.id)
        _exec(store.db, "UPDATE issues SET position = ? WHERE id = ?", [i - 1, String(iid)])
    end
end

"""
    move_issue!(store, id; status=nothing, position=nothing) -> Issue | nothing

Move an issue to `status` (default: unchanged) at 0-based `position` (default:
end). Siblings are **same-project** only so positions stay dense (0..n-1) per
`(project_id, status)`; the vacated status column is reindexed too.
"""
function move_issue!(store::SQLiteBoardStore, id::AbstractString;
                     status::Union{AbstractString,Nothing} = nothing,
                     position::Union{Integer,Nothing} = nothing)
    iss = get_issue(store, id)
    iss === nothing && return nothing
    _assert_project_writable!(store, iss.project_id)
    pid = iss.project_id
    old_status = iss.status
    new_status = status === nothing ? old_status : String(status)
    valid_status(new_status) || throw(ArgumentError("invalid status: $new_status"))
    sib = String[String(x) for x in
                 _query(store.db,
                        "SELECT id FROM issues WHERE project_id = ? AND status = ? AND id != ? ORDER BY position, key",
                        [pid, new_status, id]).id]
    pos = position === nothing ? length(sib) : clamp(Int(position), 0, length(sib))
    order = copy(sib)
    insert!(order, pos + 1, id)
    for (i, iid) in enumerate(order)
        _set_status_pos!(store, iid, new_status, i - 1)
    end
    new_status == old_status || _reindex_status!(store, pid, old_status)
    get_issue(store, id)
end

"""
    rank_issue!(store, id; position) -> Issue | nothing

Reorder an issue within its current (project, status) to 0-based `position`,
keeping positions dense and collision-free.
"""
rank_issue!(store::SQLiteBoardStore, id::AbstractString; position::Integer) =
    move_issue!(store, id; position = position)

# ── Epics ─────────────────────────────────────────────────────────────────
function _epic_from(r, i)::Epic
    Epic(; id = String(r.id[i]), key = String(r.key[i]), name = String(r.name[i]),
         color = String(r.color[i]), created = parse_dt(r.created[i]),
         project_id = _str_or_empty(hasproperty(r, :project_id) ? r.project_id[i] : nothing))
end

function create_epic!(store::SQLiteBoardStore; name::AbstractString, color::AbstractString = "violet",
                      project_id::Union{AbstractString,Nothing} = nothing)::Epic
    pid, pkey = _resolve_project_id(store.db, project_id)
    id = new_id(); key = _generate_epic_key(store.db, pkey); created = Dates.now(UTC)
    _exec(store.db,
          "INSERT INTO epics (id, key, name, color, created, project_id) VALUES (?, ?, ?, ?, ?, ?)",
          [id, key, name, color, _dt_str(created), pid])
    Epic(; id = id, key = key, name = name, color = color, created = created, project_id = pid)
end
function get_epic(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM epics WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    _epic_from(r, 1)
end
function list_epics(store::SQLiteBoardStore;
                    project_id::Union{AbstractString,Nothing} = nothing)::Vector{Epic}
    project_id = _norm_project_filter(project_id)
    r = project_id === nothing ?
        _query(store.db, "SELECT * FROM epics ORDER BY key") :
        _query(store.db, "SELECT * FROM epics WHERE project_id = ? ORDER BY key", [project_id])
    [_epic_from(r, i) for i in eachindex(r.id)]
end
function update_epic!(store::SQLiteBoardStore, id::AbstractString; name = nothing, color = nothing)
    ep = get_epic(store, id)
    ep === nothing && return nothing
    fields = String[]; vals = Any[]
    name === nothing || (push!(fields, "name = ?"); push!(vals, name))
    color === nothing || (push!(fields, "color = ?"); push!(vals, color))
    isempty(fields) && return ep
    _assert_project_writable!(store, ep.project_id)
    push!(vals, id)
    _exec(store.db, "UPDATE epics SET $(join(fields, ", ")) WHERE id = ?", vals)
    get_epic(store, id)
end
function delete_epic!(store::SQLiteBoardStore, id::AbstractString)::Bool
    ep = get_epic(store, id)
    ep === nothing && return false
    _assert_project_writable!(store, ep.project_id)
    _exec(store.db, "DELETE FROM epics WHERE id = ?", [id]); true
end

# ── Sprints ─────────────────────────────────────────────────────────────────
function create_sprint!(store::SQLiteBoardStore; name::AbstractString, goal::AbstractString = "",
                        start_date::Union{Date,Nothing} = nothing,
                        end_date::Union{Date,Nothing} = nothing,
                        project_id::Union{AbstractString,Nothing} = nothing)::Sprint
    pid, _ = _resolve_project_id(store.db, project_id)
    id = new_id()
    _exec(store.db,
          "INSERT INTO sprints (id, name, goal, start_date, end_date, state, project_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [id, name, goal, _date_str(start_date), _date_str(end_date), "future", pid])
    Sprint(; id = id, name = name, goal = goal, start_date = start_date, end_date = end_date,
           state = :future, project_id = pid)
end
function _sprint_from(r, i)::Sprint
    Sprint(; id = String(r.id[i]), name = String(r.name[i]),
           goal = r.goal[i] === missing ? "" : String(r.goal[i]),
           start_date = parse_date(r.start_date[i]), end_date = parse_date(r.end_date[i]),
           state = Symbol(r.state[i]),
           project_id = _str_or_empty(hasproperty(r, :project_id) ? r.project_id[i] : nothing))
end
function get_sprint(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM sprints WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    _sprint_from(r, 1)
end
function list_sprints(store::SQLiteBoardStore;
                      project_id::Union{AbstractString,Nothing} = nothing)::Vector{Sprint}
    project_id = _norm_project_filter(project_id)
    r = project_id === nothing ?
        _query(store.db, "SELECT * FROM sprints ORDER BY name") :
        _query(store.db, "SELECT * FROM sprints WHERE project_id = ? ORDER BY name", [project_id])
    [_sprint_from(r, i) for i in eachindex(r.id)]
end
function update_sprint!(store::SQLiteBoardStore, id::AbstractString;
                        name = nothing, goal = nothing, start_date = nothing, end_date = nothing)
    sp = get_sprint(store, id)
    sp === nothing && return nothing
    fields = String[]; vals = Any[]
    name === nothing || (push!(fields, "name = ?"); push!(vals, name))
    goal === nothing || (push!(fields, "goal = ?"); push!(vals, goal))
    start_date === nothing || (push!(fields, "start_date = ?"); push!(vals, string(start_date)))
    end_date === nothing || (push!(fields, "end_date = ?"); push!(vals, string(end_date)))
    isempty(fields) && return sp
    _assert_project_writable!(store, sp.project_id)
    push!(vals, id)
    _exec(store.db, "UPDATE sprints SET $(join(fields, ", ")) WHERE id = ?", vals)
    get_sprint(store, id)
end
"""
    start_sprint!(store, id) -> Sprint

Start a future sprint. C8: the check-and-set runs inside a transaction and the
UPDATE is guarded (`AND state='future'`). Single-active is **per project**
(Key Decision #6): another project's active sprint does not block this one.
"""
function start_sprint!(store::SQLiteBoardStore, id::AbstractString)::Sprint
    local s2
    SQLite.transaction(store.db) do
        s = get_sprint(store, id)
        s === nothing && throw(ArgumentError("no such sprint: $id"))
        # Archive write guard: cannot start a planning window on an archived project.
        _assert_project_writable!(store, s.project_id)
        if active_sprint(store; project_id = s.project_id) !== nothing
            throw(ArgumentError("another sprint is already active in this project"))
        end
        s2 = transition(s, :active)
        _exec(store.db, "UPDATE sprints SET state = 'active' WHERE id = ? AND state = 'future'", [id])
    end
    s2
end
function close_sprint!(store::SQLiteBoardStore, id::AbstractString)::Sprint
    local s2
    SQLite.transaction(store.db) do
        s = get_sprint(store, id)
        s === nothing && throw(ArgumentError("no such sprint: $id"))
        s2 = transition(s, :closed)
        _exec(store.db, "UPDATE sprints SET state = 'closed' WHERE id = ? AND state = 'active'", [id])
    end
    s2
end
"""
    active_sprint(store; project_id) -> Sprint | nothing

PR-M2: `project_id` is **required for real use** (UI always passes active project).
When omitted / empty, falls back to any active sprint (store-test compat only).
"""
function active_sprint(store::SQLiteBoardStore;
                       project_id::Union{AbstractString,Nothing} = nothing)
    project_id = _norm_project_filter(project_id)
    r = project_id === nothing ?
        _query(store.db, "SELECT * FROM sprints WHERE state = 'active' ORDER BY name, id LIMIT 1") :
        _query(store.db,
               "SELECT * FROM sprints WHERE state = 'active' AND project_id = ? ORDER BY name, id LIMIT 1",
               [project_id])
    isempty(r.id) && return nothing
    _sprint_from(r, 1)
end

# ── Labels ─────────────────────────────────────────────────────────────────
function create_label!(store::SQLiteBoardStore; name::AbstractString, color::AbstractString = "blue",
                       project_id::Union{AbstractString,Nothing} = nothing)::Label
    pid, _ = _resolve_project_id(store.db, project_id)
    id = new_id()
    _exec(store.db, "INSERT INTO labels (id, name, color, project_id) VALUES (?, ?, ?, ?)",
          [id, name, color, pid])
    Label(; id = id, name = name, color = color, project_id = pid)
end
function list_labels(store::SQLiteBoardStore;
                     project_id::Union{AbstractString,Nothing} = nothing)::Vector{Label}
    project_id = _norm_project_filter(project_id)
    r = project_id === nothing ?
        _query(store.db, "SELECT * FROM labels ORDER BY name") :
        _query(store.db, "SELECT * FROM labels WHERE project_id = ? ORDER BY name", [project_id])
    [Label(; id = String(r.id[i]), name = String(r.name[i]), color = String(r.color[i]),
           project_id = _str_or_empty(hasproperty(r, :project_id) ? r.project_id[i] : nothing))
     for i in eachindex(r.id)]
end
function set_labels!(store::SQLiteBoardStore, issue_id::AbstractString, label_ids::Vector{String})
    iss = get_issue(store, issue_id)
    iss === nothing && throw(ArgumentError("no such issue: $issue_id"))
    _assert_project_writable!(store, iss.project_id)
    _assert_issue_refs!(store, iss.project_id; labels = label_ids)
    _exec(store.db, "DELETE FROM issue_labels WHERE issue_id = ?", [issue_id])
    for lid in label_ids
        _exec(store.db, "INSERT INTO issue_labels (issue_id, label_id) VALUES (?, ?)", [issue_id, lid])
    end
    label_ids
end
function labels_for_issue(store::SQLiteBoardStore, issue_id::AbstractString)::Vector{String}
    r = _query(store.db, "SELECT label_id FROM issue_labels WHERE issue_id = ? ORDER BY label_id", [issue_id])
    String[String(x) for x in r.label_id]
end

# ── Comments ───────────────────────────────────────────────────────────────
function add_comment!(store::SQLiteBoardStore; issue_id::AbstractString,
                      author_id::AbstractString, body::AbstractString)::Comment
    id = new_id(); created = Dates.now(UTC)
    _exec(store.db, "INSERT INTO comments (id, issue_id, author_id, body, created) VALUES (?, ?, ?, ?, ?)",
          [id, issue_id, author_id, body, _dt_str(created)])
    Comment(; id = id, issue_id = issue_id, author_id = author_id, body = body, created = created)
end
function list_comments(store::SQLiteBoardStore, issue_id::AbstractString)::Vector{Comment}
    r = _query(store.db, "SELECT * FROM comments WHERE issue_id = ? ORDER BY created", [issue_id])
    [Comment(; id = String(r.id[i]), issue_id = String(r.issue_id[i]), author_id = String(r.author_id[i]),
             body = String(r.body[i]), created = parse_dt(r.created[i])) for i in eachindex(r.id)]
end

# ── Activity log ───────────────────────────────────────────────────────────
function log_activity!(store::SQLiteBoardStore; issue_id::AbstractString,
                       actor_id::Union{AbstractString,Nothing} = nothing,
                       kind::Symbol, detail::AbstractString = "")::ActivityEvent
    id = new_id(); created = Dates.now(UTC)
    _exec(store.db, "INSERT INTO activity (id, issue_id, actor_id, kind, detail, created) VALUES (?, ?, ?, ?, ?, ?)",
          [id, issue_id, actor_id, String(kind), detail, _dt_str(created)])
    ActivityEvent(; id = id, issue_id = issue_id, actor_id = actor_id, kind = kind, detail = detail, created = created)
end
function list_activity(store::SQLiteBoardStore, issue_id::AbstractString)::Vector{ActivityEvent}
    r = _query(store.db, "SELECT * FROM activity WHERE issue_id = ? ORDER BY created", [issue_id])
    [ActivityEvent(; id = String(r.id[i]), issue_id = String(r.issue_id[i]),
                   actor_id = r.actor_id[i] === missing ? nothing : String(r.actor_id[i]),
                   kind = Symbol(r.kind[i]),
                   detail = r.detail[i] === missing ? "" : String(r.detail[i]),
                   created = parse_dt(r.created[i])) for i in eachindex(r.id)]
end

# ── Sprint / backlog membership queries ────────────────────────────────────
function issues_for_sprint(store::SQLiteBoardStore, sprint_id::AbstractString)::Vector{Issue}
    r = _query(store.db, "SELECT * FROM issues WHERE sprint_id = ? ORDER BY status, position, key", [sprint_id])
    [_issue_with_labels(store, _issue_from(r, i)) for i in eachindex(r.id)]
end
function backlog_issues(store::SQLiteBoardStore;
                        project_id::Union{AbstractString,Nothing} = nothing)::Vector{Issue}
    project_id = _norm_project_filter(project_id)
    r = project_id === nothing ?
        _query(store.db, "SELECT * FROM issues WHERE sprint_id IS NULL ORDER BY status, position, key") :
        _query(store.db,
               "SELECT * FROM issues WHERE sprint_id IS NULL AND project_id = ? ORDER BY status, position, key",
               [project_id])
    [_issue_with_labels(store, _issue_from(r, i)) for i in eachindex(r.id)]
end

# ── Outbox ─────────────────────────────────────────────────────────────────
function enqueue_outbox!(store::SQLiteBoardStore; event_kind::Symbol, recipient_email::AbstractString,
                         subject::AbstractString, body::AbstractString)::String
    id = new_id()
    _exec(store.db, "INSERT INTO outbox (id, event_kind, recipient_email, subject, body, created, sent_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
          [id, String(event_kind), recipient_email, subject, body, _dt_str(Dates.now(UTC))])
    id
end
function pending_outbox(store::SQLiteBoardStore)::Vector{Dict{String,Any}}
    r = _query(store.db, "SELECT * FROM outbox WHERE sent_at IS NULL ORDER BY created")
    [Dict{String,Any}(
        "id" => String(r.id[i]), "event_kind" => String(r.event_kind[i]),
        "recipient_email" => String(r.recipient_email[i]), "subject" => String(r.subject[i]),
        "body" => String(r.body[i]), "created" => String(r.created[i])) for i in eachindex(r.id)]
end
function mark_sent!(store::SQLiteBoardStore, id::AbstractString)::Bool
    _exec(store.db, "UPDATE outbox SET sent_at = ? WHERE id = ?", [_dt_str(Dates.now(UTC)), id])
    true
end

# ── Demo seeding: issues + epics + sprints + labels, ZERO users ────────────
function seed_demo!(store::SQLiteBoardStore)
    def = _default_project(store.db)
    pid = def.id
    isempty(list_issues(store; project_id = pid)) || return store
    epic_a = create_epic!(store; name = "Onboarding", color = "violet", project_id = pid)
    epic_b = create_epic!(store; name = "Board Core", color = "teal", project_id = pid)
    sprint = create_sprint!(store; name = "Sprint 1", goal = "Ship the board",
                            start_date = Dates.today(), end_date = Dates.today() + Day(14),
                            project_id = pid)
    lbl_bug = create_label!(store; name = "bug", color = "red", project_id = pid)
    lbl_ui = create_label!(store; name = "ui", color = "cyan", project_id = pid)
    today = Dates.today()
    i1 = create_issue!(store; title = "Set up project board", status = "Backlog", priority = "High",
                       due_date = today + Day(3), epic_id = epic_b.id, story_points = 3,
                       project_id = pid)
    create_issue!(store; title = "Design login screen", status = "Backlog", priority = "Medium",
                  due_date = today + Day(1), epic_id = epic_a.id, project_id = pid)
    create_issue!(store; title = "Implement card model", status = "To Do", priority = "High",
                  epic_id = epic_b.id, sprint_id = sprint.id, story_points = 5, project_id = pid)
    create_issue!(store; title = "Add QCI colors + logo", status = "To Do", priority = "Medium",
                  epic_id = epic_b.id, project_id = pid)
    create_issue!(store; title = "Board column rendering", status = "In Progress", priority = "High",
                  epic_id = epic_b.id, sprint_id = sprint.id, project_id = pid)
    create_issue!(store; title = "Calendar view + due marks", status = "Review", priority = "Medium",
                  epic_id = epic_a.id, project_id = pid)
    create_issue!(store; title = "Initial DB schema", status = "Done", priority = "High",
                  due_date = today - Day(2), epic_id = epic_b.id, project_id = pid)
    set_labels!(store, i1.id, [lbl_bug.id, lbl_ui.id])
    store
end
