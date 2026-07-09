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
       remote_row_to_activity
export pg_placeholders, pg_conninfo

# ── Store types (exec is injectable) ─────────────────────────────────────
struct RemoteUserStore <: AbstractUserStore
    exec::Any
end
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
          # PR-M1b will plumb project_id fully; default keeps FakeExec mappers green.
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
    last = cur === nothing ? max(99, existing_max === nothing ? 99 : Int(existing_max)) : Int(cur)
    n = last + 1
    store.exec("INSERT INTO key_seq (prefix, last) VALUES (\$1, \$2) ON CONFLICT(prefix) DO UPDATE SET last = \$3",
               Any[prefix, n, n])
    n
end
function _remote_generate_issue_key(store)::String
    rows = store.exec("SELECT MAX(CAST(substr(key, 5) AS INTEGER)) AS m FROM issues WHERE key LIKE 'QCI-%'", Any[])
    emax = isempty(rows) ? nothing : _get(rows[1], "m")
    "QCI-$(_remote_next_seq!(store, "QCI", emax))"
end
function _remote_generate_epic_key(store)::String
    rows = store.exec("SELECT MAX(CAST(substr(key, 6) AS INTEGER)) AS m FROM epics WHERE key LIKE 'EPIC-%'", Any[])
    emax = isempty(rows) ? nothing : _get(rows[1], "m")
    "EPIC-$(_remote_next_seq!(store, "EPIC", emax))"
end
_remote_status_count(store, status)::Int =
    let rows = store.exec("SELECT COUNT(*) AS c FROM issues WHERE status = \$1", Any[status])
        isempty(rows) ? 0 : Int(something(_get(rows[1], "c"), 0))
    end

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
                       position::Union{Integer,Nothing} = nothing)::Issue
    valid_status(status) || throw(ArgumentError("invalid status: $status"))
    valid_priority(priority) || throw(ArgumentError("invalid priority: $priority"))
    id = new_id(); now = Dates.now(UTC)
    # C2: MAX+1 sequential key (not random) and append-position (count in status).
    k = key === nothing ? _remote_generate_issue_key(store) : String(key)
    pos = position === nothing ? _remote_status_count(store, status) : Int(position)
    store.exec("INSERT INTO issues (id, key, title, description, status, priority, story_points, epic_id, sprint_id, assignee_id, reporter_id, start_date, due_date, position, created, updated) VALUES ($(pg_placeholders(16)))",
               Any[id, k, title, description, status, priority, story_points, epic_id, sprint_id,
                   assignee_id, reporter_id, _date_str(start_date), _date_str(due_date),
                   pos, _dt_str(now), _dt_str(now)])
    Issue(; id = id, key = k, title = title, description = description, status = status,
          priority = priority, story_points = story_points, epic_id = epic_id, sprint_id = sprint_id,
          assignee_id = assignee_id, reporter_id = reporter_id, start_date = start_date,
          due_date = due_date, position = pos, created = now, updated = now)
end

function get_issue(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM issues WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_issue(rows[1])
end

list_issues(store::RemoteBoardStore; status::Union{AbstractString,Nothing} = nothing)::Vector{Issue} =
    status === nothing ?
        [remote_row_to_issue(d) for d in store.exec("SELECT * FROM issues ORDER BY status, position, key", Any[])] :
        [remote_row_to_issue(d) for d in store.exec("SELECT * FROM issues WHERE status = \$1 ORDER BY position, key", Any[status])]

function update_issue!(store::RemoteBoardStore, id::AbstractString; kwargs...)
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
function create_epic!(store::RemoteBoardStore; name::AbstractString, color::AbstractString = "violet",
                      key::Union{AbstractString,Nothing} = nothing)::Epic
    id = new_id(); created = Dates.now(UTC); k = key === nothing ? _remote_generate_epic_key(store) : String(key)
    store.exec("INSERT INTO epics (id, key, name, color, created) VALUES ($(pg_placeholders(5)))",
               Any[id, k, name, color, _dt_str(created)])
    Epic(; id = id, key = k, name = name, color = color, created = created)
end
function get_epic(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM epics WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_epic(rows[1])
end
list_epics(store::RemoteBoardStore)::Vector{Epic} =
    [remote_row_to_epic(d) for d in store.exec("SELECT * FROM epics ORDER BY key", Any[])]
function update_epic!(store::RemoteBoardStore, id::AbstractString; name = nothing, color = nothing)
    fields = String[]; vals = Any[]; i = 1
    name === nothing || (push!(fields, "name = \$$(i)"); push!(vals, name); i += 1)
    color === nothing || (push!(fields, "color = \$$(i)"); push!(vals, color); i += 1)
    isempty(fields) && return get_epic(store, id)
    push!(vals, id)
    store.exec("UPDATE epics SET $(join(fields, ", ")) WHERE id = \$$(i)", vals)
    get_epic(store, id)
end
function delete_epic!(store::RemoteBoardStore, id::AbstractString)::Bool
    store.exec("DELETE FROM epics WHERE id = \$1", Any[id]); true
end

# ── Sprints ─────────────────────────────────────────────────────────────────
function create_sprint!(store::RemoteBoardStore; name::AbstractString, goal::AbstractString = "",
                        start_date::Union{Date,Nothing} = nothing,
                        end_date::Union{Date,Nothing} = nothing)::Sprint
    id = new_id()
    store.exec("INSERT INTO sprints (id, name, goal, start_date, end_date, state) VALUES ($(pg_placeholders(6)))",
               Any[id, name, goal, _date_str(start_date), _date_str(end_date), "future"])
    Sprint(; id = id, name = name, goal = goal, start_date = start_date, end_date = end_date, state = :future)
end
function get_sprint(store::RemoteBoardStore, id::AbstractString)
    rows = store.exec("SELECT * FROM sprints WHERE id = \$1 LIMIT 1", Any[id])
    isempty(rows) && return nothing
    remote_row_to_sprint(rows[1])
end
list_sprints(store::RemoteBoardStore)::Vector{Sprint} =
    [remote_row_to_sprint(d) for d in store.exec("SELECT * FROM sprints ORDER BY name", Any[])]
function update_sprint!(store::RemoteBoardStore, id::AbstractString;
                        name = nothing, goal = nothing, start_date = nothing, end_date = nothing)
    fields = String[]; vals = Any[]; i = 1
    name === nothing || (push!(fields, "name = \$$(i)"); push!(vals, name); i += 1)
    goal === nothing || (push!(fields, "goal = \$$(i)"); push!(vals, goal); i += 1)
    start_date === nothing || (push!(fields, "start_date = \$$(i)"); push!(vals, string(start_date)); i += 1)
    end_date === nothing || (push!(fields, "end_date = \$$(i)"); push!(vals, string(end_date)); i += 1)
    isempty(fields) && return get_sprint(store, id)
    push!(vals, id)
    store.exec("UPDATE sprints SET $(join(fields, ", ")) WHERE id = \$$(i)", vals)
    get_sprint(store, id)
end
function active_sprint(store::RemoteBoardStore)
    rows = store.exec("SELECT * FROM sprints WHERE state = 'active' ORDER BY name LIMIT 1", Any[])
    isempty(rows) && return nothing
    remote_row_to_sprint(rows[1])
end
function start_sprint!(store::RemoteBoardStore, id::AbstractString)::Sprint
    s = get_sprint(store, id)
    s === nothing && throw(ArgumentError("no such sprint: $id"))
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
function create_label!(store::RemoteBoardStore; name::AbstractString, color::AbstractString = "blue")::Label
    id = new_id()
    store.exec("INSERT INTO labels (id, name, color) VALUES ($(pg_placeholders(3)))", Any[id, name, color])
    Label(; id = id, name = name, color = color)
end
list_labels(store::RemoteBoardStore)::Vector{Label} =
    [remote_row_to_label(d) for d in store.exec("SELECT * FROM labels ORDER BY name", Any[])]
function set_labels!(store::RemoteBoardStore, issue_id::AbstractString, label_ids::Vector{String})
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
backlog_issues(store::RemoteBoardStore)::Vector{Issue} =
    [remote_row_to_issue(d) for d in
     store.exec("SELECT * FROM issues WHERE sprint_id IS NULL ORDER BY status, position, key", Any[])]

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
