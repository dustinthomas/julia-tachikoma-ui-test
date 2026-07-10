# ═══════════════════════════════════════════════════════════════════════
# store/interface.jl — AbstractUserStore + AbstractBoardStore contracts.
#
# Part of `module Stores` (declared in QciKanban.jl, which also `using`s
# ..Domain / ..Config). Generic-function declarations here; methods live in
# sqlite_store.jl (local) and remote_store.jl (Postgres/LibPQ).
# ═══════════════════════════════════════════════════════════════════════

using Dates
using UUIDs

export AbstractUserStore, AbstractBoardStore
# user store API
export create_user!, authenticate, get_user, list_users, deactivate_user!
export get_token_version, bump_token_version!
# board store API
export create_issue!, get_issue, update_issue!, delete_issue!, list_issues
export create_epic!, get_epic, list_epics, update_epic!, delete_epic!
export create_sprint!, get_sprint, list_sprints, update_sprint!,
       start_sprint!, close_sprint!, active_sprint
export create_label!, list_labels, set_labels!, labels_for_issue
export add_comment!, list_comments, log_activity!, list_activity
export rank_issue!, move_issue!, issues_for_sprint, backlog_issues
export enqueue_outbox!, pending_outbox, mark_sent!
export seed_demo!, seed_ops_template!
export create_project!, list_projects, get_project, archive_project!
export board_schema_version
export record_sprint_metrics!, list_sprint_metrics

abstract type AbstractUserStore end
abstract type AbstractBoardStore end

# ── User store contract ──────────────────────────────────────────────────
function create_user! end
function authenticate end
function get_user end
function list_users end
function deactivate_user! end
function get_token_version end     # session-epoch for a user (0 if missing)
function bump_token_version! end   # increment epoch → orphan outstanding tokens

# ── Board store contract ───────────────────────────────────────────────────
function create_issue! end
function get_issue end
function update_issue! end
function delete_issue! end
function list_issues end
function create_epic! end
function get_epic end
function list_epics end
function update_epic! end
function delete_epic! end
function create_sprint! end
function get_sprint end
function list_sprints end
function update_sprint! end
function start_sprint! end
function close_sprint! end
function active_sprint end
function create_label! end
function list_labels end
function set_labels! end
function labels_for_issue end
function add_comment! end
function list_comments end
function log_activity! end
function list_activity end
function rank_issue! end
function move_issue! end
function issues_for_sprint end
function backlog_issues end
function enqueue_outbox! end
function pending_outbox end
function mark_sent! end
function seed_demo! end
"""Ops labels only (PM/CM/Safety/Critical) for a project — no issues/sprints."""
function seed_ops_template! end
# Project APIs + optional `project_id` kwargs: SQLite (PR-M1) + Remote/FakeExec (PR-M1b).
function create_project! end
function list_projects end
function get_project end
function archive_project! end
function board_schema_version end
function record_sprint_metrics! end
function list_sprint_metrics end

# ── Shared helpers (pure) ─────────────────────────────────────────────────
new_id() = string(uuid4())

# S3: a fixed dummy hash used to perform constant work when a login targets an
# absent or inactive email, so the response time does not reveal whether the
# email exists (user-enumeration timing oracle). Computed once at module load.
const DUMMY_PASSWORD_HASH = hash_password("dummy-password-for-timing"; iterations = 100_000)

"Run a throwaway PBKDF2 verify to match the work of a real authentication."
_dummy_verify(password::AbstractString) = (verify_password(password, DUMMY_PASSWORD_HASH); nothing)

_dt_str(dt::DateTime) = string(dt)
_date_str(::Nothing) = nothing
_date_str(d::Date) = string(d)

"""
    _normalize_role(x) -> String

Map missing/blank/invalid stored roles to `\"supervisor\"` so a corrupted
users.role never throws from `User` construction on auth/restore/list.
Valid roles pass through. No promote-to-admin heuristic.
"""
function _normalize_role(x)::String
    s = if x === nothing || x === missing
        ""
    else
        strip(String(x))
    end
    isempty(s) && return "supervisor"
    valid_role(s) ? s : "supervisor"
end

parse_date(::Nothing) = nothing
parse_date(::Missing) = nothing
parse_date(d::Date) = d
function parse_date(s::AbstractString)
    isempty(s) && return nothing
    try
        return Date(first(split(s, 'T')))
    catch
        return nothing
    end
end

parse_dt(::Nothing) = Dates.now(UTC)
parse_dt(::Missing) = Dates.now(UTC)
parse_dt(d::DateTime) = d
function parse_dt(s::AbstractString)
    try
        return DateTime(s)
    catch
        try
            return DateTime(first(split(s, '.')))
        catch
            return Dates.now(UTC)
        end
    end
end

parse_points(::Nothing) = nothing
parse_points(::Missing) = nothing
parse_points(n::Integer) = Int(n)
parse_points(s::AbstractString) = isempty(s) ? nothing : parse(Int, s)

# `key LIKE 'PREFIX-%'` → next sequential number, base 100.
next_key_number(existing_max::Union{Nothing,Missing,Integer}) =
    (existing_max === nothing || existing_max === missing) ? 100 : Int(existing_max) + 1
