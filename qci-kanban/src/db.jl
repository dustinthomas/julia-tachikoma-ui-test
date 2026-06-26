# ═══════════════════════════════════════════════════════════════════════
# db.jl — SQLite persistence for QCI Kanban
#
# Tables:
#   users(id, name, created)
#   issues(id, key, title, description, status, priority, assignee_id, due_date, position, created, updated)
#
# All functions take a SQLite.DB (or path that is opened). Defensive.
# Seed demo data on first run if tables empty.
# ═══════════════════════════════════════════════════════════════════════

module DB

using SQLite
using DBInterface
using Tables
using Dates
using UUIDs

export open_db, init_schema!, seed_demo!, close_db
export list_users, create_user!, get_user
export list_issues, create_issue!, update_issue!, update_issue_status_and_position!
export get_issue, delete_issue!

const DEFAULT_DB_PATH = expanduser("~/.qci-kanban/kanban.db")

function open_db(path::AbstractString = DEFAULT_DB_PATH)::SQLite.DB
    dir = dirname(path)
    if !isempty(dir) && !isdir(dir)
        mkpath(dir)
    end
    db = SQLite.DB(path)
    init_schema!(db)
    db
end

function close_db(db::SQLite.DB)
    # SQLite handles close on GC, but explicit is nice
    try
        SQLite.close(db)
    catch
        # ignore
    end
end

function init_schema!(db::SQLite.DB)
    # users
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created TEXT NOT NULL
        )
    """)

    # issues (position is per-status ordering)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS issues (
            id TEXT PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            description TEXT,
            status TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'Medium',
            assignee_id TEXT,
            due_date TEXT,
            position INTEGER NOT NULL DEFAULT 0,
            created TEXT NOT NULL,
            updated TEXT NOT NULL,
            FOREIGN KEY (assignee_id) REFERENCES users(id)
        )
    """)

    # index for ordering
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_issues_status_pos ON issues(status, position)
    """)
end

# ── Users ───────────────────────────────────────────────────────────────

function list_users(db::SQLite.DB)::Vector{Dict{String,Any}}
    rows = DBInterface.execute(db, "SELECT id, name, created FROM users ORDER BY name") |> Tables.columntable
    out = Dict{String,Any}[]
    for i in 1:length(rows.id)
        push!(out, Dict("id" => rows.id[i], "name" => rows.name[i], "created" => rows.created[i]))
    end
    out
end

function create_user!(db::SQLite.DB, name::AbstractString)::String
    id = string(uuid4())
    now = string(Dates.now(UTC))
    DBInterface.execute(db, "INSERT INTO users (id, name, created) VALUES (?, ?, ?)", [id, name, now])
    id
end

function get_user(db::SQLite.DB, id::AbstractString)::Union{Dict{String,Any}, Nothing}
    stmt = DBInterface.prepare(db, "SELECT id, name, created FROM users WHERE id = ? LIMIT 1")
    rows = DBInterface.execute(stmt, [id]) |> Tables.columntable
    isempty(rows.id) && return nothing
    Dict("id" => rows.id[1], "name" => rows.name[1], "created" => rows.created[1])
end

# ── Issues ──────────────────────────────────────────────────────────────

function list_issues(db::SQLite.DB; status::Union{AbstractString,Nothing}=nothing)::Vector{Dict{String,Any}}
    if status === nothing
        sql = "SELECT * FROM issues ORDER BY status, position, key"
        rows = DBInterface.execute(db, sql) |> Tables.columntable
    else
        sql = "SELECT * FROM issues WHERE status = ? ORDER BY position, key"
        rows = DBInterface.execute(db, sql, [status]) |> Tables.columntable
    end

    out = Dict{String,Any}[]
    n = length(rows.id)
    for i in 1:n
        push!(out, Dict(
            "id" => rows.id[i],
            "key" => rows.key[i],
            "title" => rows.title[i],
            "description" => rows.description[i],
            "status" => rows.status[i],
            "priority" => rows.priority[i],
            "assignee_id" => rows.assignee_id[i],
            "due_date" => rows.due_date[i],
            "position" => rows.position[i],
            "created" => rows.created[i],
            "updated" => rows.updated[i],
        ))
    end
    out
end

function get_issue(db::SQLite.DB, id::AbstractString)::Union{Dict{String,Any}, Nothing}
    stmt = DBInterface.prepare(db, "SELECT * FROM issues WHERE id = ? LIMIT 1")
    rows = DBInterface.execute(stmt, [id]) |> Tables.columntable
    isempty(rows.id) && return nothing
    Dict(
        "id" => rows.id[1], "key" => rows.key[1], "title" => rows.title[1],
        "description" => rows.description[1], "status" => rows.status[1],
        "priority" => rows.priority[1], "assignee_id" => rows.assignee_id[1],
        "due_date" => rows.due_date[1], "position" => rows.position[1],
        "created" => rows.created[1], "updated" => rows.updated[1],
    )
end

function create_issue!(db::SQLite.DB;
                       title::AbstractString,
                       description::AbstractString = "",
                       status::AbstractString = "To Do",
                       priority::AbstractString = "Medium",
                       assignee_id::Union{AbstractString,Nothing} = nothing,
                       due_date::Union{AbstractString,Nothing} = nothing,
                       position::Int = 999)::String
    id = string(uuid4())
    key = generate_key(db)
    now = string(Dates.now(UTC))
    DBInterface.execute(db, """
        INSERT INTO issues (id, key, title, description, status, priority, assignee_id, due_date, position, created, updated)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [id, key, title, description, status, priority, assignee_id, due_date, position, now, now])
    id
end

function update_issue!(db::SQLite.DB, id::AbstractString; kwargs...)::Bool
    # Simple dynamic update for title/desc/priority/assignee/due etc.
    fields = String[]
    vals = Any[]
    for (k, v) in kwargs
        if k in (:title, :description, :priority, :assignee_id, :due_date, :status, :position)
            push!(fields, "$(k) = ?")
            push!(vals, v)
        end
    end
    isempty(fields) && return false
    push!(vals, string(Dates.now(UTC)))  # updated
    push!(vals, id)
    sql = "UPDATE issues SET $(join(fields, ", ")), updated = ? WHERE id = ?"
    DBInterface.execute(db, sql, vals)
    true
end

function update_issue_status_and_position!(db::SQLite.DB, id::AbstractString, new_status::AbstractString, new_position::Int)
    # Caller responsible for shifting siblings if needed. This just sets.
    now = string(Dates.now(UTC))
    DBInterface.execute(db, """
        UPDATE issues SET status = ?, position = ?, updated = ? WHERE id = ?
    """, [new_status, new_position, now, id])
end

function delete_issue!(db::SQLite.DB, id::AbstractString)::Bool
    DBInterface.execute(db, "DELETE FROM issues WHERE id = ?", [id])
    true
end

# ── Helpers ─────────────────────────────────────────────────────────────

function generate_key(db::SQLite.DB)::String
    # Find next QCI-XXX
    row = DBInterface.execute(db, "SELECT MAX(CAST(substr(key, 5) AS INTEGER)) as maxn FROM issues WHERE key LIKE 'QCI-%'") |> Tables.columntable
    maxn = isempty(row.maxn) ? nothing : row.maxn[1]
    n = (maxn === missing || maxn === nothing) ? 100 : Int(maxn) + 1
    "QCI-$(n)"
end

function seed_demo!(db::SQLite.DB)
    # Only seed if no users and no issues
    u = list_users(db)
    iss = list_issues(db)
    if !isempty(u) || !isempty(iss)
        return
    end

    # Users
    u1 = create_user!(db, "Alex Rivera")
    u2 = create_user!(db, "Sam Chen")
    u3 = create_user!(db, "You")

    today = Dates.today()
    tomorrow = string(today + Day(1))
    soon = string(today + Day(3))
    past = string(today - Day(2))

    # Issues — spread across columns with positions
    create_issue!(db; title="Set up project board", status="Backlog", priority="High", assignee_id=u1, due_date=soon, position=0)
    create_issue!(db; title="Design login screen", status="Backlog", priority="Medium", assignee_id=u2, due_date=tomorrow, position=1)

    create_issue!(db; title="Implement card model", status="To Do", priority="High", assignee_id=u1, due_date=tomorrow, position=0)
    create_issue!(db; title="Add QCI colors + logo", status="To Do", priority="Medium", assignee_id=u3, position=1)

    create_issue!(db; title="Board column rendering", status="In Progress", priority="High", assignee_id=u3, due_date=tomorrow, position=0)
    create_issue!(db; title="Keyboard nav between columns", status="In Progress", priority="Medium", assignee_id=u1, position=1)

    create_issue!(db; title="Calendar view + due marks", status="Review", priority="Medium", assignee_id=u2, due_date=soon, position=0)
    create_issue!(db; title="Basic issue detail modal", status="Review", priority="Low", position=1)

    create_issue!(db; title="Initial DB schema", status="Done", priority="High", assignee_id=u3, due_date=past, position=0)
    create_issue!(db; title="Scaffold QciKanban package", status="Done", priority="High", assignee_id=u3, due_date=past, position=1)
end

end # module DB
