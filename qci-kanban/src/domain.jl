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
# Project keys: 2–8 chars, start with letter, A–Z / 0–9 only (no hyphen).
const PROJECT_KEY_RE = r"^[A-Z][A-Z0-9]{1,7}$"

export User, Issue, Epic, Sprint, Label, Comment, ActivityEvent, NotificationEvent, Project
export SprintMetrics
export PRIORITIES, STATUSES, SPRINT_STATES, NOTIFICATION_KINDS, PROJECT_KEY_RE
export valid_email, valid_priority, valid_status, valid_sprint_state, valid_notification_kind
export valid_project_key
export can_transition, transition
export sum_units

# ── Validators ──────────────────────────────────────────────────────────
valid_email(s::AbstractString)::Bool = occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", s)
valid_priority(p::AbstractString)::Bool = p in PRIORITIES
valid_status(s::AbstractString)::Bool = s in STATUSES
valid_sprint_state(s::Symbol)::Bool = s in SPRINT_STATES
valid_notification_kind(k::Symbol)::Bool = k in NOTIFICATION_KINDS
valid_project_key(k::AbstractString)::Bool = occursin(PROJECT_KEY_RE, k)

# ── User ────────────────────────────────────────────────────────────────
struct User
    id::String
    email::String
    name::String
    active::Bool
    created::DateTime
    function User(id::AbstractString, email::AbstractString, name::AbstractString,
                  active::Bool, created::DateTime)
        valid_email(email) || throw(ArgumentError("invalid email: $email"))
        isempty(strip(name)) && throw(ArgumentError("user name must not be empty"))
        new(String(id), String(email), String(name), active, created)
    end
end
User(; id, email, name, active::Bool = true, created::DateTime = Dates.now(UTC)) =
    User(id, email, name, active, created)

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
    function Issue(id, key, title, description, status, priority, story_points,
                   epic_id, sprint_id, assignee_id, reporter_id, start_date,
                   due_date, position, labels, created, updated, project_id)
        isempty(strip(title)) && throw(ArgumentError("issue title must not be empty"))
        valid_status(status)  || throw(ArgumentError("invalid status: $status"))
        valid_priority(priority) || throw(ArgumentError("invalid priority: $priority"))
        (story_points === nothing || story_points >= 0) ||
            throw(ArgumentError("story_points must be >= 0"))
        new(String(id), String(key), String(title), String(description), String(status),
            String(priority), story_points,
            epic_id === nothing ? nothing : String(epic_id),
            sprint_id === nothing ? nothing : String(sprint_id),
            assignee_id === nothing ? nothing : String(assignee_id),
            reporter_id === nothing ? nothing : String(reporter_id),
            start_date, due_date, Int(position), Vector{String}(labels), created, updated,
            String(project_id))
    end
end
function Issue(; id, key, title, description = "", status = "Backlog", priority = "Medium",
               story_points = nothing, epic_id = nothing, sprint_id = nothing,
               assignee_id = nothing, reporter_id = nothing, start_date = nothing,
               due_date = nothing, position = 0, labels = String[],
               created::DateTime = Dates.now(UTC), updated::DateTime = Dates.now(UTC),
               project_id::AbstractString = "")
    Issue(id, key, title, description, status, priority, story_points, epic_id, sprint_id,
          assignee_id, reporter_id, start_date, due_date, position, labels, created, updated,
          project_id)
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
