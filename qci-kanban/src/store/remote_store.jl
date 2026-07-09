# ═══════════════════════════════════════════════════════════════════════
# store/remote_store.jl — Postgres implementation of both store contracts.
#
# ALL SQL-building and row-mapping is in pure functions (unit-tested with a
# fake exec). The only LibPQ-touching code is the thin `exec` boundary and
# the connection constructor, both marked `# COV_EXCL` (see COVERAGE.md) —
# they cannot run without a live Postgres and are excluded from coverage.
#
# Contract: `store.exec(sql::String, params::Vector)::Vector{Dict{String,Any}}`
# returns one Dict per row (column name => value) for SELECTs, and any value
# (ignored) for writes.
# ═══════════════════════════════════════════════════════════════════════

using Dates

export RemoteUserStore, RemoteBoardStore, FakeExec
export remote_row_to_user, remote_row_to_issue, remote_row_to_epic,
       remote_row_to_sprint, remote_row_to_comment, remote_row_to_label,
       remote_row_to_activity, remote_row_to_project
export pg_placeholders, pg_conninfo

# ── Store types (exec is injectable) ─────────────────────────────────────
struct RemoteUserStore <: AbstractUserStore
    exec::Any
end
# PR-M1b: project CRUD + optional `project_id` kwargs on create/list (FakeExec path).
struct RemoteBoardStore <: AbstractBoardStore
    exec::Any
end

# ── Fake exec for tests ──────────────────────────────────────────────────
"""
    FakeExec(responder)

Callable recording every `(sql, params)` and returning `responder(sql, params)`
(a `Vector{Dict{String,Any}}`). Lets remote-store logic be tested with no
Postgres present.
"""
mutable struct FakeExec
    calls::Vector{Tuple{String,Vector{Any}}}
    responder::Any
end
FakeExec(responder = (sql, params) -> Dict{String,Any}[]) =
    FakeExec(Tuple{String,Vector{Any}}[], responder)
function (f::FakeExec)(sql::AbstractString, params::AbstractVector)
    push!(f.calls, (String(sql), Vector{Any}(params)))
    f.responder(sql, params)
end

# ── Pure helpers ─────────────────────────────────────────────────────────
"pg_placeholders(3) == \"\$1, \$2, \$3\""
pg_placeholders(n::Integer) = join(("\$$(i)" for i in 1:n), ", ")

# S10: build a libpq conninfo string with each value single-quoted and backslash/
# quote-escaped, so a value containing spaces or quotes cannot inject extra
# connection keywords. (Pure + covered; `connect_remote` uses it.)
_pg_quote(v)::String = "'" * replace(string(v), "\\" => "\\\\", "'" => "\\'") * "'"
function pg_conninfo(cfg::PostgresConfig)::String
    join(("$(k)=$(_pg_quote(v))" for (k, v) in
          (("host", cfg.host), ("port", cfg.port), ("dbname", cfg.dbname),
           ("user", cfg.user), ("password", cfg.password))), " ")
end

_val(::Nothing) = nothing
_val(::Missing) = nothing
_val(x) = x
_get(d, k) = _val(get(d, k, nothing))

# ── Pure row mappers ─────────────────────────────────────────────────────
function remote_row_to_user(d::AbstractDict)::User
    User(; id = String(_get(d, "id")), email = String(_get(d, "email")),
         name = String(_get(d, "name")),
         active = let a = _get(d, "active"); a === nothing ? true : (a == 1 || a === true) end,
         created = parse_dt(something(_get(d, "created"), Dates.now(UTC))))
end

function remote_row_to_project(d::AbstractDict)::Project
    color = let x = _get(d, "color"); x === nothing || isempty(String(x)) ? "blue" : String(x) end
    Project(; id = String(_get(d, "id")), key = String(_get(d, "key")), name = String(_get(d, "name")),
            description = let x = _get(d, "description"); x === nothing ? "" : String(x) end,
            color = color,
            archived = let a = _get(d, "archived"); a === nothing ? false : (a == 1 || a === true) end,
            created = parse_dt(something(_get(d, "created"), Dates.now(UTC))))
end

function remote_row_to_issue(d::AbstractDict)::Issue
    Issue(; id = String(_get(d, "id")), key = String(_get(d, "key")),
          title = String(_get(d, "title")),
          description = let x = _get(d, "description"); x === nothing ? "" : String(x) end,
          status = String(_get(d, "status")), priority = String(_get(d, "priority")),
          story_points = parse_points(_get(d, "story_points")),
          epic_id = let x = _get(d, "epic_id"); x === nothing ? nothing : String(x) end,
          sprint_id = let x = _get(d, "sprint_id"); x === nothing ? nothing : String(x) end,
          assignee_id = let x = _get(d, "assignee_id"); x === nothing ? nothing : String(x) end,
          reporter_id = let x = _get(d, "reporter_id"); x === nothing ? nothing : String(x) end,
          start_date = parse_date(_get(d, "start_date")), due_date = parse_date(_get(d, "due_date")),
          position = Int(something(_get(d, "position"), 0)), labels = String[],
          created = parse_dt(something(_get(d, "created"), Dates.now(UTC))),
          updated = parse_dt(something(_get(d, "updated"), Dates.now(UTC))),
          project_id = let x = _get(d, "project_id"); x === nothing ? "" : String(x) end)
end

remote_row_to_epic(d::AbstractDict)::Epic =
    Epic(; id = String(_get(d, "id")), key = String(_get(d, "key")), name = String(_get(d, "name")),
         color = String(_get(d, "color")),
         created = parse_dt(something(_get(d, "created"), Dates.now(UTC))),
         project_id = let x = _get(d, "project_id"); x === nothing ? "" : String(x) end)

remote_row_to_sprint(d::AbstractDict)::Sprint =
    Sprint(; id = String(_get(d, "id")), name = String(_get(d, "name")),
           goal = let x = _get(d, "goal"); x === nothing ? "" : String(x) end,
           start_date = parse_date(_get(d, "start_date")), end_date = parse_date(_get(d, "end_date")),
           state = Symbol(_get(d, "state")),
           project_id = let x = _get(d, "project_id"); x === nothing ? "" : String(x) end)

remote_row_to_comment(d::AbstractDict)::Comment =
    Comment(; id = String(_get(d, "id")), issue_id = String(_get(d, "issue_id")),
            author_id = String(_get(d, "author_id")), body = String(_get(d, "body")),
            created = parse_dt(something(_get(d, "created"), Dates.now(UTC))))

remote_row_to_label(d::AbstractDict)::Label =
    Label(; id = String(_get(d, "id")), name = String(_get(d, "name")), color = String(_get(d, "color")),
          project_id = let x = _get(d, "project_id"); x === nothing ? "" : String(x) end)

remote_row_to_activity(d::AbstractDict)::ActivityEvent =
    ActivityEvent(; id = String(_get(d, "id")), issue_id = String(_get(d, "issue_id")),
                  actor_id = let x = _get(d, "actor_id"); x === nothing ? nothing : String(x) end,
                  kind = Symbol(_get(d, "kind")),
                  detail = let x = _get(d, "detail"); x === nothing ? "" : String(x) end,
                  created = parse_dt(something(_get(d, "created"), Dates.now(UTC))))

# ═══════════════════════════ USER STORE ═══════════════════════════════════
function create_user!(store::RemoteUserStore; email::AbstractString, name::AbstractString,
                      password::AbstractString)::User
    valid_email(email) || throw(ArgumentError("invalid email: $email"))
    id = new_id(); created = Dates.now(UTC); ph = hash_password(password)
    store.exec("INSERT INTO users (id, email, name, password_hash, salt, iterations, created, active) VALUES ($(pg_placeholders(8)))",
               Any[id, email, name, ph.hash_hex, ph.salt_hex, ph.iterations, _dt_str(created), 1])
    User(; id = id, email = email, name = name, active = true, created = created)
end

function authenticate(store::RemoteUserStore, email::AbstractString, password::AbstractString)
    rows = store.exec("SELECT id, email, name, password_hash, salt, iterations, created, active FROM users WHERE email = \$1 LIMIT 1",
                      Any[email])
    # S3: constant-work dummy verify for absent/inactive email → no timing oracle.
    (isempty(rows) || !(_get(rows[1], "active") in (1, true))) && (_dummy_verify(password); return nothing)
    d = rows[1]
    ph = PasswordHash(String(_get(d, "password_hash")), String(_get(d, "salt")), Int(_get(d, "iterations")))
    verify_password(password, ph) || return nothing
    remote_row_to_user(d)
end

function get_user(store::RemoteUserStore, id::AbstractString)
    rows = store.exec("SELECT id, email, name, created, active FROM users WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_user(rows[1])
end

function get_token_version(store::RemoteUserStore, id::AbstractString)::Int
    rows = store.exec("SELECT token_version FROM users WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) ? 0 : Int(something(_get(rows[1], "token_version"), 0))
end

function bump_token_version!(store::RemoteUserStore, id::AbstractString)::Int
    store.exec("UPDATE users SET token_version = token_version + 1 WHERE id = \$1", Any[id])
    get_token_version(store, id)
end

list_users(store::RemoteUserStore)::Vector{User} =
    [remote_row_to_user(d) for d in store.exec("SELECT id, email, name, created, active FROM users ORDER BY name", Any[])]

function deactivate_user!(store::RemoteUserStore, id::AbstractString)::Bool
    store.exec("UPDATE users SET active = 0, token_version = token_version + 1 WHERE id = \$1", Any[id]); true
end

# ═══════════════════════════ BOARD STORE ══════════════════════════════════
# C10: monotonic per-prefix key counter (mirrors sqlite_store `_next_seq!`).
function _remote_next_seq!(store, prefix::AbstractString, existing_max)::Int
    rows = store.exec("SELECT last FROM key_seq WHERE prefix = \$1 LIMIT 1", Any[prefix])
    cur = isempty(rows) ? nothing : _get(rows[1], "last")
    emax = existing_max === nothing ? nothing : Int(existing_max)
    stored = cur === nothing ? nothing : Int(cur)
    last = max(99, something(stored, 99), something(emax, 99))
    n = last + 1
    store.exec("INSERT INTO key_seq (prefix, last) VALUES (\$1, \$2) ON CONFLICT(prefix) DO UPDATE SET last = \$3",
               Any[prefix, n, n])
    n
end

"""Max numeric suffix for issue keys `{project_key}-{n}` (reject multi-hyphen)."""
function _remote_max_issue_num(store, project_key::AbstractString)
    rows = store.exec("SELECT key FROM issues WHERE key LIKE \$1", Any[project_key * "-%"])
    maxn = nothing
    re = Regex("^" * project_key * "-(\\d+)\$")
    for d in rows
        m = match(re, String(_get(d, "key")))
        m === nothing && continue
        n = parse(Int, m.captures[1])
        maxn = maxn === nothing ? n : max(maxn, n)
    end
    maxn
end

"""Max numeric suffix for epic keys `{project_key}-E-{n}`."""
function _remote_max_epic_num(store, project_key::AbstractString)
    rows = store.exec("SELECT key FROM epics WHERE key LIKE \$1", Any[project_key * "-E-%"])
    maxn = nothing
    re = Regex("^" * project_key * "-E-(\\d+)\$")
    for d in rows
        m = match(re, String(_get(d, "key")))
        m === nothing && continue
        n = parse(Int, m.captures[1])
        maxn = maxn === nothing ? n : max(maxn, n)
    end
    maxn
end

function _remote_generate_issue_key(store, project_key::AbstractString)::String
    n = _remote_next_seq!(store, project_key, _remote_max_issue_num(store, project_key))
    "$(project_key)-$(n)"
end
function _remote_generate_epic_key(store, project_key::AbstractString)::String
    n = _remote_next_seq!(store, "$(project_key)#EPIC", _remote_max_epic_num(store, project_key))
    "$(project_key)-E-$(n)"
end
_remote_status_count(store, status)::Int =
    let rows = store.exec("SELECT COUNT(*) AS c FROM issues WHERE status = \$1", Any[status])
        isempty(rows) ? 0 : Int(something(_get(rows[1], "c"), 0))
    end

# ── Projects ──────────────────────────────────────────────────────────────
function create_project!(store::RemoteBoardStore; key::AbstractString, name::AbstractString,
                         description::AbstractString = "",
                         color::AbstractString = "blue")::Project
    valid_project_key(key) || throw(ArgumentError("invalid project key: $key"))
    isempty(strip(name)) && throw(ArgumentError("project name must not be empty"))
    existing = store.exec("SELECT id FROM projects WHERE key = \$1 LIMIT 1", Any[key])
    isempty(existing) || throw(ArgumentError("project key already exists: $key"))
    id = new_id(); created = Dates.now(UTC)
    store.exec("INSERT INTO projects (id, key, name, description, color, archived, created) VALUES ($(pg_placeholders(7)))",
               Any[id, key, name, description, color, 0, _dt_str(created)])
    Project(; id = id, key = key, name = name, description = description,
            color = color, archived = false, created = created)
end

function get_project(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM projects WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_project(rows[1])
end

function list_projects(store::RemoteBoardStore; include_archived::Bool = false)::Vector{Project}
    rows = include_archived ?
        store.exec("SELECT * FROM projects ORDER BY key", Any[]) :
        store.exec("SELECT * FROM projects WHERE archived = 0 ORDER BY key", Any[])
    [remote_row_to_project(d) for d in rows]
end

function archive_project!(store::RemoteBoardStore, id::AbstractString)::Project
    p = get_project(store, id)
    p === nothing && throw(ArgumentError("no such project: $id"))
    p.archived && return p
    act = store.exec(
        "SELECT id FROM sprints WHERE project_id = \$1 AND state = 'active' LIMIT 1", Any[id])
    isempty(act) || throw(ArgumentError("cannot archive project with an active sprint"))
    store.exec("UPDATE projects SET archived = 1 WHERE id = \$1", Any[id])
    get_project(store, id)
end

function _remote_default_project(store)::Project
    rows = store.exec("SELECT * FROM projects WHERE key = \$1 LIMIT 1", Any[DEFAULT_PROJECT_KEY])
    isempty(rows) && throw(ErrorException("Default project missing — run migrations"))
    remote_row_to_project(rows[1])
end

"""Resolve optional project_id to a real non-archived project id (Default if omitted)."""
function _remote_resolve_project_id(store, project_id::Union{AbstractString,Nothing})::Tuple{String,String}
    if project_id === nothing || isempty(String(project_id))
        p = _remote_default_project(store)
        p.archived && throw(ArgumentError("project is archived: $(p.id)"))
        return (p.id, p.key)
    end
    p = get_project(store, project_id)
    p === nothing && throw(ArgumentError("no such project: $project_id"))
    p.archived && throw(ArgumentError("project is archived: $project_id"))
    (p.id, p.key)
end

"""Throw if `project_id` names an archived project (no-op for empty/missing id)."""
function _remote_assert_project_writable!(store::RemoteBoardStore, project_id::AbstractString)
    isempty(project_id) && return nothing
    p = get_project(store, project_id)
    p === nothing && return nothing
    p.archived && throw(ArgumentError("project is archived: $project_id"))
    nothing
end

function board_schema_version(store::RemoteBoardStore)::Int
    rows = store.exec("SELECT MAX(version) AS v FROM schema_migrations", Any[])
    isempty(rows) && return 0
    Int(something(_get(rows[1], "v"), 0))
end

# Note: `key=` / `position=` are FakeExec/test ergonomics (pre-existing remote
# convenience). SQLite always generates `{project_key}-n` keys and appends
# position. App code must omit them so keys stay project-scoped; an explicit
# `key="QCI-9"` with `project_id=la` is allowed but not validated against
# `pkey` (no prefix assert in MVP). Same for `create_epic!(…; key=)`.
function create_issue!(store::RemoteBoardStore; title::AbstractString, description::AbstractString = "",
                       status::AbstractString = "Backlog", priority::AbstractString = "Medium",
                       story_points::Union{Int,Nothing} = nothing,
                       epic_id::Union{AbstractString,Nothing} = nothing,
                       sprint_id::Union{AbstractString,Nothing} = nothing,
                       assignee_id::Union{AbstractString,Nothing} = nothing,
                       reporter_id::Union{AbstractString,Nothing} = nothing,
                       start_date::Union{Date,Nothing} = nothing,
                       due_date::Union{Date,Nothing} = nothing,
                       key::Union{AbstractString,Nothing} = nothing,
                       position::Union{Integer,Nothing} = nothing,
                       project_id::Union{AbstractString,Nothing} = nothing)::Issue
    valid_status(status) || throw(ArgumentError("invalid status: $status"))
    valid_priority(priority) || throw(ArgumentError("invalid priority: $priority"))
    pid, pkey = _remote_resolve_project_id(store, project_id)
    id = new_id(); now = Dates.now(UTC)
    # C2: MAX+1 sequential key (not random) and append-position (count in status).
    k = key === nothing ? _remote_generate_issue_key(store, pkey) : String(key)
    pos = position === nothing ? _remote_status_count(store, status) : Int(position)
    store.exec("INSERT INTO issues (id, key, title, description, status, priority, story_points, epic_id, sprint_id, assignee_id, reporter_id, start_date, due_date, position, created, updated, project_id) VALUES ($(pg_placeholders(17)))",
               Any[id, k, title, description, status, priority, story_points, epic_id, sprint_id,
                   assignee_id, reporter_id, _date_str(start_date), _date_str(due_date),
                   pos, _dt_str(now), _dt_str(now), pid])
    Issue(; id = id, key = k, title = title, description = description, status = status,
          priority = priority, story_points = story_points, epic_id = epic_id, sprint_id = sprint_id,
          assignee_id = assignee_id, reporter_id = reporter_id, start_date = start_date,
          due_date = due_date, position = pos, created = now, updated = now, project_id = pid)
end

function get_issue(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM issues WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_issue(rows[1])
end

function list_issues(store::RemoteBoardStore;
                     status::Union{AbstractString,Nothing} = nothing,
                     project_id::Union{AbstractString,Nothing} = nothing)::Vector{Issue}
    project_id = _norm_project_filter(project_id)
    rows = if project_id === nothing && status === nothing
        store.exec("SELECT * FROM issues ORDER BY status, position, key", Any[])
    elseif project_id === nothing
        store.exec("SELECT * FROM issues WHERE status = \$1 ORDER BY position, key", Any[status])
    elseif status === nothing
        store.exec("SELECT * FROM issues WHERE project_id = \$1 ORDER BY status, position, key",
                   Any[project_id])
    else
        store.exec("SELECT * FROM issues WHERE project_id = \$1 AND status = \$2 ORDER BY position, key",
                   Any[project_id, status])
    end
    [remote_row_to_issue(d) for d in rows]
end

function update_issue!(store::RemoteBoardStore, id::AbstractString; kwargs...)
    iss0 = get_issue(store, id)
    iss0 !== nothing && _remote_assert_project_writable!(store, iss0.project_id)
    move_status = nothing; move_pos = nothing
    fields = String[]; vals = Any[]; i = 1
    for (k, v) in kwargs
        k in _ISSUE_UPDATE_FIELDS || continue
        # C4: validate status/priority (matching sqlite) and route status/position
        # through move_issue! so positions stay dense — never a raw write.
        if k === :status
            valid_status(v) || throw(ArgumentError("invalid status: $v"))
            move_status = v; continue
        elseif k === :position
            move_pos = v; continue
        elseif k === :priority
            valid_priority(v) || throw(ArgumentError("invalid priority: $v"))
        end
        push!(fields, "$(k) = \$$(i)"); push!(vals, (v isa Date) ? string(v) : v); i += 1
    end
    if !isempty(fields)
        push!(vals, _dt_str(Dates.now(UTC))); push!(vals, id)
        store.exec("UPDATE issues SET $(join(fields, ", ")), updated = \$$(i) WHERE id = \$$(i+1)", vals)
    end
    if move_status !== nothing || move_pos !== nothing
        move_issue!(store, id; status = move_status, position = move_pos)
    end
    get_issue(store, id)
end

"Renumber a status's issues to 0..n-1 in current order (mirrors sqlite)."
function _remote_reindex_status!(store, status)
    rows = store.exec("SELECT id FROM issues WHERE status = \$1 ORDER BY position, key", Any[status])
    for (i, d) in enumerate(rows)
        store.exec("UPDATE issues SET position = \$1 WHERE id = \$2", Any[i - 1, String(_get(d, "id"))])
    end
end

function delete_issue!(store::RemoteBoardStore, id::AbstractString)::Bool
    iss = get_issue(store, id)
    iss === nothing && return false
    _remote_assert_project_writable!(store, iss.project_id)
    store.exec("DELETE FROM issue_labels WHERE issue_id = \$1", Any[id])
    store.exec("DELETE FROM issues WHERE id = \$1", Any[id])
    _remote_reindex_status!(store, iss.status)   # C3: keep positions dense after delete
    true
end

# C3: sibling-shift + reindex, mirroring sqlite_store.move_issue!'s dense contract.
function move_issue!(store::RemoteBoardStore, id::AbstractString;
                     status::Union{AbstractString,Nothing} = nothing,
                     position::Union{Integer,Nothing} = nothing)
    iss = get_issue(store, id)
    iss === nothing && return nothing
    _remote_assert_project_writable!(store, iss.project_id)
    old_status = iss.status
    new_status = status === nothing ? old_status : String(status)
    valid_status(new_status) || throw(ArgumentError("invalid status: $new_status"))
    sib = String[String(_get(d, "id")) for d in
                 store.exec("SELECT id FROM issues WHERE status = \$1 AND id != \$2 ORDER BY position, key",
                            Any[new_status, id])]
    pos = position === nothing ? length(sib) : clamp(Int(position), 0, length(sib))
    order = copy(sib)
    insert!(order, pos + 1, id)
    for (i, iid) in enumerate(order)
        store.exec("UPDATE issues SET status = \$1, position = \$2, updated = \$3 WHERE id = \$4",
                   Any[new_status, i - 1, _dt_str(Dates.now(UTC)), iid])
    end
    new_status == old_status || _remote_reindex_status!(store, old_status)
    get_issue(store, id)
end

rank_issue!(store::RemoteBoardStore, id::AbstractString; position::Integer) =
    move_issue!(store, id; position = position)

# ── Epics ─────────────────────────────────────────────────────────────────
# `key=` override is FakeExec/test-only (see create_issue! note above).
function create_epic!(store::RemoteBoardStore; name::AbstractString, color::AbstractString = "violet",
                      key::Union{AbstractString,Nothing} = nothing,
                      project_id::Union{AbstractString,Nothing} = nothing)::Epic
    pid, pkey = _remote_resolve_project_id(store, project_id)
    id = new_id(); created = Dates.now(UTC)
    k = key === nothing ? _remote_generate_epic_key(store, pkey) : String(key)
    store.exec("INSERT INTO epics (id, key, name, color, created, project_id) VALUES ($(pg_placeholders(6)))",
               Any[id, k, name, color, _dt_str(created), pid])
    Epic(; id = id, key = k, name = name, color = color, created = created, project_id = pid)
end
function get_epic(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM epics WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_epic(rows[1])
end
function list_epics(store::RemoteBoardStore;
                    project_id::Union{AbstractString,Nothing} = nothing)::Vector{Epic}
    project_id = _norm_project_filter(project_id)
    rows = project_id === nothing ?
        store.exec("SELECT * FROM epics ORDER BY key", Any[]) :
        store.exec("SELECT * FROM epics WHERE project_id = \$1 ORDER BY key", Any[project_id])
    [remote_row_to_epic(d) for d in rows]
end
function update_epic!(store::RemoteBoardStore, id::AbstractString; name = nothing, color = nothing)
    ep = get_epic(store, id)
    ep === nothing && return nothing
    fields = String[]; vals = Any[]; i = 1
    name === nothing || (push!(fields, "name = \$$(i)"); push!(vals, name); i += 1)
    color === nothing || (push!(fields, "color = \$$(i)"); push!(vals, color); i += 1)
    isempty(fields) && return ep
    _remote_assert_project_writable!(store, ep.project_id)
    push!(vals, id)
    store.exec("UPDATE epics SET $(join(fields, ", ")) WHERE id = \$$(i)", vals)
    get_epic(store, id)
end
function delete_epic!(store::RemoteBoardStore, id::AbstractString)::Bool
    ep = get_epic(store, id)
    ep === nothing && return false
    _remote_assert_project_writable!(store, ep.project_id)
    store.exec("DELETE FROM epics WHERE id = \$1", Any[id]); true
end

# ── Sprints ─────────────────────────────────────────────────────────────────
function create_sprint!(store::RemoteBoardStore; name::AbstractString, goal::AbstractString = "",
                        start_date::Union{Date,Nothing} = nothing,
                        end_date::Union{Date,Nothing} = nothing,
                        project_id::Union{AbstractString,Nothing} = nothing)::Sprint
    pid, _ = _remote_resolve_project_id(store, project_id)
    id = new_id()
    store.exec("INSERT INTO sprints (id, name, goal, start_date, end_date, state, project_id) VALUES ($(pg_placeholders(7)))",
               Any[id, name, goal, _date_str(start_date), _date_str(end_date), "future", pid])
    Sprint(; id = id, name = name, goal = goal, start_date = start_date, end_date = end_date,
           state = :future, project_id = pid)
end
function get_sprint(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM sprints WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_sprint(rows[1])
end
function list_sprints(store::RemoteBoardStore;
                      project_id::Union{AbstractString,Nothing} = nothing)::Vector{Sprint}
    project_id = _norm_project_filter(project_id)
    rows = project_id === nothing ?
        store.exec("SELECT * FROM sprints ORDER BY name", Any[]) :
        store.exec("SELECT * FROM sprints WHERE project_id = \$1 ORDER BY name", Any[project_id])
    [remote_row_to_sprint(d) for d in rows]
end
function update_sprint!(store::RemoteBoardStore, id::AbstractString;
                        name = nothing, goal = nothing, start_date = nothing, end_date = nothing)
    sp = get_sprint(store, id)
    sp === nothing && return nothing
    fields = String[]; vals = Any[]; i = 1
    name === nothing || (push!(fields, "name = \$$(i)"); push!(vals, name); i += 1)
    goal === nothing || (push!(fields, "goal = \$$(i)"); push!(vals, goal); i += 1)
    start_date === nothing || (push!(fields, "start_date = \$$(i)"); push!(vals, string(start_date)); i += 1)
    end_date === nothing || (push!(fields, "end_date = \$$(i)"); push!(vals, string(end_date)); i += 1)
    isempty(fields) && return sp
    _remote_assert_project_writable!(store, sp.project_id)
    push!(vals, id)
    store.exec("UPDATE sprints SET $(join(fields, ", ")) WHERE id = \$$(i)", vals)
    get_sprint(store, id)
end
function active_sprint(store::RemoteBoardStore;
                       project_id::Union{AbstractString,Nothing} = nothing)
    # PR-M1: optional project_id filter; without kw stays global (compat).
    project_id = _norm_project_filter(project_id)
    rows = project_id === nothing ?
        store.exec("SELECT * FROM sprints WHERE state = 'active' ORDER BY name, id LIMIT 1", Any[]) :
        store.exec("SELECT * FROM sprints WHERE state = 'active' AND project_id = \$1 ORDER BY name, id LIMIT 1",
                   Any[project_id])
    isempty(rows) && return nothing
    remote_row_to_sprint(rows[1])
end
function start_sprint!(store::RemoteBoardStore, id::AbstractString)::Sprint
    s = get_sprint(store, id)
    s === nothing && throw(ArgumentError("no such sprint: $id"))
    _remote_assert_project_writable!(store, s.project_id)
    active_sprint(store) === nothing || throw(ArgumentError("another sprint is already active"))
    s2 = transition(s, :active)
    # C8: guard the write at the DB level so the single-active invariant holds.
    store.exec("UPDATE sprints SET state = \$1 WHERE id = \$2 AND state = 'future'", Any["active", id])
    s2
end
function close_sprint!(store::RemoteBoardStore, id::AbstractString)::Sprint
    s = get_sprint(store, id)
    s === nothing && throw(ArgumentError("no such sprint: $id"))
    s2 = transition(s, :closed)
    store.exec("UPDATE sprints SET state = \$1 WHERE id = \$2 AND state = 'active'", Any["closed", id])
    s2
end

# ── Labels ─────────────────────────────────────────────────────────────────
function create_label!(store::RemoteBoardStore; name::AbstractString, color::AbstractString = "blue",
                       project_id::Union{AbstractString,Nothing} = nothing)::Label
    pid, _ = _remote_resolve_project_id(store, project_id)
    id = new_id()
    store.exec("INSERT INTO labels (id, name, color, project_id) VALUES ($(pg_placeholders(4)))",
               Any[id, name, color, pid])
    Label(; id = id, name = name, color = color, project_id = pid)
end
function list_labels(store::RemoteBoardStore;
                     project_id::Union{AbstractString,Nothing} = nothing)::Vector{Label}
    project_id = _norm_project_filter(project_id)
    rows = project_id === nothing ?
        store.exec("SELECT * FROM labels ORDER BY name", Any[]) :
        store.exec("SELECT * FROM labels WHERE project_id = \$1 ORDER BY name", Any[project_id])
    [remote_row_to_label(d) for d in rows]
end
function set_labels!(store::RemoteBoardStore, issue_id::AbstractString, label_ids::Vector{String})
    iss = get_issue(store, issue_id)
    iss !== nothing && _remote_assert_project_writable!(store, iss.project_id)
    store.exec("DELETE FROM issue_labels WHERE issue_id = \$1", Any[issue_id])
    for lid in label_ids
        store.exec("INSERT INTO issue_labels (issue_id, label_id) VALUES ($(pg_placeholders(2)))", Any[issue_id, lid])
    end
    label_ids
end
labels_for_issue(store::RemoteBoardStore, issue_id::AbstractString)::Vector{String} =
    String[String(_get(d, "label_id")) for d in
            store.exec("SELECT label_id FROM issue_labels WHERE issue_id = \$1 ORDER BY label_id", Any[issue_id])]

# ── Comments / activity ─────────────────────────────────────────────────────
function add_comment!(store::RemoteBoardStore; issue_id::AbstractString,
                      author_id::AbstractString, body::AbstractString)::Comment
    id = new_id(); created = Dates.now(UTC)
    store.exec("INSERT INTO comments (id, issue_id, author_id, body, created) VALUES ($(pg_placeholders(5)))",
               Any[id, issue_id, author_id, body, _dt_str(created)])
    Comment(; id = id, issue_id = issue_id, author_id = author_id, body = body, created = created)
end
list_comments(store::RemoteBoardStore, issue_id::AbstractString)::Vector{Comment} =
    [remote_row_to_comment(d) for d in
     store.exec("SELECT * FROM comments WHERE issue_id = \$1 ORDER BY created", Any[issue_id])]
function log_activity!(store::RemoteBoardStore; issue_id::AbstractString,
                       actor_id::Union{AbstractString,Nothing} = nothing,
                       kind::Symbol, detail::AbstractString = "")::ActivityEvent
    id = new_id(); created = Dates.now(UTC)
    store.exec("INSERT INTO activity (id, issue_id, actor_id, kind, detail, created) VALUES ($(pg_placeholders(6)))",
               Any[id, issue_id, actor_id, String(kind), detail, _dt_str(created)])
    ActivityEvent(; id = id, issue_id = issue_id, actor_id = actor_id, kind = kind, detail = detail, created = created)
end
list_activity(store::RemoteBoardStore, issue_id::AbstractString)::Vector{ActivityEvent} =
    [remote_row_to_activity(d) for d in
     store.exec("SELECT * FROM activity WHERE issue_id = \$1 ORDER BY created", Any[issue_id])]

# ── Sprint / backlog queries ────────────────────────────────────────────────
issues_for_sprint(store::RemoteBoardStore, sprint_id::AbstractString)::Vector{Issue} =
    [remote_row_to_issue(d) for d in
     store.exec("SELECT * FROM issues WHERE sprint_id = \$1 ORDER BY status, position, key", Any[sprint_id])]
function backlog_issues(store::RemoteBoardStore;
                        project_id::Union{AbstractString,Nothing} = nothing)::Vector{Issue}
    project_id = _norm_project_filter(project_id)
    rows = project_id === nothing ?
        store.exec("SELECT * FROM issues WHERE sprint_id IS NULL ORDER BY status, position, key", Any[]) :
        store.exec("SELECT * FROM issues WHERE sprint_id IS NULL AND project_id = \$1 ORDER BY status, position, key",
                   Any[project_id])
    [remote_row_to_issue(d) for d in rows]
end
# ── Outbox ─────────────────────────────────────────────────────────────────
function enqueue_outbox!(store::RemoteBoardStore; event_kind::Symbol, recipient_email::AbstractString,
                         subject::AbstractString, body::AbstractString)::String
    id = new_id()
    store.exec("INSERT INTO outbox (id, event_kind, recipient_email, subject, body, created, sent_at) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, NULL)",
               Any[id, String(event_kind), recipient_email, subject, body, _dt_str(Dates.now(UTC))])
    id
end
pending_outbox(store::RemoteBoardStore)::Vector{Dict{String,Any}} =
    [Dict{String,Any}("id" => String(_get(d, "id")), "event_kind" => String(_get(d, "event_kind")),
        "recipient_email" => String(_get(d, "recipient_email")), "subject" => String(_get(d, "subject")),
        "body" => String(_get(d, "body")), "created" => String(_get(d, "created")))
     for d in store.exec("SELECT * FROM outbox WHERE sent_at IS NULL ORDER BY created", Any[])]
function mark_sent!(store::RemoteBoardStore, id::AbstractString)::Bool
    store.exec("UPDATE outbox SET sent_at = \$1 WHERE id = \$2", Any[_dt_str(Dates.now(UTC)), id]); true
end

# ── LibPQ connection glue (thin, live-Postgres only) ────────────────────────
# COV_EXCL_START — requires a live Postgres connection; excluded from coverage.
function libpq_exec(conn, sql::AbstractString, params::AbstractVector)::Vector{Dict{String,Any}}
    result = isempty(params) ? LibPQ.execute(conn, String(sql)) :
                               LibPQ.execute(conn, String(sql), collect(params))
    cols = LibPQ.column_names(result)
    out = Dict{String,Any}[]
    for row in Tables.rows(result)
        d = Dict{String,Any}()
        for c in cols
            d[String(c)] = getproperty(row, Symbol(c))
        end
        push!(out, d)
    end
    out
end

function connect_remote(cfg::PostgresConfig)
    conn = LibPQ.Connection(pg_conninfo(cfg))
    (sql, params) -> libpq_exec(conn, sql, params)
end

RemoteUserStore(cfg::AppConfig) = RemoteUserStore(connect_remote(cfg.postgres))
RemoteBoardStore(cfg::AppConfig) = RemoteBoardStore(connect_remote(cfg.postgres))
# COV_EXCL_STOP
