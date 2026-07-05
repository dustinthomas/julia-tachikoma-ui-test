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
    SQLite.DB(path)
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
          created = parse_dt(r.created[i]), updated = parse_dt(r.updated[i]))
end

# C10: bump a monotonic per-prefix counter. On first use the counter seeds from
# the current MAX (so it never collides with pre-existing rows), then only ever
# increases — deleting the highest-numbered issue can never recycle its key.
function _next_seq!(db, prefix::AbstractString, existing_max::Union{Nothing,Missing,Integer})::Int
    row = _query(db, "SELECT last FROM key_seq WHERE prefix = ? LIMIT 1", [prefix])
    last = if isempty(row.last)
        emax = (existing_max === nothing || existing_max === missing) ? 99 : Int(existing_max)
        max(99, emax)   # base is 100 → base-1 == 99
    else
        Int(row.last[1])
    end
    n = last + 1
    _exec(db, """
        INSERT INTO key_seq (prefix, last) VALUES (?, ?)
        ON CONFLICT(prefix) DO UPDATE SET last = ?
    """, [prefix, n, n])
    n
end

function _generate_issue_key(db)::String
    row = _query(db, "SELECT MAX(CAST(substr(key, 5) AS INTEGER)) AS m FROM issues WHERE key LIKE 'QCI-%'")
    n = _next_seq!(db, "QCI", isempty(row.m) ? nothing : row.m[1])
    "QCI-$(n)"
end
function _generate_epic_key(db)::String
    row = _query(db, "SELECT MAX(CAST(substr(key, 6) AS INTEGER)) AS m FROM epics WHERE key LIKE 'EPIC-%'")
    n = _next_seq!(db, "EPIC", isempty(row.m) ? nothing : row.m[1])
    "EPIC-$(n)"
end

_status_count(db, status) = Int(_query(db, "SELECT COUNT(*) AS c FROM issues WHERE status = ?", [status]).c[1])

function create_issue!(store::SQLiteBoardStore; title::AbstractString, description::AbstractString = "",
                       status::AbstractString = "Backlog", priority::AbstractString = "Medium",
                       story_points::Union{Int,Nothing} = nothing,
                       epic_id::Union{AbstractString,Nothing} = nothing,
                       sprint_id::Union{AbstractString,Nothing} = nothing,
                       assignee_id::Union{AbstractString,Nothing} = nothing,
                       reporter_id::Union{AbstractString,Nothing} = nothing,
                       start_date::Union{Date,Nothing} = nothing,
                       due_date::Union{Date,Nothing} = nothing,
                       labels::Vector{String} = String[])::Issue
    valid_status(status) || throw(ArgumentError("invalid status: $status"))
    valid_priority(priority) || throw(ArgumentError("invalid priority: $priority"))
    id = new_id()
    key = _generate_issue_key(store.db)
    now = Dates.now(UTC)
    position = _status_count(store.db, status)   # append → keeps 0..n dense
    _exec(store.db, """
        INSERT INTO issues (id, key, title, description, status, priority, story_points,
            epic_id, sprint_id, assignee_id, reporter_id, start_date, due_date, position, created, updated)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [id, key, title, description, status, priority, story_points, epic_id, sprint_id,
          assignee_id, reporter_id, _date_str(start_date), _date_str(due_date), position,
          _dt_str(now), _dt_str(now)])
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
          position = iss.position, labels = lbls, created = iss.created, updated = iss.updated)
end

function list_issues(store::SQLiteBoardStore; status::Union{AbstractString,Nothing} = nothing)::Vector{Issue}
    r = status === nothing ?
        _query(store.db, "SELECT * FROM issues ORDER BY status, position, key") :
        _query(store.db, "SELECT * FROM issues WHERE status = ? ORDER BY position, key", [status])
    [_issue_with_labels(store, _issue_from(r, i)) for i in eachindex(r.id)]
end

const _ISSUE_UPDATE_FIELDS = (:title, :description, :status, :priority, :story_points,
    :epic_id, :sprint_id, :assignee_id, :reporter_id, :start_date, :due_date, :position)

function update_issue!(store::SQLiteBoardStore, id::AbstractString; kwargs...)
    move_status = nothing; move_pos = nothing
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
    _exec(store.db, "DELETE FROM issues WHERE id = ?", [id])
    _exec(store.db, "DELETE FROM issue_labels WHERE issue_id = ?", [id])
    _reindex_status!(store, iss.status)
    true
end

# ── Dense, collision-free ranking ─────────────────────────────────────────
function _set_status_pos!(store, id, status, pos)
    _exec(store.db, "UPDATE issues SET status = ?, position = ?, updated = ? WHERE id = ?",
          [status, pos, _dt_str(Dates.now(UTC)), id])
end

"Renumber a status's issues to 0..n-1 in current order (closes any gaps)."
function _reindex_status!(store, status)
    r = _query(store.db, "SELECT id FROM issues WHERE status = ? ORDER BY position, key", [status])
    for (i, iid) in enumerate(r.id)
        _exec(store.db, "UPDATE issues SET position = ? WHERE id = ?", [i - 1, String(iid)])
    end
end

"""
    move_issue!(store, id; status=nothing, position=nothing) -> Issue | nothing

Move an issue to `status` (default: unchanged) at 0-based `position` (default:
end). Siblings shift so positions stay dense (0..n-1) and collision-free; the
vacated status is reindexed too.
"""
function move_issue!(store::SQLiteBoardStore, id::AbstractString;
                     status::Union{AbstractString,Nothing} = nothing,
                     position::Union{Integer,Nothing} = nothing)
    iss = get_issue(store, id)
    iss === nothing && return nothing
    old_status = iss.status
    new_status = status === nothing ? old_status : String(status)
    valid_status(new_status) || throw(ArgumentError("invalid status: $new_status"))
    sib = String[String(x) for x in
                 _query(store.db, "SELECT id FROM issues WHERE status = ? AND id != ? ORDER BY position, key",
                        [new_status, id]).id]
    pos = position === nothing ? length(sib) : clamp(Int(position), 0, length(sib))
    order = copy(sib)
    insert!(order, pos + 1, id)
    for (i, iid) in enumerate(order)
        _set_status_pos!(store, iid, new_status, i - 1)
    end
    new_status == old_status || _reindex_status!(store, old_status)
    get_issue(store, id)
end

"""
    rank_issue!(store, id; position) -> Issue | nothing

Reorder an issue within its current status to 0-based `position`, keeping
positions dense and collision-free.
"""
rank_issue!(store::SQLiteBoardStore, id::AbstractString; position::Integer) =
    move_issue!(store, id; position = position)

# ── Epics ─────────────────────────────────────────────────────────────────
function create_epic!(store::SQLiteBoardStore; name::AbstractString, color::AbstractString = "violet")::Epic
    id = new_id(); key = _generate_epic_key(store.db); created = Dates.now(UTC)
    _exec(store.db, "INSERT INTO epics (id, key, name, color, created) VALUES (?, ?, ?, ?, ?)",
          [id, key, name, color, _dt_str(created)])
    Epic(; id = id, key = key, name = name, color = color, created = created)
end
function get_epic(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM epics WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    Epic(; id = String(r.id[1]), key = String(r.key[1]), name = String(r.name[1]),
         color = String(r.color[1]), created = parse_dt(r.created[1]))
end
function list_epics(store::SQLiteBoardStore)::Vector{Epic}
    r = _query(store.db, "SELECT * FROM epics ORDER BY key")
    [Epic(; id = String(r.id[i]), key = String(r.key[i]), name = String(r.name[i]),
          color = String(r.color[i]), created = parse_dt(r.created[i])) for i in eachindex(r.id)]
end
function update_epic!(store::SQLiteBoardStore, id::AbstractString; name = nothing, color = nothing)
    fields = String[]; vals = Any[]
    name === nothing || (push!(fields, "name = ?"); push!(vals, name))
    color === nothing || (push!(fields, "color = ?"); push!(vals, color))
    isempty(fields) && return get_epic(store, id)
    push!(vals, id)
    _exec(store.db, "UPDATE epics SET $(join(fields, ", ")) WHERE id = ?", vals)
    get_epic(store, id)
end
function delete_epic!(store::SQLiteBoardStore, id::AbstractString)::Bool
    _exec(store.db, "DELETE FROM epics WHERE id = ?", [id]); true
end

# ── Sprints ─────────────────────────────────────────────────────────────────
function create_sprint!(store::SQLiteBoardStore; name::AbstractString, goal::AbstractString = "",
                        start_date::Union{Date,Nothing} = nothing,
                        end_date::Union{Date,Nothing} = nothing)::Sprint
    id = new_id()
    _exec(store.db, "INSERT INTO sprints (id, name, goal, start_date, end_date, state) VALUES (?, ?, ?, ?, ?, ?)",
          [id, name, goal, _date_str(start_date), _date_str(end_date), "future"])
    Sprint(; id = id, name = name, goal = goal, start_date = start_date, end_date = end_date, state = :future)
end
function _sprint_from(r, i)::Sprint
    Sprint(; id = String(r.id[i]), name = String(r.name[i]),
           goal = r.goal[i] === missing ? "" : String(r.goal[i]),
           start_date = parse_date(r.start_date[i]), end_date = parse_date(r.end_date[i]),
           state = Symbol(r.state[i]))
end
function get_sprint(store::SQLiteBoardStore, id::AbstractString)
    r = _query(store.db, "SELECT * FROM sprints WHERE id = ? LIMIT 1", [id])
    isempty(r.id) && return nothing
    _sprint_from(r, 1)
end
function list_sprints(store::SQLiteBoardStore)::Vector{Sprint}
    r = _query(store.db, "SELECT * FROM sprints ORDER BY name")
    [_sprint_from(r, i) for i in eachindex(r.id)]
end
function update_sprint!(store::SQLiteBoardStore, id::AbstractString;
                        name = nothing, goal = nothing, start_date = nothing, end_date = nothing)
    fields = String[]; vals = Any[]
    name === nothing || (push!(fields, "name = ?"); push!(vals, name))
    goal === nothing || (push!(fields, "goal = ?"); push!(vals, goal))
    start_date === nothing || (push!(fields, "start_date = ?"); push!(vals, string(start_date)))
    end_date === nothing || (push!(fields, "end_date = ?"); push!(vals, string(end_date)))
    isempty(fields) && return get_sprint(store, id)
    push!(vals, id)
    _exec(store.db, "UPDATE sprints SET $(join(fields, ", ")) WHERE id = ?", vals)
    get_sprint(store, id)
end
"""
    start_sprint!(store, id) -> Sprint

Start a future sprint. C8: the check-and-set runs inside a transaction and the
UPDATE is guarded (`AND state='future'`) so the single-active invariant is
enforced at the DB level, not just check-then-act.
"""
function start_sprint!(store::SQLiteBoardStore, id::AbstractString)::Sprint
    local s2
    SQLite.transaction(store.db) do
        s = get_sprint(store, id)
        s === nothing && throw(ArgumentError("no such sprint: $id"))
        active_sprint(store) === nothing || throw(ArgumentError("another sprint is already active"))
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
function active_sprint(store::SQLiteBoardStore)
    r = _query(store.db, "SELECT * FROM sprints WHERE state = 'active' ORDER BY name, id LIMIT 1")
    isempty(r.id) && return nothing
    _sprint_from(r, 1)
end

# ── Labels ─────────────────────────────────────────────────────────────────
function create_label!(store::SQLiteBoardStore; name::AbstractString, color::AbstractString = "blue")::Label
    id = new_id()
    _exec(store.db, "INSERT INTO labels (id, name, color) VALUES (?, ?, ?)", [id, name, color])
    Label(; id = id, name = name, color = color)
end
function list_labels(store::SQLiteBoardStore)::Vector{Label}
    r = _query(store.db, "SELECT * FROM labels ORDER BY name")
    [Label(; id = String(r.id[i]), name = String(r.name[i]), color = String(r.color[i])) for i in eachindex(r.id)]
end
function set_labels!(store::SQLiteBoardStore, issue_id::AbstractString, label_ids::Vector{String})
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
function backlog_issues(store::SQLiteBoardStore)::Vector{Issue}
    r = _query(store.db, "SELECT * FROM issues WHERE sprint_id IS NULL ORDER BY status, position, key")
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
    isempty(list_issues(store)) || return store
    epic_a = create_epic!(store; name = "Onboarding", color = "violet")
    epic_b = create_epic!(store; name = "Board Core", color = "teal")
    sprint = create_sprint!(store; name = "Sprint 1", goal = "Ship the board",
                            start_date = Dates.today(), end_date = Dates.today() + Day(14))
    lbl_bug = create_label!(store; name = "bug", color = "red")
    lbl_ui = create_label!(store; name = "ui", color = "cyan")
    today = Dates.today()
    i1 = create_issue!(store; title = "Set up project board", status = "Backlog", priority = "High",
                       due_date = today + Day(3), epic_id = epic_b.id, story_points = 3)
    create_issue!(store; title = "Design login screen", status = "Backlog", priority = "Medium",
                  due_date = today + Day(1), epic_id = epic_a.id)
    create_issue!(store; title = "Implement card model", status = "To Do", priority = "High",
                  epic_id = epic_b.id, sprint_id = sprint.id, story_points = 5)
    create_issue!(store; title = "Add QCI colors + logo", status = "To Do", priority = "Medium",
                  epic_id = epic_b.id)
    create_issue!(store; title = "Board column rendering", status = "In Progress", priority = "High",
                  epic_id = epic_b.id, sprint_id = sprint.id)
    create_issue!(store; title = "Calendar view + due marks", status = "Review", priority = "Medium",
                  epic_id = epic_a.id)
    create_issue!(store; title = "Initial DB schema", status = "Done", priority = "High",
                  due_date = today - Day(2), epic_id = epic_b.id)
    set_labels!(store, i1.id, [lbl_bug.id, lbl_ui.id])
    store
end
