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

export User, Issue, Epic, Sprint, Comment, Label, ActivityEvent, NotificationEvent
export PRIORITIES, STATUSES, SPRINT_STATES, NOTIFICATION_KINDS
export valid_email, valid_priority, valid_status, valid_sprint_state, valid_notification_kind
export can_transition, transition

# ── Validators ──────────────────────────────────────────────────────────
valid_email(s::AbstractString)::Bool = occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", s)
valid_priority(p::AbstractString)::Bool = p in PRIORITIES
valid_status(s::AbstractString)::Bool = s in STATUSES
valid_sprint_state(s::Symbol)::Bool = s in SPRINT_STATES
valid_notification_kind(k::Symbol)::Bool = k in NOTIFICATION_KINDS

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
    function Issue(id, key, title, description, status, priority, story_points,
                   epic_id, sprint_id, assignee_id, reporter_id, start_date,
                   due_date, position, labels, created, updated)
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
            start_date, due_date, Int(position), Vector{String}(labels), created, updated)
    end
end
function Issue(; id, key, title, description = "", status = "Backlog", priority = "Medium",
               story_points = nothing, epic_id = nothing, sprint_id = nothing,
               assignee_id = nothing, reporter_id = nothing, start_date = nothing,
               due_date = nothing, position = 0, labels = String[],
               created::DateTime = Dates.now(UTC), updated::DateTime = Dates.now(UTC))
    Issue(id, key, title, description, status, priority, story_points, epic_id, sprint_id,
          assignee_id, reporter_id, start_date, due_date, position, labels, created, updated)
end

# ── Epic ────────────────────────────────────────────────────────────────
struct Epic
    id::String
    key::String
    name::String
    color::String
    created::DateTime
    function Epic(id, key, name, color, created)
        isempty(strip(name)) && throw(ArgumentError("epic name must not be empty"))
        new(String(id), String(key), String(name), String(color), created)
    end
end
Epic(; id, key, name, color = "violet", created::DateTime = Dates.now(UTC)) =
    Epic(id, key, name, color, created)

# ── Sprint ──────────────────────────────────────────────────────────────
struct Sprint
    id::String
    name::String
    goal::String
    start_date::Union{Date,Nothing}
    end_date::Union{Date,Nothing}
    state::Symbol
    function Sprint(id, name, goal, start_date, end_date, state)
        isempty(strip(name)) && throw(ArgumentError("sprint name must not be empty"))
        valid_sprint_state(state) || throw(ArgumentError("invalid sprint state: $state"))
        new(String(id), String(name), String(goal), start_date, end_date, state)
    end
end
Sprint(; id, name, goal = "", start_date = nothing, end_date = nothing, state::Symbol = :future) =
    Sprint(id, name, goal, start_date, end_date, state)

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
    Sprint(s.id, s.name, s.goal, s.start_date, s.end_date, to)
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
    function Label(id, name, color)
        isempty(strip(name)) && throw(ArgumentError("label name must not be empty"))
        new(String(id), String(name), String(color))
    end
end
Label(; id, name, color = "blue") = Label(id, name, color)

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
