# ═══════════════════════════════════════════════════════════════════════
# domain.jl — pure domain types + validators + sprint state machine.
#
# Wrapped by `module Domain` in QciKanban.jl. No I/O, no persistence — just
# value types and the invariants they must satisfy. Every struct validates
# in its inner constructor so an invalid domain object can never exist.
# ═══════════════════════════════════════════════════════════════════════

using Dates

# ── Vocabulary ──────────────────────────────────────────────────────────
const PRIORITIES = ("Low", "Medium", "High")
const STATUSES   = ("Backlog", "To Do", "In Progress", "Review", "Done")
const SPRINT_STATES = (:future, :active, :closed)
const NOTIFICATION_KINDS = (:assigned, :status_changed, :comment_added, :due_soon, :mentioned)
# Work-order types (manufacturing ops; nullable on Issue).
const WORK_TYPES = ("PM", "CM", "Improvement", "Safety", "Other")
# Issue dependency link kinds (G6 / Criterion 4). UI "blocked by" = reverse of "blocks".
const LINK_TYPES = ("blocks", "relates_to")
# Project keys: 2–8 chars, start with letter, A–Z / 0–9 only (no hyphen).
const PROJECT_KEY_RE = r"^[A-Z][A-Z0-9]{1,7}$"
# RBAC roles (PR-H1). Stored as TEXT on users.role; default "supervisor".
const USER_ROLES = ("admin", "supervisor", "technician", "viewer")

export User, Issue, Epic, Sprint, Label, Comment, ActivityEvent, NotificationEvent, Project
export SprintMetrics, IssueLink
export PRIORITIES, STATUSES, SPRINT_STATES, NOTIFICATION_KINDS, WORK_TYPES, PROJECT_KEY_RE
export LINK_TYPES, USER_ROLES, valid_role, can
export valid_email, valid_priority, valid_status, valid_sprint_state, valid_notification_kind
export valid_project_key, valid_work_type, valid_link_type
export can_transition, transition
export sum_units
export issues_to_csv
export would_blocks_cycle

# ── Validators ──────────────────────────────────────────────────────────
valid_email(s::AbstractString)::Bool = occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", s)
valid_priority(p::AbstractString)::Bool = p in PRIORITIES
valid_status(s::AbstractString)::Bool = s in STATUSES
valid_sprint_state(s::Symbol)::Bool = s in SPRINT_STATES
valid_notification_kind(k::Symbol)::Bool = k in NOTIFICATION_KINDS
valid_project_key(k::AbstractString)::Bool = occursin(PROJECT_KEY_RE, k)
valid_work_type(::Nothing)::Bool = true
valid_work_type(w::AbstractString)::Bool = w in WORK_TYPES
valid_role(r::AbstractString)::Bool = r in USER_ROLES
valid_link_type(k::AbstractString)::Bool = k in LINK_TYPES

# ── User ────────────────────────────────────────────────────────────────
struct User
    id::String
    email::String
    name::String
    active::Bool
    created::DateTime
    role::String   # one of USER_ROLES; keyword default "supervisor"
    function User(id::AbstractString, email::AbstractString, name::AbstractString,
                  active::Bool, created::DateTime, role::AbstractString)
        valid_email(email) || throw(ArgumentError("invalid email: $email"))
        isempty(strip(name)) && throw(ArgumentError("user name must not be empty"))
        valid_role(role) || throw(ArgumentError("invalid role: $role"))
        new(String(id), String(email), String(name), active, created, String(role))
    end
end
User(; id, email, name, active::Bool = true, created::DateTime = Dates.now(UTC),
     role::AbstractString = "supervisor") =
    User(id, email, name, active, created, role)

# ── Capability matrix (pure; no I/O) ────────────────────────────────────
"""
    can(user, action; resource=nothing) -> Bool

Closed-set RBAC check (PR-H1 / Q6). Unauthenticated (`user === nothing`) and
inactive users always false. Technician may create issues and edit only when
`resource` is an `Issue` with `assignee_id == user.id`. Enforcement (hard deny
vs warn-only) lives in UI `can!` via `config.enforce_roles`.
"""
function can(user::Union{User,Nothing}, action::Symbol; resource=nothing)::Bool
    user === nothing && return false
    user.active || return false
    r = user.role
    if action === :view_board
        return true
    elseif action === :create_issue
        return r in ("admin", "supervisor", "technician")
    elseif action === :edit_issue
        r in ("admin", "supervisor") && return true
        if r == "technician"
            resource isa Issue || return false
            return resource.assignee_id == user.id
        end
        return false
    elseif action === :delete_issue
        return r in ("admin", "supervisor")
    elseif action === :manage_sprint
        return r in ("admin", "supervisor")
    elseif action === :manage_project
        return r in ("admin", "supervisor")
    elseif action === :export_csv
        return r in ("admin", "supervisor", "technician")
    elseif action === :create_user || action === :manage_users
        # Matrix only (future post-login admin UI). Public create form is open (Q5)
        # and must NOT call can! / can on pre-login _create_submit!.
        return r == "admin"
    else
        return false
    end
end

# ── Project ─────────────────────────────────────────────────────────────
struct Project
    id::String
    key::String          # immutable after create; 2–8 A-Z0-9 starting with letter
    name::String
    description::String
    color::String
    archived::Bool
    created::DateTime
    function Project(id, key, name, description, color, archived, created)
        valid_project_key(key) || throw(ArgumentError("invalid project key: $key"))
        isempty(strip(name)) && throw(ArgumentError("project name must not be empty"))
        new(String(id), String(key), String(name), String(description),
            String(color), Bool(archived), created)
    end
end
Project(; id, key, name, description = "", color = "blue", archived::Bool = false,
        created::DateTime = Dates.now(UTC)) =
    Project(id, key, name, description, color, archived, created)

# ── Issue ───────────────────────────────────────────────────────────────
# Optional manufacturing work-order fields (PR-M6 / design §4.4):
# asset_tag, location, work_type — all nullable; work_type constrained to WORK_TYPES.
struct Issue
    id::String
    key::String
    title::String
    description::String
    status::String
    priority::String
    story_points::Union{Int,Nothing}
    epic_id::Union{String,Nothing}
    sprint_id::Union{String,Nothing}
    assignee_id::Union{String,Nothing}
    reporter_id::Union{String,Nothing}
    start_date::Union{Date,Nothing}
    due_date::Union{Date,Nothing}
    position::Int
    labels::Vector{String}
    created::DateTime
    updated::DateTime
    project_id::String   # required on store writes; "" allowed for pure test fixtures
    asset_tag::Union{String,Nothing}
    location::Union{String,Nothing}
    work_type::Union{String,Nothing}
    function Issue(id, key, title, description, status, priority, story_points,
                   epic_id, sprint_id, assignee_id, reporter_id, start_date,
                   due_date, position, labels, created, updated, project_id,
                   asset_tag, location, work_type)
        isempty(strip(title)) && throw(ArgumentError("issue title must not be empty"))
        valid_status(status)  || throw(ArgumentError("invalid status: $status"))
        valid_priority(priority) || throw(ArgumentError("invalid priority: $priority"))
        (story_points === nothing || story_points >= 0) ||
            throw(ArgumentError("story_points must be >= 0"))
        at = _opt_field(asset_tag)
        loc = _opt_field(location)
        wt = _opt_field(work_type)
        valid_work_type(wt) || throw(ArgumentError("invalid work_type: $work_type"))
        new(String(id), String(key), String(title), String(description), String(status),
            String(priority), story_points,
            epic_id === nothing ? nothing : String(epic_id),
            sprint_id === nothing ? nothing : String(sprint_id),
            assignee_id === nothing ? nothing : String(assignee_id),
            reporter_id === nothing ? nothing : String(reporter_id),
            start_date, due_date, Int(position), Vector{String}(labels), created, updated,
            String(project_id), at, loc, wt)
    end
end

"Normalize optional free-text fields: nothing / missing / blank → nothing."
_opt_field(::Nothing) = nothing
_opt_field(s::AbstractString) = (t = strip(String(s)); isempty(t) ? nothing : t)

function Issue(; id, key, title, description = "", status = "Backlog", priority = "Medium",
               story_points = nothing, epic_id = nothing, sprint_id = nothing,
               assignee_id = nothing, reporter_id = nothing, start_date = nothing,
               due_date = nothing, position = 0, labels = String[],
               created::DateTime = Dates.now(UTC), updated::DateTime = Dates.now(UTC),
               project_id::AbstractString = "",
               asset_tag = nothing, location = nothing, work_type = nothing)
    Issue(id, key, title, description, status, priority, story_points, epic_id, sprint_id,
          assignee_id, reporter_id, start_date, due_date, position, labels, created, updated,
          project_id, asset_tag, location, work_type)
end

# ── Epic ────────────────────────────────────────────────────────────────
struct Epic
    id::String
    key::String
    name::String
    color::String
    created::DateTime
    project_id::String
    function Epic(id, key, name, color, created, project_id)
        isempty(strip(name)) && throw(ArgumentError("epic name must not be empty"))
        new(String(id), String(key), String(name), String(color), created, String(project_id))
    end
end
Epic(; id, key, name, color = "violet", created::DateTime = Dates.now(UTC),
     project_id::AbstractString = "") =
    Epic(id, key, name, color, created, project_id)

# ── Sprint ──────────────────────────────────────────────────────────────
struct Sprint
    id::String
    name::String
    goal::String
    start_date::Union{Date,Nothing}
    end_date::Union{Date,Nothing}
    state::Symbol
    project_id::String
    function Sprint(id, name, goal, start_date, end_date, state, project_id)
        isempty(strip(name)) && throw(ArgumentError("sprint name must not be empty"))
        valid_sprint_state(state) || throw(ArgumentError("invalid sprint state: $state"))
        new(String(id), String(name), String(goal), start_date, end_date, state, String(project_id))
    end
end
Sprint(; id, name, goal = "", start_date = nothing, end_date = nothing,
       state::Symbol = :future, project_id::AbstractString = "") =
    Sprint(id, name, goal, start_date, end_date, state, project_id)

# ── SprintMetrics (velocity snapshot at planning-window close) ───────────
"""
Snapshot of capacity/throughput for a closed sprint (planning window).

Captured by the app close path **before** incomplete issues roll back to the
backlog. `unit_kind` tags the sum columns (`planned_units` / `completed_units`);
count columns are always filled. Velocity charts pick series by config unit,
not by filtering on `unit_kind`.
"""
struct SprintMetrics
    sprint_id::String
    project_id::String
    planned_units::Int       # sum story_points of all in-sprint issues at close
    completed_units::Int     # sum story_points of Done issues at close
    completed_count::Int     # count of Done issues at close
    incomplete_count::Int    # count of non-Done at close (before rollback)
    unit_kind::Symbol        # :points | :count (describes sum columns)
    closed_at::DateTime
    function SprintMetrics(sprint_id, project_id, planned_units, completed_units,
                           completed_count, incomplete_count, unit_kind, closed_at)
        planned_units >= 0 || throw(ArgumentError("planned_units must be >= 0"))
        completed_units >= 0 || throw(ArgumentError("completed_units must be >= 0"))
        completed_count >= 0 || throw(ArgumentError("completed_count must be >= 0"))
        incomplete_count >= 0 || throw(ArgumentError("incomplete_count must be >= 0"))
        unit_kind in (:points, :count) ||
            throw(ArgumentError("unit_kind must be :points or :count"))
        new(String(sprint_id), String(project_id), Int(planned_units), Int(completed_units),
            Int(completed_count), Int(incomplete_count), Symbol(unit_kind), closed_at)
    end
end
SprintMetrics(; sprint_id, project_id, planned_units::Int = 0, completed_units::Int = 0,
              completed_count::Int = 0, incomplete_count::Int = 0,
              unit_kind::Symbol = :points, closed_at::DateTime = Dates.now(UTC)) =
    SprintMetrics(sprint_id, project_id, planned_units, completed_units,
                  completed_count, incomplete_count, unit_kind, closed_at)

"""Sum of `story_points` over issues (missing → 0). Pure helper for velocity."""
sum_units(issues)::Int = sum(i -> something(i.story_points, 0), issues; init = 0)

# Sprint state machine: future → active → closed (no other transitions).
can_transition(from::Symbol, to::Symbol)::Bool =
    (from, to) === (:future, :active) || (from, to) === (:active, :closed)

"""
    transition(s::Sprint, to::Symbol) -> Sprint

Return a new Sprint moved to state `to`, or throw if the transition is illegal.
Single-active enforcement lives in the store, not here.
"""
function transition(s::Sprint, to::Symbol)::Sprint
    can_transition(s.state, to) ||
        throw(ArgumentError("illegal sprint transition: $(s.state) → $to"))
    Sprint(s.id, s.name, s.goal, s.start_date, s.end_date, to, s.project_id)
end

# ── Comment ─────────────────────────────────────────────────────────────
struct Comment
    id::String
    issue_id::String
    author_id::String
    body::String
    created::DateTime
    function Comment(id, issue_id, author_id, body, created)
        isempty(strip(body)) && throw(ArgumentError("comment body must not be empty"))
        new(String(id), String(issue_id), String(author_id), String(body), created)
    end
end
Comment(; id, issue_id, author_id, body, created::DateTime = Dates.now(UTC)) =
    Comment(id, issue_id, author_id, body, created)

# ── IssueLink (directed dependency edge; G6 / Criterion 4) ───────────────
# "blocks" means from_id blocks to_id (finish-to-start for Gantt).
# "relates_to" is undirected at the product level; stored as a directed edge
# with no inverse row. UI "blocked by" is reverse adjacency of blocks — not
# a stored kind.
struct IssueLink
    id::String
    from_id::String
    to_id::String
    kind::String
    created::DateTime
    function IssueLink(id, from_id, to_id, kind, created)
        valid_link_type(kind) || throw(ArgumentError("invalid link kind: $kind"))
        isempty(strip(String(from_id))) && throw(ArgumentError("from_id must not be empty"))
        isempty(strip(String(to_id))) && throw(ArgumentError("to_id must not be empty"))
        new(String(id), String(from_id), String(to_id), String(kind), created)
    end
end
IssueLink(; id, from_id, to_id, kind::AbstractString = "blocks",
          created::DateTime = Dates.now(UTC)) =
    IssueLink(id, from_id, to_id, kind, created)

"""
    would_blocks_cycle(edges, from_id, to_id) -> Bool

Pure cycle check for a directed `blocks` graph. `edges` is an iterable of
`(from, to)` pairs for existing blocks links. Returns true if adding
`from_id → to_id` would introduce a cycle (including self-loop).
Does not mutate `edges`.
"""
function would_blocks_cycle(edges, from_id::AbstractString, to_id::AbstractString)::Bool
    from_s = String(from_id)
    to_s = String(to_id)
    from_s == to_s && return true
    adj = Dict{String,Vector{String}}()
    for e in edges
        a = String(e[1]); b = String(e[2])
        push!(get!(adj, a, String[]), b)
    end
    # Walk successors of `to`; if we reach `from`, the new edge closes a cycle.
    visited = Set{String}()
    stack = String[to_s]
    while !isempty(stack)
        n = pop!(stack)
        n == from_s && return true
        n in visited && continue
        push!(visited, n)
        for m in get(adj, n, String[])
            push!(stack, m)
        end
    end
    false
end

# ── Label ───────────────────────────────────────────────────────────────
struct Label
    id::String
    name::String
    color::String
    project_id::String
    function Label(id, name, color, project_id)
        isempty(strip(name)) && throw(ArgumentError("label name must not be empty"))
        new(String(id), String(name), String(color), String(project_id))
    end
end
Label(; id, name, color = "blue", project_id::AbstractString = "") =
    Label(id, name, color, project_id)

# ── ActivityEvent (audit log entry) ──────────────────────────────────────
struct ActivityEvent
    id::String
    issue_id::String
    actor_id::Union{String,Nothing}
    kind::Symbol
    detail::String
    created::DateTime
    function ActivityEvent(id, issue_id, actor_id, kind, detail, created)
        new(String(id), String(issue_id),
            actor_id === nothing ? nothing : String(actor_id),
            Symbol(kind), String(detail), created)
    end
end
ActivityEvent(; id, issue_id, actor_id = nothing, kind::Symbol, detail = "",
              created::DateTime = Dates.now(UTC)) =
    ActivityEvent(id, issue_id, actor_id, kind, detail, created)

# ── NotificationEvent (drives the notifier / outbox) ─────────────────────
struct NotificationEvent
    kind::Symbol
    recipient_email::String
    actor_name::String
    issue_key::String
    issue_title::String
    detail::String
    function NotificationEvent(kind, recipient_email, actor_name, issue_key, issue_title, detail)
        valid_notification_kind(kind) ||
            throw(ArgumentError("invalid notification kind: $kind"))
        valid_email(recipient_email) ||
            throw(ArgumentError("invalid recipient email: $recipient_email"))
        new(Symbol(kind), String(recipient_email), String(actor_name),
            String(issue_key), String(issue_title), String(detail))
    end
end
NotificationEvent(; kind::Symbol, recipient_email, actor_name = "", issue_key = "",
                  issue_title = "", detail = "") =
    NotificationEvent(kind, recipient_email, actor_name, issue_key, issue_title, detail)

# ── CSV export (pure; PR-M7 / design §4.9) ────────────────────────────────
"RFC 4180-style field escape: quote when the value contains comma, quote, or newline."
function _csv_escape(s::AbstractString)::String
    t = String(s)
    if occursin(r"[,\"\r\n]", t)
        return "\"" * replace(t, "\"" => "\"\"") * "\""
    end
    t
end
_csv_cell(::Nothing) = ""
_csv_cell(x::Date) = string(x)
_csv_cell(x::DateTime) = string(x)
_csv_cell(x::AbstractVector) = _csv_escape(join(x, "|"))
_csv_cell(x) = _csv_escape(string(x))

const _CSV_ISSUE_HEADER = "key,title,status,priority,story_points,asset_tag,location,work_type," *
                          "assignee_id,reporter_id,start_date,due_date,sprint_id,epic_id," *
                          "labels,project_id,description"

"""
    issues_to_csv(issues) -> String

Pure CSV serialization of issues (RFC 4180). Header row + one row per issue.
Nullable fields become empty cells; labels are `|`-joined. No I/O.
"""
function issues_to_csv(issues)::String
    io = IOBuffer()
    println(io, _CSV_ISSUE_HEADER)
    for iss in issues
        cells = (
            iss.key, iss.title, iss.status, iss.priority, iss.story_points,
            iss.asset_tag, iss.location, iss.work_type,
            iss.assignee_id, iss.reporter_id, iss.start_date, iss.due_date,
            iss.sprint_id, iss.epic_id, iss.labels, iss.project_id, iss.description,
        )
        println(io, join(_csv_cell.(cells), ","))
    end
    String(take!(io))
end
