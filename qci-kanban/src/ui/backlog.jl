# ═══════════════════════════════════════════════════════════════════════
# ui/backlog.jl — Phase 3 backlog view: backlog list + sprint sections,
# sprint lifecycle (create/start/close with rollback), move issue ↔ sprint.
# The board's active-sprint quick filter (:sprint) reads the same store state.
# No raw ColorRGB literals — color via Theming accessors.
# ═══════════════════════════════════════════════════════════════════════

using .Theming

"Sprints in display order: active first, then future, then closed; each by name."
function _sorted_sprints(m::AppModel)
    ss = Stores.list_sprints(m.boardstore; project_id = _scope(m))
    ord = Dict(:active => 1, :future => 2, :closed => 3)
    sort(ss; by = s -> (get(ord, s.state, 9), s.name))
end

"Flat list of selectable issues in the backlog view (sprint issues then loose backlog)."
function _backlog_selectable(m::AppModel)::Vector{Domain.Issue}
    out = Domain.Issue[]
    for s in _sorted_sprints(m)
        append!(out, Stores.issues_for_sprint(m.boardstore, s.id))
    end
    append!(out, Stores.backlog_issues(m.boardstore; project_id = _scope(m)))
    out
end

function _backlog_selected_issue(m::AppModel)
    items = _backlog_selectable(m)
    isempty(items) && return nothing
    items[clamp(m.backlog_sel, 1, length(items))]
end

function _backlog_nav!(m::AppModel, delta::Int)
    n = length(_backlog_selectable(m))
    n == 0 && return m
    m.backlog_sel = clamp(m.backlog_sel + delta, 1, n)
    m
end

"Target sprint an issue moves INTO: the active sprint, else the first future sprint."
function _target_sprint(m::AppModel)
    asp = Stores.active_sprint(m.boardstore; project_id = _scope(m))
    asp !== nothing && return asp
    fut = filter(s -> s.state === :future, Stores.list_sprints(m.boardstore; project_id = _scope(m)))
    isempty(fut) ? nothing : first(fut)
end

function _move_to_sprint!(m::AppModel)
    iss = _backlog_selected_issue(m); iss === nothing && return m
    s = _target_sprint(m)
    if s === nothing
        m.message = "No sprint to move into (create one with n)"; return m
    end
    Stores.update_issue!(m.boardstore, iss.id; sprint_id = s.id)
    Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                         kind = :sprint_changed, detail = "→ $(s.name)")
    m.message = "$(iss.key) → $(s.name)"
    m
end

function _move_to_backlog!(m::AppModel)
    iss = _backlog_selected_issue(m); iss === nothing && return m
    iss.sprint_id === nothing && (m.message = "$(iss.key) already in backlog"; return m)
    Stores.update_issue!(m.boardstore, iss.id; sprint_id = nothing)
    Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                         kind = :sprint_changed, detail = "→ backlog")
    m.message = "$(iss.key) → backlog"
    m
end

function _start_sprint!(m::AppModel)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :manage_sprint) || return m
    if Stores.active_sprint(m.boardstore; project_id = _scope(m)) !== nothing
        m.message = "A planning window is already active in this project"; return m
    end
    fut = filter(s -> s.state === :future, Stores.list_sprints(m.boardstore; project_id = _scope(m)))
    if isempty(fut)
        m.message = "No future sprint to start"; return m
    end
    s = Stores.start_sprint!(m.boardstore, first(fut).id)
    _set_message!(m, "Started $(s.name)")
    m
end

function _request_close_sprint!(m::AppModel)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :manage_sprint) || return m
    asp = Stores.active_sprint(m.boardstore; project_id = _scope(m))
    if asp === nothing
        m.message = "No active sprint to close"; return m
    end
    m.confirm_kind = :close_sprint; m.confirm_target = asp.id
    m.modal = :confirm; m.focus = FocusState()
    m
end

"""
Close a sprint: snapshot velocity metrics **before** incomplete (non-Done)
issues roll back to the backlog, then mark the sprint closed.

Metrics live in the app close path only — not inside `Stores.close_sprint!`.
"""
function _do_close_sprint!(m::AppModel, sprint_id)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :manage_sprint) || return m
    sprint_id === nothing && return m
    issues = Stores.issues_for_sprint(m.boardstore, sprint_id)
    done = filter(i -> i.status == "Done", issues)
    incomplete = filter(i -> i.status != "Done", issues)
    sp = Stores.get_sprint(m.boardstore, sprint_id)
    if sp !== nothing
        # Dual storage: always fill both unit sums and counts (unit_kind tags sums).
        Stores.record_sprint_metrics!(m.boardstore, Domain.SprintMetrics(;
            sprint_id = sprint_id,
            project_id = sp.project_id,
            planned_units = Domain.sum_units(issues),
            completed_units = Domain.sum_units(done),
            completed_count = length(done),
            incomplete_count = length(incomplete),
            unit_kind = :points,
            closed_at = Dates.now(UTC)))
    end
    for iss in incomplete
        Stores.update_issue!(m.boardstore, iss.id; sprint_id = nothing)
        Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                             kind = :sprint_changed, detail = "rolled back to backlog")
    end
    s = Stores.close_sprint!(m.boardstore, sprint_id)
    _set_message!(m, "Closed $(s.name)")
    m
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function render_backlog!(m::AppModel, buf::Buffer, area::Rect)
    (area.width < 20 || area.height < 5) && return
    # Reserve a bottom strip for burndown (active) or velocity (closed history).
    bd_h = area.height >= 9 ? 3 : 0
    list_area = Rect(area.x, area.y, area.width, area.height - bd_h)
    _render_backlog_list!(m, buf, list_area)
    bd_h > 0 && render_backlog_footer!(m, buf,
        Rect(area.x, area.y + area.height - bd_h, area.width, bd_h))
    return
end

function _render_backlog_list!(m::AppModel, buf::Buffer, area::Rect)
    items = _backlog_selectable(m)
    m.backlog_sel = clamp(m.backlog_sel, 1, max(1, length(items)))
    set_string!(buf, area.x, area.y,
                _short("BACKLOG & SPRINTS  (n new sprint, > to sprint, < to backlog, S start, X close)", area.width),
                Style(; fg = col_text_dim()))
    # Build the flat display-row list (section headers interleaved with issue
    # rows) so we can scroll the window to keep the selected issue on-screen —
    # otherwise a destructive op could target an off-screen selection (U5).
    rows = Tuple{Symbol,Any,Int}[]            # (:sprint|:backlog|:issue, payload, idx)
    idx = 0
    for s in _sorted_sprints(m)
        push!(rows, (:sprint, s, 0))
        for iss in Stores.issues_for_sprint(m.boardstore, s.id)
            idx += 1; push!(rows, (:issue, iss, idx))
        end
    end
    push!(rows, (:backlog, nothing, 0))
    for iss in Stores.backlog_issues(m.boardstore; project_id = _scope(m))
        idx += 1; push!(rows, (:issue, iss, idx))
    end

    body_y0 = area.y + 2
    maxy = area.y + area.height - 1
    capacity = max(1, maxy - body_y0 + 1)
    sel_row = findfirst(r -> r[1] === :issue && r[3] == m.backlog_sel, rows)
    start = (sel_row !== nothing && sel_row > capacity) ? (sel_row - capacity + 1) : 1

    y = body_y0
    for ri in start:length(rows)
        y > maxy && break
        kind, payload, ix = rows[ri]
        if kind === :sprint
            s = payload
            sissues = Stores.issues_for_sprint(m.boardstore, s.id)
            badge = s.state === :active ? "● ACTIVE" : s.state === :closed ? "✓ closed" : "○ future"
            set_string!(buf, area.x, y, _short("▬ $(s.name) [$(badge)] ($(length(sissues)))", area.width),
                        Style(; fg = s.state === :active ? col_primary_hi() : col_primary(), bold = true))
        elseif kind === :backlog
            set_string!(buf, area.x, y, "▬ Backlog", Style(; fg = col_primary(), bold = true))
        else
            _render_backlog_row!(m, buf, area, y, payload, ix)
        end
        y += 1
    end
end

function _render_backlog_row!(m::AppModel, buf::Buffer, area::Rect, y::Int, iss::Domain.Issue, idx::Int)
    sel = idx == m.backlog_sel
    marker = sel ? "▸ " : "  "
    line = "$(marker)$(iss.key)  [$(iss.status)]  $(iss.title)"
    st = sel ? sel_style() : Style(; fg = col_text())
    set_string!(buf, area.x + 2, y, _short(line, area.width - 3), st)
end
