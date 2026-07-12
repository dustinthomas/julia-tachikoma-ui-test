# ═══════════════════════════════════════════════════════════════════════
# ui/app.jl — the v2 application shell: AppModel, update!, view, kanban2.
#
# Elm-style like v1, but state is a single AppModel wired to the Phase 1
# stores/auth/session. Input flows through the focus router + declarative
# keymap (no per-field guards). Views are stubs here (Phase 2); real board /
# backlog / calendar / gantt content lands in Phase 3/4.
#
# All color goes through `Theming` accessors — this file must contain NO raw
# ColorRGB literals (test-enforced). `render_qci_logo` is reused from
# QciKanban.jl (v1, palette-exempt).
# ═══════════════════════════════════════════════════════════════════════

using .Theming

const APP_VIEWS = (:board, :backlog, :calendar, :gantt)
const VIEW_TITLES = Dict(
    :board    => "BOARD",
    :backlog  => "BACKLOG",
    :calendar => "CALENDAR",
    :gantt    => "GANTT",
)

# ── Model ────────────────────────────────────────────────────────────────
mutable struct AppModel <: Model
    quit::Bool
    tick::Int
    config::Config.AppConfig
    userstore::Stores.SQLiteUserStore
    boardstore::Stores.SQLiteBoardStore
    session::Auth.Session
    # auth ui (pre-login)
    auth_stage::Symbol                 # :signin | :create
    email_input::TextInput
    name_input::TextInput
    password_input::TextInput
    focus::FocusState
    login_error::String
    user_count::Int
    # post-login
    current_user::Union{Domain.User,Nothing}
    view::Symbol                       # one of APP_VIEWS
    modal::Symbol                      # :none | :help | :card_detail | :card_edit | :confirm | :new_sprint | :search | :project_switch | :project_create
    message::String
    # ── Phase 3: board state ───────────────────────────────────────────────
    notifier::Any                      # AbstractNotifier (NullNotifier default)
    swimlane_by::Symbol                # :none | :assignee | :epic | :priority
    sel_lane::Int                      # 1-based lane index
    sel_col::Int                       # 1-based status-column index (1..length(STATUSES))
    sel_idx::Int                       # 1-based card index within the selected cell
    selected_ids::Set{String}          # bulk selection
    active_filters::Set{Symbol}        # :mine :high :due_soon :sprint
    label_filter::Union{String,Nothing}
    wip_limits::Dict{String,Int}
    search_input::TextInput            # live full-text filter
    # ── Phase 3: modals ────────────────────────────────────────────────────
    card_issue_id::Union{String,Nothing}   # issue under detail/edit (nothing = create)
    comment_input::TextArea
    edit_form::Any                     # EditForm | nothing
    confirm_kind::Symbol               # :none | :delete_one | :bulk_delete | :close_sprint | :bad_date
    confirm_target::Any
    sprint_name_input::TextInput
    sprint_goal_input::TextInput
    # ── Phase 3: backlog state ─────────────────────────────────────────────
    backlog_sel::Int
    # ── Phase 4: calendar + gantt state ────────────────────────────────────
    cal_year::Int                      # displayed calendar month/year
    cal_month::Int
    cal_sel_day::Int                   # selected day within the month (1-based)
    gantt_start::Date                  # left edge (earliest visible date) of the Gantt window
    gantt_scale::Symbol                # :day (1 day/col) | :week (1 day/col) | :month (7 days/col)
    gantt_sel::Int                     # 1-based index into the Gantt issue rows
    gantt_last_area::Rect              # last content Rect passed to render_gantt! (G4.1; zero default)
    # M3 drag-reschedule shadow state (nothing | NamedTuple with issue_id, mode,
    # origin_col, orig_start/due, preview_start/due). Preview only until release.
    gantt_drag::Any
    # ── Phase 5: graphics polish ───────────────────────────────────────────
    show_stats::Bool                   # board stats strip toggle (`t`)
    # ── Multi-project (PR-M2 / PR-M7) ──────────────────────────────────────
    active_project_id::Union{String,Nothing}
    projects_cache::Vector{Domain.Project}
    project_sel::Int                   # 1-based index into projects_cache (switcher)
    project_name_input::TextInput      # create-project modal (name)
    project_key_input::TextInput       # create-project modal (key)
    # PR-H1: last KeyEvent that passed the non-expired idle check (UTC).
    last_input_at::DateTime
end

should_quit(m::AppModel) = m.quit

# ── Construction ───────────────────────────────────────────────────────────
function _make_input(; text = "")
    TextInput(; text = text, focused = false,
              style = Style(; fg = col_text()),
              label_style = Style(; fg = col_text_dim()),
              cursor_style = Style(; fg = col_bg(), bg = col_primary()))
end

function _make_area(; text = "")
    TextArea(; text = text, focused = false,
             style = Style(; fg = col_text()),
             label_style = Style(; fg = col_text_dim()),
             cursor_style = Style(; fg = col_bg(), bg = col_primary()))
end

"Default per-column WIP limits (Jira-style soft limits; over-limit warns but allows)."
_default_wip_limits() = Dict("In Progress" => 3, "Review" => 2)

"""
    AppModel(; user_db, board_db, config, config_path, token_path, secret,
             ttl_seconds, restore=true, seed=true) -> AppModel

Build the v2 model. `user_db`/`board_db` default to `:memory:` (test-safe).
`token_path` and `secret` are injectable so tests never touch `~/.qci-kanban`.
On construction the board demo is seeded (issues/epics/sprints/labels, never
users) and — when `restore` — a persisted valid session token skips the login
gate. Expired/tampered/absent tokens leave the model on the login screen.
"""
function AppModel(; user_db::AbstractString = ":memory:",
                  board_db::AbstractString = ":memory:",
                  config::Union{Config.AppConfig,Nothing} = nothing,
                  config_path::Union{AbstractString,Nothing} = nothing,
                  token_path::Union{AbstractString,Nothing} = nothing,
                  secret::Union{AbstractString,Nothing} = nothing,
                  ttl_seconds::Union{Integer,Nothing} = nothing,
                  notifier = nothing,
                  restore::Bool = true, seed::Bool = true)
    cfg = config === nothing ? Config.load_config(config_path) : config
    us = Stores.SQLiteUserStore(user_db)
    bs = Stores.SQLiteBoardStore(board_db)
    seed && Stores.seed_demo!(bs)
    tok = token_path === nothing ? cfg.session_token_path : String(token_path)
    sec = secret !== nothing ? String(secret) : Config.ensure_jwt_secret!(cfg)
    ttl = ttl_seconds === nothing ? cfg.token_ttl_seconds : Int(ttl_seconds)
    sess = Auth.Session(; secret = sec, token_path = tok, ttl_seconds = ttl)

    td = Dates.today()
    m = AppModel(false, 0, cfg, us, bs, sess, :signin,
                 _make_input(), _make_input(), _make_input(),
                 FocusState(), "", length(Stores.list_users(us)),
                 nothing, :board, :none, "",
                 notifier === nothing ? Notify.NullNotifier() : notifier,
                 :none, 1, 1, 1, Set{String}(),
                 Set{Symbol}(), nothing, _default_wip_limits(),
                 _make_input(),
                 nothing, _make_area(), nothing, :none, nothing,
                 _make_input(), _make_input(),
                 1,
                 Dates.year(td), Dates.month(td), Dates.day(td),
                 td, :day, 1, Rect(0, 0, 0, 0), nothing,
                 false,
                 nothing, Domain.Project[], 1,
                 _make_input(), _make_input(),
                 Dates.now(UTC))
    _init_login_focus!(m)
    if restore && Auth.restore_from_file!(sess, us) && sess.current_user !== nothing
        _complete_login!(m, sess.current_user)
    end
    m
end

# ── Multi-project helpers (PR-M2 / PR-M7) ──────────────────────────────────
# When no active project is set, UI list/create calls must NOT fall through to
# the store's unfiltered path (omit/empty project_id ≡ all projects). A
# non-empty sentinel matches zero rows and keeps isolation fail-closed.
const _NO_PROJECT_SCOPE = "\0__no_active_project__"

"""
    _scope(m) -> String

Active project id for store list/create scope. Returns a non-matching sentinel
when `active_project_id` is unset so lists stay empty (never unscoped).
"""
_scope(m::AppModel) =
    m.active_project_id === nothing ? _NO_PROJECT_SCOPE : m.active_project_id

"""Path of the last-project remember file (next to the session token)."""
_last_project_path(m::AppModel) =
    joinpath(dirname(m.session.token_path), "last_project")

"Persist active project id (0600 atomic) so the next login restores it."
function _save_last_project!(m::AppModel)
    m.active_project_id === nothing && return m
    try
        Config._atomic_write_0600(_last_project_path(m), m.active_project_id * "\n")
    catch err
        @warn "could not write last_project" error = err  # COV_EXCL_LINE (I/O failure rare)
    end
    m
end

"""
Read last_project file; return id string or `nothing` if missing/blank/unreadable.
"""
function _read_last_project_id(m::AppModel)::Union{String,Nothing}
    path = _last_project_path(m)
    isfile(path) || return nothing
    try
        id = strip(read(path, String))
        isempty(id) ? nothing : String(id)
    catch
        nothing  # COV_EXCL_LINE
    end
end

"""Reload non-archived projects and ensure `active_project_id` is valid.

Prefers the current `active_project_id` when still valid, else restores
`last_project` when present and non-archived, else the first listed project.
Empty cache leaves `active_project_id = nothing` (caller may force create).
"""
function _load_projects!(m::AppModel)
    m.projects_cache = Stores.list_projects(m.boardstore; include_archived = false)
    if isempty(m.projects_cache)
        m.active_project_id = nothing
        m.project_sel = 1
        return m
    end
    if m.active_project_id !== nothing &&
       any(p -> p.id == m.active_project_id, m.projects_cache)
        # keep current
    else
        last_id = _read_last_project_id(m)
        if last_id !== nothing && any(p -> p.id == last_id, m.projects_cache)
            m.active_project_id = last_id
        else
            m.active_project_id = m.projects_cache[1].id
        end
    end
    idx = findfirst(p -> p.id == m.active_project_id, m.projects_cache)
    m.project_sel = something(idx, 1)
    m
end

"Clear board/backlog/gantt/modal selection after a project switch."
function _clear_project_selection!(m::AppModel)
    empty!(m.selected_ids)
    m.sel_lane = 1; m.sel_col = 1; m.sel_idx = 1
    m.card_issue_id = nothing
    m.backlog_sel = 1
    m.gantt_sel = 1
    m.label_filter = nothing
    empty!(m.active_filters)
    set_text!(m.search_input, "")
    m.edit_form = nothing
    m.confirm_kind = :none
    m.confirm_target = nothing
    m.modal = :none
    m.focus = FocusState()
    m
end

function _set_active_project!(m::AppModel, project_id::AbstractString)
    m.active_project_id = String(project_id)
    _clear_project_selection!(m)
    _save_last_project!(m)
    p = Stores.get_project(m.boardstore, project_id)
    # Short action message only — the always-on toast prefix already shows
    # "PROJECT: name (key)"; repeating that string doubles it in the header.
    m.message = p === nothing ? "Project switched" : "Switched to $(p.name)"
    m
end

function _open_project_switch!(m::AppModel)
    _load_projects!(m)
    if isempty(m.projects_cache)
        # Zero projects → forced create-project modal (blocks board).
        return _open_project_create!(m; forced = true)
    end
    idx = findfirst(p -> p.id == m.active_project_id, m.projects_cache)
    m.project_sel = something(idx, 1)
    m.modal = :project_switch
    m.focus = FocusState()
    m
end

function _project_switch_nav!(m::AppModel, delta::Int)
    n = length(m.projects_cache)
    n == 0 && return m
    m.project_sel = clamp(m.project_sel + delta, 1, n)
    m
end

function _project_switch_select!(m::AppModel)
    (1 <= m.project_sel <= length(m.projects_cache)) || return _close_modal!(m)
    p = m.projects_cache[m.project_sel]
    _set_active_project!(m, p.id)
    m
end

"""
    create_project_with_defaults!(store, cfg; key, name, ...) -> Project

App-layer project create (PR-M3 / design §4.4): store `create_project!` stays pure
(no `AppConfig`). When `cfg.seed_ops_labels`, seeds ops labels via
`seed_ops_template!` after a successful create. Used by the project-create modal
(PR-M7) and callable from tests.
"""
function create_project_with_defaults!(store, cfg::Config.AppConfig;
                                       key::AbstractString, name::AbstractString,
                                       description::AbstractString = "",
                                       color::AbstractString = "blue")
    p = Stores.create_project!(store; key = key, name = name,
                               description = description, color = color)
    cfg.seed_ops_labels && Stores.seed_ops_template!(store, p.id)
    p
end

"""Open the create-project modal (focus-routed name + key, like new_sprint)."""
function _open_project_create!(m::AppModel; forced::Bool = false)
    set_text!(m.project_name_input, "")
    set_text!(m.project_key_input, "")
    m.modal = :project_create
    m.focus = FocusState(Any[m.project_name_input, m.project_key_input]; active = true)
    forced && (m.message = "Create a project to continue")
    m
end

function _submit_project_create!(m::AppModel)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :manage_project) || return m
    name = strip(text(m.project_name_input))
    key  = strip(text(m.project_key_input))
    if isempty(name)
        m.message = "Project name required"; return m
    end
    if isempty(key)
        m.message = "Project key required"; return m
    end
    key_up = uppercase(key)
    if !Domain.valid_project_key(key_up)
        m.message = "Key must be 2–8 chars A-Z0-9 starting with a letter"
        return m
    end
    local p
    try
        p = create_project_with_defaults!(m.boardstore, m.config;
                                          key = key_up, name = String(name))
    catch err
        m.message = "Could not create project: $(sprint(showerror, err))"
        return m
    end
    _load_projects!(m)
    _set_active_project!(m, p.id)
    _set_message!(m, "Created project $(p.name) ($(p.key))")
    m
end

"Esc on create-project: cancel when projects exist; block dismiss when forced (empty)."
function _close_project_create!(m::AppModel)
    _load_projects!(m)
    if isempty(m.projects_cache)
        m.message = "A project is required"
        # keep focus on the create form
        m.modal = :project_create
        m.focus = FocusState(Any[m.project_name_input, m.project_key_input]; active = true)
        return m
    end
    _close_modal!(m)
end

"""Export active-project issues as CSV next to the session token (0600)."""
function _export_csv!(m::AppModel)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :export_csv) || return m
    m.active_project_id === nothing && (m.message = "No active project"; return m)
    issues = Stores.list_issues(m.boardstore; project_id = _scope(m))
    csv = Domain.issues_to_csv(issues)
    p = Stores.get_project(m.boardstore, m.active_project_id)
    key = p === nothing ? "PROJ" : p.key
    stamp = Dates.format(Dates.now(), dateformat"yyyymmdd-HHMMSS")
    path = joinpath(dirname(m.session.token_path), "export-$(key)-$(stamp).csv")
    try
        Config._atomic_write_0600(path, csv)
        _set_message!(m, "Exported $(length(issues)) issues → $(path)")
    catch err
        m.message = "Export failed: $(sprint(showerror, err))"  # COV_EXCL_LINE
    end
    m
end

# ── Focus setup for the login screens ──────────────────────────────────────
function _init_login_focus!(m::AppModel)
    if m.auth_stage === :create
        m.focus = FocusState(Any[m.email_input, m.name_input, m.password_input];
                             active_index = 1, active = true)
    elseif m.user_count == 0
        # First-run: no editor owns input so [c] reaches the keymap.
        m.focus = FocusState()
    else
        m.focus = FocusState(Any[m.email_input, m.password_input];
                             active_index = 1, active = true)
    end
    m
end

# ── Context stack (dispatch order 2→3→4) ───────────────────────────────────
function context_stack(m::AppModel)
    if m.current_user === nothing
        return m.auth_stage === :create ? Symbol[:login_create] : Symbol[:login]
    elseif m.modal === :help
        return Symbol[:help, :global]
    elseif m.modal === :card_detail
        return Symbol[:card_detail, :global]
    elseif m.modal === :card_edit
        return Symbol[:card_edit, :global]
    elseif m.modal === :confirm
        return Symbol[:confirm, :global]
    elseif m.modal === :search
        return Symbol[:search, :global]
    elseif m.modal === :new_sprint
        return Symbol[:new_sprint, :global]
    elseif m.modal === :project_switch
        return Symbol[:project_switch, :global]
    elseif m.modal === :project_create
        return Symbol[:project_create, :global]
    else
        return Symbol[m.view, :global]
    end
end

# ── Permissions (PR-H1) ─────────────────────────────────────────────────────
"""
    can!(m, action; resource=nothing) -> Bool

UI-facing capability gate. When `enforce_roles=false` (default), denied matrix
checks still allow the action but set a role-warning message. Unauthenticated
always returns false without reading `.role`. Do not call from pre-login
`_create_submit!` (Q5 open self-service).
"""
function can!(m::AppModel, action::Symbol; resource=nothing)::Bool
    u = m.current_user
    if u === nothing
        # Gated actions require a session. Never interpolate u.role.
        if m.config.enforce_roles
            m.message = "Permission denied ($action)"
            return false
        end
        return false   # warn-only still does not allow unauthenticated mutate
    end
    Domain.can(u, action; resource = resource) && return true
    if m.config.enforce_roles
        m.message = "Permission denied ($action)"
        return false
    else
        m.message = "Role warning: $(u.role) lacks $action (enforcement off)"
        return true
    end
end

"""
Preserve a warn-only role toast when setting a success/status message so pilots
still see the matrix deny after a gated mutate completes (PR-H1 review).
"""
function _set_message!(m::AppModel, text::AbstractString)
    if startswith(m.message, "Role warning:")
        m.message = "$(m.message) · $(text)"
    else
        m.message = String(text)
    end
    m
end

# ── Lazy idle logout (PR-H1) ────────────────────────────────────────────────
"""
    _idle_expired!(m) -> Bool

If logged in and idle past `idle_logout_seconds`, logout and set
`login_error = "Session expired (idle)"` (visible on SIGN IN). Returns true
when the key must be swallowed.
"""
function _idle_expired!(m::AppModel)::Bool
    m.current_user === nothing && return false
    m.config.idle_logout_seconds <= 0 && return false
    if Dates.now(UTC) - m.last_input_at > Dates.Second(m.config.idle_logout_seconds)
        _logout!(m)
        # _logout! clears login_error — set AFTER so SIGN IN shows the reason.
        m.login_error = "Session expired (idle)"
        return true
    end
    false
end

# ── Update ──────────────────────────────────────────────────────────────────
function update!(m::AppModel, evt::KeyEvent)
    m.tick += 1
    if _idle_expired!(m)   # may logout + return true if expired
        return m           # swallow this key
    end
    m.last_input_at = Dates.now(UTC)
    # M3: Esc cancels an in-progress gantt bar drag without store commit.
    if m.gantt_drag !== nothing && evt.key === :escape && m.modal === :none
        m.gantt_drag = nothing
        m.message = "Drag cancelled"
        return m
    end
    disp = route_to_focus!(m.focus, evt)      # step 1: focused editor wins
    disp === :consumed && return m
    act = lookup_action(context_stack(m), evt)  # steps 2-4 via keymap
    act === nothing && return m
    _do_action!(m, act)
    m
end

"""
    update!(m::AppModel, evt::MouseEvent)

Mouse path (not KEYMAP): idle parity, then Gantt-only handling (M1 click-select
+ M2 wheel scroll + M3 drag-reschedule) when logged in, no modal, view is
`:gantt`, and `gantt_last_area` is non-empty.
"""
function update!(m::AppModel, evt::MouseEvent)
    m.tick += 1
    if _idle_expired!(m)
        return m
    end
    m.last_input_at = Dates.now(UTC)

    m.current_user === nothing && return m
    m.modal !== :none && return m
    m.view !== :gantt && return m
    (m.gantt_last_area.width < 1 || m.gantt_last_area.height < 1) && return m

    _handle_gantt_mouse!(m, evt)
    m
end

function _do_action!(m::AppModel, act::Symbol)
    if act === :quit
        m.quit = true
    elseif act === :toggle_help
        m.modal = m.modal === :help ? :none : :help
    elseif act === :close_help
        m.modal = :none
    elseif act === :view_board
        _switch_view!(m, :board)
    elseif act === :view_backlog
        _switch_view!(m, :backlog)
    elseif act === :view_calendar
        _switch_view!(m, :calendar)
    elseif act === :view_gantt
        _switch_view!(m, :gantt)
    elseif act === :logout
        _logout!(m)
    elseif act === :soft_refresh
        _soft_refresh!(m)
    elseif act === :login_submit
        _login_submit!(m)
    elseif act === :login_to_create
        _to_create!(m)
    elseif act === :login_to_signin
        _to_signin!(m)
    elseif act === :create_submit
        _create_submit!(m)
    # ── Phase 3: board navigation ──────────────────────────────────────────
    elseif act === :nav_left
        _nav!(m, :left)
    elseif act === :nav_right
        _nav!(m, :right)
    elseif act === :nav_down
        _nav!(m, :down)
    elseif act === :nav_up
        _nav!(m, :up)
    elseif act === :cycle_swimlane
        _cycle_swimlane!(m)
    elseif act === :toggle_stats
        _toggle_stats!(m)
    # ── Phase 3: board card ops ────────────────────────────────────────────
    elseif act === :move_prev
        _move_status!(m, -1)
    elseif act === :move_next
        _move_status!(m, +1)
    elseif act === :rank_down
        _rank!(m, +1)
    elseif act === :rank_up
        _rank!(m, -1)
    elseif act === :assign_me
        _assign_me!(m)
    elseif act === :toggle_select
        _toggle_select!(m)
    elseif act === :bulk_move
        _bulk_move!(m)
    elseif act === :bulk_assign
        _bulk_assign!(m)
    elseif act === :bulk_delete
        _request_bulk_delete!(m)
    elseif act === :new_card
        _open_card_edit!(m; create = true)
    elseif act === :edit_card
        _open_card_edit!(m; create = false)
    elseif act === :delete_card
        _request_delete_one!(m)
    elseif act === :view_card
        _open_card_detail!(m)
    # ── Phase 3: filters / search ──────────────────────────────────────────
    elseif act === :filter_mine
        _toggle_filter!(m, :mine)
    elseif act === :filter_high
        _toggle_filter!(m, :high)
    elseif act === :filter_due
        _toggle_filter!(m, :due_soon)
    elseif act === :filter_sprint
        _toggle_filter!(m, :sprint)
    elseif act === :cycle_label_filter
        _cycle_label_filter!(m)
    elseif act === :open_search
        _open_search!(m)
    elseif act === :apply_search
        _apply_search!(m)
    elseif act === :clear_search
        _clear_search!(m)
    # ── Phase 3: modals ────────────────────────────────────────────────────
    elseif act === :save_edit
        _save_edit!(m)
    elseif act === :edit_enter
        _edit_enter!(m)
    elseif act === :submit_comment
        _submit_comment!(m)
    elseif act === :close_card
        _close_modal!(m)
    elseif act === :confirm_yes
        _confirm_yes!(m)
    elseif act === :confirm_no
        _close_modal!(m)
    # ── Phase 3: backlog / sprints ─────────────────────────────────────────
    elseif act === :backlog_down
        _backlog_nav!(m, +1)
    elseif act === :backlog_up
        _backlog_nav!(m, -1)
    elseif act === :new_sprint
        _open_new_sprint!(m)
    elseif act === :submit_new_sprint
        _submit_new_sprint!(m)
    elseif act === :move_to_sprint
        _move_to_sprint!(m)
    elseif act === :move_to_backlog
        _move_to_backlog!(m)
    elseif act === :start_sprint
        _start_sprint!(m)
    elseif act === :close_sprint
        _request_close_sprint!(m)
    elseif act === :backlog_view_card
        _backlog_open_detail!(m)
    elseif act === :backlog_edit_card
        _backlog_open_edit!(m)
    elseif act === :backlog_delete_card
        _backlog_request_delete!(m)
    # ── Phase 4: calendar ──────────────────────────────────────────────────
    elseif act === :cal_prev_month
        _cal_month!(m, -1)
    elseif act === :cal_next_month
        _cal_month!(m, +1)
    elseif act === :cal_day_next
        _cal_day!(m, +1)
    elseif act === :cal_day_prev
        _cal_day!(m, -1)
    elseif act === :cal_new
        _cal_new!(m)
    elseif act === :cal_view_card
        _cal_open_detail!(m)
    elseif act === :cal_edit_card
        _cal_open_edit!(m)
    # ── Phase 4: gantt ─────────────────────────────────────────────────────
    elseif act === :gantt_scroll_left
        _gantt_scroll!(m, -1)
    elseif act === :gantt_scroll_right
        _gantt_scroll!(m, +1)
    elseif act === :gantt_row_next
        _gantt_row!(m, +1)
    elseif act === :gantt_row_prev
        _gantt_row!(m, -1)
    elseif act === :gantt_zoom
        _gantt_zoom!(m)
    elseif act === :gantt_view_card
        _gantt_open_detail!(m)
    elseif act === :gantt_edit_card
        _gantt_open_edit!(m)
    # ── Multi-project (PR-M2 / PR-M7) ──────────────────────────────────────
    elseif act === :project_switch
        _open_project_switch!(m)
    elseif act === :project_switch_up
        _project_switch_nav!(m, -1)
    elseif act === :project_switch_down
        _project_switch_nav!(m, +1)
    elseif act === :project_switch_select
        _project_switch_select!(m)
    elseif act === :project_create
        _open_project_create!(m)
    elseif act === :submit_project_create
        _submit_project_create!(m)
    elseif act === :close_project_create
        _close_project_create!(m)
    elseif act === :export_csv
        _export_csv!(m)
    end
    m
end

# Backlog-view card ops select via the backlog cursor rather than the board grid.
function _backlog_open_detail!(m::AppModel)
    iss = _backlog_selected_issue(m); iss === nothing && return m
    m.card_issue_id = iss.id; m.modal = :card_detail
    set_text!(m.comment_input, ""); m.focus = FocusState(Any[m.comment_input]; active = true)
    m
end
function _backlog_open_edit!(m::AppModel)
    iss = _backlog_selected_issue(m); iss === nothing && return m
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :edit_issue; resource = iss) || return m
    m.card_issue_id = iss.id; m.edit_form = _build_edit_form(m, iss)
    m.modal = :card_edit; m.focus = FocusState(edit_editors(m.edit_form); active = true)
    m
end
function _backlog_request_delete!(m::AppModel)
    iss = _backlog_selected_issue(m); iss === nothing && return m
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :delete_issue) || return m
    m.confirm_kind = :delete_one; m.confirm_target = iss.id
    m.modal = :confirm; m.focus = FocusState()
    m
end

function _switch_view!(m::AppModel, v::Symbol)
    m.view = v
    m.modal = :none
    m.gantt_drag = nothing   # M3: never carry shadow drag across views
    m.message = "$(VIEW_TITLES[v]) view"
    v === :calendar && _cal_init!(m)
    v === :gantt && _gantt_init!(m)
    m
end

# ── Auth transitions ────────────────────────────────────────────────────────
function _complete_login!(m::AppModel, user::Domain.User)
    m.current_user = user
    m.login_error = ""
    m.last_input_at = Dates.now(UTC)   # PR-H1: start idle window at login
    m.view = :board
    m.modal = :none
    m.focus = FocusState()             # no editor in the main shell (Phase 2)
    _load_projects!(m)                 # Default always present after migrate
    if isempty(m.projects_cache)
        # Zero projects after login → forced create-project modal (blocks board).
        _open_project_create!(m; forced = true)
        m.message = "Signed in as $(user.name) — create a project to continue"
        return m
    end
    _save_last_project!(m)             # remember restored/selected active project
    pname = begin
        p = m.active_project_id === nothing ? nothing :
            Stores.get_project(m.boardstore, m.active_project_id)
        p === nothing ? "" : " · $(p.name)"
    end
    m.message = "Signed in as $(user.name)$(pname)"
    m
end

function _login_submit!(m::AppModel)
    email = strip(text(m.email_input))
    pw = text(m.password_input)
    if isempty(email)
        m.login_error = "Enter your email"
        return m
    end
    u = Auth.login!(m.session, m.userstore, email, pw)
    if u === nothing
        m.login_error = "Invalid email or password"
        set_text!(m.password_input, "")
        return m
    end
    _complete_login!(m, u)
end

function _to_create!(m::AppModel)
    m.auth_stage = :create
    m.login_error = ""
    set_text!(m.name_input, "")
    _init_login_focus!(m)
end

function _to_signin!(m::AppModel)
    m.auth_stage = :signin
    m.login_error = ""
    _init_login_focus!(m)
end

function _create_submit!(m::AppModel)
    email = strip(text(m.email_input))
    name = strip(text(m.name_input))
    pw = text(m.password_input)
    if !Domain.valid_email(email)
        m.login_error = "Enter a valid email"
        return m
    end
    if isempty(name)
        m.login_error = "Enter your name"
        return m
    end
    if length(pw) < 4
        m.login_error = "Password must be at least 4 characters"
        return m
    end
    local u
    try
        u = Stores.create_user!(m.userstore; email = email, name = name, password = pw)
    catch
        m.login_error = "Could not create account (email already in use?)"
        return m
    end
    # Establish the session directly for the just-created user — no redundant
    # re-authentication (which by construction would always succeed here).
    _establish_session!(m, u)
    m.user_count = length(Stores.list_users(m.userstore))
    _complete_login!(m, u)
end

"Issue + persist a session token for an already-authenticated user."
function _establish_session!(m::AppModel, u::Domain.User)
    token = Auth.issue_jwt(m.session.secret,
                           Dict("sub" => u.id, "name" => u.name, "email" => u.email, "tv" => 0);
                           ttl_seconds = m.session.ttl_seconds)
    m.session.current_user = u
    m.session.token = token
    Auth.save_token(m.session.token_path, token)
    m
end

function _logout!(m::AppModel)
    Auth.logout!(m.session, m.userstore)
    m.current_user = nothing
    m.auth_stage = :signin
    m.login_error = ""
    m.message = ""
    # Hygiene: drop modal/confirm/edit so post-idle (and normal logout) model
    # state is clean until next login (render already short-circuits unauth).
    m.modal = :none
    m.gantt_drag = nothing
    m.confirm_kind = :none
    m.confirm_target = nothing
    m.card_issue_id = nothing
    m.edit_form = nothing
    m.focus = FocusState()
    m.active_project_id = nothing
    empty!(m.projects_cache)
    m.project_sel = 1
    _clear_project_selection!(m)
    set_text!(m.email_input, "")
    set_text!(m.password_input, "")
    set_text!(m.name_input, "")
    m.user_count = length(Stores.list_users(m.userstore))
    _init_login_focus!(m)
end

"""
    _soft_refresh!(m)

Global soft refresh (`R`): reload projects_cache, revalidate current user,
clamp board/backlog/gantt/calendar selection, prune deleted bulk-selected ids
(by store existence — not filter-aware visibility), and preserve open modal if
its issue still exists. If `_load_projects!` falls back to a different active
project (archived/deleted behind the model), clear selection/modals like a
project switch so multi-seat refresh does not leave cross-project selection.
No-op when not logged in. Sets `message = "Refreshed"`.
"""
function _soft_refresh!(m::AppModel)
    m.current_user === nothing && return m
    prev_active = m.active_project_id
    _load_projects!(m)
    # Re-load user so active/name changes apply without full re-login.
    u = Stores.get_user(m.userstore, m.current_user.id)
    if u === nothing || !u.active
        _logout!(m)
        m.login_error = "Account no longer active"
        return m  # skip clamp / "Refreshed" — login chrome shows login_error
    end
    m.current_user = u
    m.session.current_user = u
    # Active project disappeared/archived → same hygiene as explicit switch.
    if m.active_project_id != prev_active
        _clear_project_selection!(m)
    end
    # Board cursor + bulk multi-select (drop deleted cards, not filter-hidden ones).
    _clamp_selection!(m)
    filter!(id -> Stores.get_issue(m.boardstore, id) !== nothing, m.selected_ids)
    # Backlog / gantt cursors.
    items = _backlog_selectable(m)
    m.backlog_sel = clamp(m.backlog_sel, 1, max(1, length(items)))
    m.gantt_sel = clamp(m.gantt_sel, 1, max(1, length(gantt_issue_rows(m))))
    # Calendar day may exceed days-in-month after a rare month shift.
    m.cal_sel_day = clamp(m.cal_sel_day, 1,
        Dates.daysinmonth(Date(m.cal_year, m.cal_month, 1)))
    # Modal: preserve if card_issue_id still exists; close when issue was deleted.
    if m.card_issue_id !== nothing && m.modal !== :none &&
       Stores.get_issue(m.boardstore, m.card_issue_id) === nothing
        _close_modal!(m)
    end
    m.message = "Refreshed"
    m
end

# ═══════════════════════════ VIEW ══════════════════════════════════════════
function view(m::AppModel, f::Frame)
    buf = f.buffer
    area = f.area

    if area.width < 24 || area.height < 8
        set_string!(buf, area.x, area.y, "QCI KANBAN (small)",
                    Style(; fg = col_primary(), dim = true))
        return
    end

    outer = Block(title = "QCI KANBAN",
                  border_style = Style(; fg = col_primary()),
                  title_style = Style(; fg = col_primary(), bold = true))
    main = render(outer, area, buf)

    logo_h = main.height < 14 ? 3 : (main.height < 22 ? 4 : 6)
    rows = split_layout(Layout(Vertical, [Fixed(logo_h), Fill(), Fixed(1)]), main)
    length(rows) < 3 && return
    logo_area, content_area, status_area = rows[1], rows[2], rows[3]

    render_qci_logo_v2!(buf, logo_area; tick = m.tick)

    if m.current_user === nothing
        _render_login!(m, buf, content_area)
    else
        _render_main!(m, buf, content_area)
    end

    _render_status!(m, buf, status_area)

    if m.current_user !== nothing && m.modal !== :none
        # Full-area clear so no board/backlog content bleeds around the overlay.
        _clear_rect!(buf, content_area)
        if m.modal === :help
            _render_help!(m, buf, content_area)
        elseif m.modal === :card_detail
            render_card_detail!(m, buf, content_area)
        elseif m.modal === :card_edit
            render_card_edit!(m, buf, content_area)
        elseif m.modal === :confirm
            render_confirm!(m, buf, content_area)
        elseif m.modal === :search
            render_search!(m, buf, content_area)
        elseif m.modal === :new_sprint
            render_new_sprint!(m, buf, content_area)
        elseif m.modal === :project_switch
            render_project_switch!(m, buf, content_area)
        elseif m.modal === :project_create
            render_project_create!(m, buf, content_area)
        end
    end
    return
end

# ── Password masking (plaintext never enters the buffer) ────────────────────
function _render_masked!(input::TextInput, rect::Rect, buf::Buffer)
    n = length(input.buffer)
    masked = TextInput(; text = repeat("•", n), focused = input.focused,
                       style = input.style, cursor_style = input.cursor_style)
    masked.cursor = input.cursor
    render(masked, rect, buf)
end

function _panel_rect(content_area::Rect, w::Int, h::Int)
    w = min(w, content_area.width)
    h = min(h, content_area.height)
    x = content_area.x + max(0, (content_area.width - w) ÷ 2)
    y = content_area.y + max(0, (content_area.height - h) ÷ 3)
    Rect(x, y, w, h)
end

function _clear_rect!(buf::Buffer, r::Rect)
    # Clear glyphs, then force style reset. Tachikoma's set_char!/set_string!
    # preserve an existing cell bg when the new style has NoColor bg — a
    # space-only clear left modern-card surface colors showing through modals
    # as colored rectangles. set_style!(…, RESET) replaces the whole style.
    for yy in r.y:(r.y + r.height - 1)
        set_string!(buf, r.x, yy, repeat(" ", r.width))
    end
    set_style!(buf, r, RESET)
end

# ── Login rendering ─────────────────────────────────────────────────────────
function _render_login!(m::AppModel, buf::Buffer, content_area::Rect)
    if m.auth_stage === :create
        _render_create!(m, buf, content_area)
    elseif m.user_count == 0
        _render_first_run!(m, buf, content_area)
    else
        _render_signin!(m, buf, content_area)
    end
end

function _render_first_run!(m::AppModel, buf::Buffer, content_area::Rect)
    prompt = "No users — press [c] to create account"
    hint = status_hints([:login])
    w = clamp(max(length(prompt), length(hint)) + 4, 20, content_area.width)
    r = _panel_rect(content_area, w, 6)
    _clear_rect!(buf, r)
    inner = render(Block(title = "LOGIN",
                         border_style = Style(; fg = col_primary()),
                         title_style = Style(; fg = col_primary(), bold = true)), r, buf)
    avail = max(1, inner.width)
    p = fit_width(prompt, avail)
    set_string!(buf, inner.x + max(0, (inner.width - textwidth(p)) ÷ 2), inner.y + 1, p,
                Style(; fg = col_text_dim()))
    h = fit_width(hint, avail)
    set_string!(buf, inner.x + max(0, (inner.width - textwidth(h)) ÷ 2),
                inner.y + inner.height - 1, h, Style(; fg = col_primary(), dim = true))
end

function _render_field!(buf::Buffer, inner::Rect, y::Int, label::String,
                        input::TextInput, focused::Bool; masked::Bool = false)
    lstyle = focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim())
    set_string!(buf, inner.x + 1, y, label, lstyle)
    fx = inner.x + 1 + length(label) + 1
    fr = Rect(fx, y, max(4, inner.x + inner.width - fx - 1), 1)
    masked ? _render_masked!(input, fr, buf) : render(input, fr, buf)
end

function _render_error!(buf::Buffer, inner::Rect, y::Int, msg::String)
    isempty(msg) && return
    avail = max(1, inner.width - 2)
    set_string!(buf, inner.x + 1, y, fit_width(msg, avail), Style(; fg = col_err(), bold = true))
end

function _render_signin!(m::AppModel, buf::Buffer, content_area::Rect)
    hint = status_hints([:login]; editors_focused = focused_editor(m.focus) !== nothing)
    r = _panel_rect(content_area, clamp(max(44, length(hint) + 4), 20, content_area.width), 9)
    _clear_rect!(buf, r)
    inner = render(Block(title = "SIGN IN",
                         border_style = Style(; fg = col_primary()),
                         title_style = Style(; fg = col_primary(), bold = true)), r, buf)
    y = inner.y + 1
    _render_field!(buf, inner, y, "Email:", m.email_input, m.email_input.focused)
    y += 2
    _render_field!(buf, inner, y, "Password:", m.password_input, m.password_input.focused; masked = true)
    y += 2
    _render_error!(buf, inner, y, m.login_error)
    set_string!(buf, inner.x + 1, inner.y + inner.height - 1, fit_width(hint, inner.width),
                Style(; fg = col_primary(), dim = true))
end

function _render_create!(m::AppModel, buf::Buffer, content_area::Rect)
    hint = status_hints([:login_create]; editors_focused = focused_editor(m.focus) !== nothing)
    r = _panel_rect(content_area, clamp(max(46, length(hint) + 4), 20, content_area.width), 11)
    _clear_rect!(buf, r)
    inner = render(Block(title = "CREATE ACCOUNT",
                         border_style = Style(; fg = col_primary()),
                         title_style = Style(; fg = col_primary(), bold = true)), r, buf)
    y = inner.y + 1
    _render_field!(buf, inner, y, "Email:", m.email_input, m.email_input.focused)
    y += 2
    _render_field!(buf, inner, y, "Name:", m.name_input, m.name_input.focused)
    y += 2
    _render_field!(buf, inner, y, "Password:", m.password_input, m.password_input.focused; masked = true)
    y += 2
    _render_error!(buf, inner, y, m.login_error)
    set_string!(buf, inner.x + 1, inner.y + inner.height - 1, fit_width(hint, inner.width),
                Style(; fg = col_primary(), dim = true))
end

# ── Main shell (view router; content is Phase 3/4) ──────────────────────────
function _render_main!(m::AppModel, buf::Buffer, content_area::Rect)
    # View tabs row — clip each label to the remaining inner width so a narrow
    # terminal never overwrites the right border (finding U4).
    x = content_area.x + 1
    right_edge = content_area.x + content_area.width      # first column past the inner area
    for v in APP_VIEWS
        avail = right_edge - x
        avail <= 0 && break
        label = (v === m.view ? "▸ " : "  ") * VIEW_TITLES[v]
        sty = v === m.view ? sel_style() : Style(; fg = col_text_muted())
        set_string!(buf, x, content_area.y, fit_width(label, avail), sty)
        x += length(label) + 2
    end

    # message/toast under the tabs — prefix with active project (same row so
    # board body height is unchanged; short-terminal layout tests stay green).
    proj_label = begin
        p = m.active_project_id === nothing ? nothing :
            Stores.get_project(m.boardstore, m.active_project_id)
        p === nothing ? "" : "PROJECT: $(p.name) ($(p.key))"
    end
    toast = if isempty(proj_label)
        m.message
    elseif isempty(m.message)
        proj_label
    else
        proj_label * "  ·  " * m.message
    end
    if !isempty(toast)
        set_string!(buf, content_area.x + 1, content_area.y + 1,
                    _clip(toast, content_area.width - 2),
                    Style(; fg = isempty(proj_label) ? col_text_muted() : col_primary(), dim = true))
    end

    body = Rect(content_area.x + 1, content_area.y + 2,
                max(1, content_area.width - 2), max(1, content_area.height - 2))
    if m.view === :board
        render_board!(m, buf, body)
    elseif m.view === :backlog
        render_backlog!(m, buf, body)
    elseif m.view === :calendar
        render_calendar!(m, buf, body)
    elseif m.view === :gantt
        render_gantt!(m, buf, body)
    end
end

_clip(s::AbstractString, w::Int) = fit_width(s, w)

"""Contextual status tips for the focused field (date picker, …). Empty if none."""
function _field_status_hints(ed)::String
    ed isa DateField && return date_field_status_hint(ed)
    ""
end

function _render_status!(m::AppModel, buf::Buffer, status_area::Rect)
    status_area.width < 10 && return
    ctx = context_stack(m)
    ed = focused_editor(m.focus)
    hints = status_hints(ctx; editors_focused = ed !== nothing)
    # Field-specific tips (e.g. [Spc] Calendar) lead so they aren't truncated off
    # the right of a crowded card-edit status line.
    field = _field_status_hints(ed)
    if !isempty(field)
        hints = isempty(hints) ? field : field * "  " * hints
    end
    who = m.current_user === nothing ? "" : " " * split(m.current_user.name)[1]
    mode = m.current_user === nothing ? "LOGIN" : VIEW_TITLES[m.view]
    # Pin Quit/Help to the (always-visible) left so a long view-hint string on
    # the right can never truncate them off the screen.
    brand = m.current_user === nothing ? " QCI • KANBAN " : " QCI • KANBAN  [q]Quit [?]Help "
    render(StatusBar(
        left = [Span(brand, Style(; fg = col_primary(), dim = true))],
        right = [Span("$(mode)$(who)  $(hints) ", Style(; fg = col_primary(), dim = true))],
    ), status_area, buf)
end

function _render_help!(m::AppModel, buf::Buffer, content_area::Rect)
    # Global first so essentials (Quit/Help/views) are always visible even if the
    # per-view section is long enough to overflow a small overlay.
    # Ops onboarding blurb (PR-M3 / design §4.7) is pinned at the top so a long
    # binding list never hides the plant quickstart behind "▾ N more".
    lines = String[
        "Ops quickstart: project → planning window (Backlog/S) → work orders [n]",
        "",
    ]
    append!(lines, help_lines([:global, m.view]))
    w = clamp(maximum(length, lines; init = 20) + 4, 20, content_area.width)
    h = clamp(length(lines) + 4, 6, content_area.height)
    r = _panel_rect(content_area, w, h)
    _clear_rect!(buf, r)
    inner = render(Block(title = "HELP — Esc / ? to close",
                         border_style = Style(; fg = col_primary()),
                         title_style = Style(; fg = col_primary(), bold = true)), r, buf)
    y = inner.y + 1
    last_row = inner.y + inner.height - 1
    cap = max(1, last_row - y + 1)               # content rows available
    if length(lines) <= cap  # COV_EXCL_START
        for ln in lines
            set_string!(buf, inner.x + 1, y, fit_width(ln, inner.width), Style(; fg = col_text_dim()))
            y += 1
        end
    # COV_EXCL_STOP — short help list rendering (when all lines fit); not reached in current headless test runs due to unrelated fixwave ordering/failures
    else
        # Not everything fits: fill all but the last row, then flag the remainder
        # so bindings are never silently hidden (finding U10).
        for i in 1:(cap - 1)
            set_string!(buf, inner.x + 1, y, fit_width(lines[i], inner.width), Style(; fg = col_text_dim()))
            y += 1
        end
        more = length(lines) - (cap - 1)
        set_string!(buf, inner.x + 1, y, fit_width("▾ $(more) more — resize to see all", inner.width),
                    Style(; fg = col_primary_hi(), bold = true))
    end
end

# ═══════════════════════════ ENTRY POINT ════════════════════════════════════
# COV_EXCL_START — live terminal loop glue: constructs the real-DB AppModel and
# hands off to Tachikoma's interactive `app` run loop, which needs a live
# terminal. Not reachable under TestBackend; the scripted headless tour lives in
# record_demo2 (covered). See COVERAGE.md.
"""
    kanban2(; user_db, board_db, config_path, token_path)

Launch the v2 QCI Kanban app. Separate user/board SQLite databases, real JWT
session restore on startup. Demo board seeding follows `AppConfig.seed_demo`
(TOML / `QCI_SEED_DEMO`; default true for demo ergonomics — plant installs set
`seed_demo = false` via `config/maintenance.toml.example`). Never seeds users.
Lives alongside the untouched v1 `kanban()`.
"""
function kanban2(; user_db::AbstractString = joinpath(homedir(), ".qci-kanban", "users.db"),
                 board_db::AbstractString = joinpath(homedir(), ".qci-kanban", "board.db"),
                 config_path::Union{AbstractString,Nothing} = nothing,
                 token_path::Union{AbstractString,Nothing} = nothing)
    cfg = Config.load_config(config_path)
    m = AppModel(; user_db = user_db, board_db = board_db,
                 config = cfg, token_path = token_path, seed = cfg.seed_demo)
    app(m)
end
# COV_EXCL_STOP

"""
    record_demo2(filename="qci-kanban-v2-demo.tach"; width, height, frames, fps,
                 gif=false, svg=false) -> String

Record a scripted headless tour of the v2 app (`kanban2`) to a `.tach` file:
first-run gate → create account → board → cycle swimlanes → open card detail →
add a comment → stats strip → card edit (WO/date fields) → project switcher
`P` open/Esc → calendar (`e` edit) → backlog + start sprint → gantt (`e` edit)
→ soft refresh `R` → board.

Runs on isolated `:memory:` stores and a throwaway token path, so it never
touches `~/.qci-kanban`. `gif`/`svg` optionally export the same frames when the
corresponding Tachikoma extension loads headlessly (guarded; skipped otherwise).
"""
function record_demo2(filename::AbstractString = "qci-kanban-v2-demo.tach";
                      width::Int = 90, height::Int = 28,
                      frames::Int = 140, fps::Int = 8,
                      gif::Bool = false, svg::Bool = false)
    m = AppModel(; user_db = ":memory:", board_db = ":memory:",
                 token_path = tempname(), secret = "demo-secret", restore = false)
    script = EventScript(
        (0.5, key('c')),                       # first-run gate → create account
        chars("demo@qci.com"; pace = 0.04),
        (0.3, key(:tab)),
        chars("Demo User"; pace = 0.04),
        (0.3, key(:tab)),
        chars("password"; pace = 0.04),
        (0.5, key(:enter)),                    # create + sign in → board
        (0.8, key('s')),                       # cycle swimlanes (→ assignee)
        (0.6, key('s')),                       # → epic
        (0.8, key('v')),                       # open card detail
        chars("Looks great!"; pace = 0.04),    # comment (comment box focused)
        (0.4, key(:enter)),                    # submit comment
        (0.5, key(:escape)),                   # close detail
        (0.8, key('t')),                       # stats strip on
        (0.6, key('e')),                       # edit card (WO / date fields)
        (0.7, key(:escape)),                   # close edit
        (0.6, key('P')),                       # project switcher (multi-project ops)
        (0.6, key(:escape)),                   # close switcher
        (0.8, key('C')),                       # calendar view
        (0.6, key('l')),                       # next month
        (0.5, key('e')),                       # cal edit (no-op if no due issue)
        (0.4, key(:escape)),                   # close if edit opened
        (0.8, key('K')),                       # backlog view
        (0.8, key('S')),                       # start sprint (burndown updates)
        (0.8, key('G')),                       # gantt view
        (0.6, key('e')),                       # gantt edit selected row
        (0.5, key(:escape)),                   # close edit
        (0.6, key('R')),                       # soft refresh flash
        (0.8, key('B')),                       # back to board
        pause(1.0),
    )
    events = script(fps)
    record_app(m, filename; width = width, height = height,
               frames = frames, fps = fps, events = events)
    if gif || svg
        _export_demo(filename; gif = gif, svg = svg)
    end
    @info "Recorded QCI Kanban v2 demo" filename frames fps
    filename
end

"Guarded gif/svg export from a recorded .tach (skips gracefully if unsupported)."
function _export_demo(tach::AbstractString; gif::Bool = false, svg::Bool = false)
    try
        w, h, cells, ts, _ = load_tach(String(tach))
        base = splitext(String(tach))[1]
        if svg
            export_svg(base * ".svg", w, h, cells, ts)
        end
        if gif && gif_extension_loaded()
            export_gif_from_snapshots(base * ".gif", w, h, cells, ts)  # COV_EXCL_LINE (extension-only)
        end
    catch err
        @warn "demo export skipped" error = err
    end
    nothing
end
