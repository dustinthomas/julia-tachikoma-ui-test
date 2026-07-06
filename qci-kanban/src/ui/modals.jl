# ═══════════════════════════════════════════════════════════════════════
# ui/modals.jl — Phase 3 overlays: card detail, create/edit form, delete
# confirm, search, new-sprint. Every text-entry surface is built as a
# FocusState over real widgets, so the router (not per-field guards) governs
# input; Tab cycles fields; digits type into every text field by construction.
# No raw ColorRGB literals — color via Theming accessors.
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates

# ── The card create/edit form (focus-routed fields) ────────────────────────
mutable struct EditForm
    title_input::TextInput
    desc_area::TextArea
    priority_sel::Selector
    points_input::TextInput
    epic_sel::Selector
    sprint_sel::Selector
    assignee_sel::Selector
    start_input::TextInput
    due_input::TextInput
    labels_ms::MultiSelect
end

edit_editors(f::EditForm) = Any[f.title_input, f.desc_area, f.priority_sel, f.points_input,
                                f.epic_sel, f.sprint_sel, f.assignee_sel, f.start_input,
                                f.due_input, f.labels_ms]

function _build_edit_form(m::AppModel, iss::Union{Domain.Issue,Nothing})
    epics = Stores.list_epics(m.boardstore)
    sprints = Stores.list_sprints(m.boardstore)
    users = Stores.list_users(m.userstore)
    labels = Stores.list_labels(m.boardstore)

    prio_opts = collect(Domain.PRIORITIES)
    prio_sel = iss === nothing ? 2 : something(findfirst(==(iss.priority), prio_opts), 2)

    epic_opts = ["(none)"; [e.name for e in epics]]
    epic_vals = Any[nothing; [e.id for e in epics]]
    epic_sel = iss === nothing || iss.epic_id === nothing ? 1 :
               something(findfirst(==(iss.epic_id), epic_vals), 1)

    sprint_opts = ["(none)"; [s.name for s in sprints]]
    sprint_vals = Any[nothing; [s.id for s in sprints]]
    sprint_sel = iss === nothing || iss.sprint_id === nothing ? 1 :
                 something(findfirst(==(iss.sprint_id), sprint_vals), 1)

    user_opts = ["(none)"; [u.name for u in users]]
    user_vals = Any[nothing; [u.id for u in users]]
    asg_sel = iss === nothing || iss.assignee_id === nothing ? 1 :
              something(findfirst(==(iss.assignee_id), user_vals), 1)

    label_opts = [l.name for l in labels]
    label_vals = [l.id for l in labels]
    label_checked = Bool[l.id in (iss === nothing ? String[] : iss.labels) for l in labels]

    EditForm(
        _make_input(; text = iss === nothing ? "" : iss.title),
        _make_area(; text = iss === nothing ? "" : iss.description),
        Selector("Priority:", prio_opts, Any[prio_opts...]; selected = prio_sel),
        _make_input(; text = iss === nothing || iss.story_points === nothing ? "" : string(iss.story_points)),
        Selector("Epic:", epic_opts, epic_vals; selected = epic_sel),
        Selector("Sprint:", sprint_opts, sprint_vals; selected = sprint_sel),
        Selector("Assignee:", user_opts, user_vals; selected = asg_sel),
        _make_input(; text = iss === nothing || iss.start_date === nothing ? "" : string(iss.start_date)),
        _make_input(; text = iss === nothing || iss.due_date === nothing ? "" : string(iss.due_date)),
        MultiSelect("Labels:", label_opts, label_vals; checked = label_checked),
    )
end

# ── Opening / closing modals (set focus + which issue) ──────────────────────
function _open_card_detail!(m::AppModel)
    iss = selected_issue(m); iss === nothing && return m
    m.card_issue_id = iss.id
    m.modal = :card_detail
    set_text!(m.comment_input, "")
    m.focus = FocusState(Any[m.comment_input]; active = true)
    m
end

function _open_card_edit!(m::AppModel; create::Bool = false, due_prefill = nothing)
    iss = create ? nothing : selected_issue(m)
    (!create && iss === nothing) && return m
    m.card_issue_id = create ? nothing : iss.id
    m.edit_form = _build_edit_form(m, iss)
    due_prefill === nothing || set_text!(m.edit_form.due_input, string(due_prefill))
    m.modal = :card_edit
    m.focus = FocusState(edit_editors(m.edit_form); active = true)
    m
end

"""
    _open_detail_issue!(m, iss)

Open the read-only card-detail modal for a specific issue (used by the
calendar/gantt Enter binding, where the target issue comes from that view's
own selection rather than the board grid). No-op when `iss === nothing`.
"""
function _open_detail_issue!(m::AppModel, iss)
    iss === nothing && return m
    m.card_issue_id = iss.id
    m.modal = :card_detail
    set_text!(m.comment_input, "")
    m.focus = FocusState(Any[m.comment_input]; active = true)
    m
end

"""
    _open_edit_issue!(m, iss)

Open the card-edit modal pre-populated from a specific issue (used by the
calendar/gantt 'e' binding, where the target comes from the view's own
selected issue rather than board selection). No-op when `iss === nothing`.
"""
function _open_edit_issue!(m::AppModel, iss)
    iss === nothing && return m
    m.card_issue_id = iss.id; m.edit_form = _build_edit_form(m, iss)
    m.modal = :card_edit; m.focus = FocusState(edit_editors(m.edit_form); active = true)
    m
end

function _close_modal!(m::AppModel)
    m.modal = :none
    m.card_issue_id = nothing
    m.edit_form = nothing
    m.confirm_kind = :none
    m.confirm_target = nothing
    m.focus = FocusState()
    m
end

# ── Save from the edit form ─────────────────────────────────────────────────
function _parse_points(s::AbstractString)
    t = strip(s)
    isempty(t) && return nothing
    v = tryparse(Int, t)
    (v === nothing || v < 0) ? nothing : v
end
"""
    _date_field(s) -> (:empty | :date | :invalid, Date | nothing)

Classify a date-input field. An empty field clears the date (`:empty`); a
well-formed date parses (`:date`); a non-empty but unparseable value is
`:invalid` — the caller must NOT persist it (that would silently erase the
stored date). See finding C6.
"""
function _date_field(s::AbstractString)
    t = strip(s)
    isempty(t) && return (:empty, nothing)
    d = Stores.parse_date(String(t))
    d === nothing ? (:invalid, nothing) : (:date, d)
end

"""
    _edit_enter!(m)

Enter in the card-edit modal: insert a newline when the multi-line Desc field
owns input (multi-line descriptions, U6), otherwise save. Ctrl+S always saves.
"""
function _edit_enter!(m::AppModel)
    f = m.edit_form
    if f !== nothing && focused_editor(m.focus) === f.desc_area
        handle_key!(f.desc_area, KeyEvent(:enter))
        return m
    end
    _save_edit!(m)
end

function _save_edit!(m::AppModel)
    f = m.edit_form
    f === nothing && return _close_modal!(m)
    title = strip(text(f.title_input))
    if isempty(title)
        m.message = "Title is required"; return m
    end
    # Dates: distinguish empty (clear) from malformed (keep old value, error out).
    start_kind, start_date = _date_field(text(f.start_input))
    due_kind, due_date = _date_field(text(f.due_input))
    if start_kind === :invalid || due_kind === :invalid
        bad = start_kind === :invalid ? "start" : "due"
        m.message = "Invalid $(bad) date (use YYYY-MM-DD) — not saved"
        return m
    end
    priority = String(sel_current_value(f.priority_sel))
    pts = _parse_points(text(f.points_input))
    epic_id = sel_current_value(f.epic_sel)
    sprint_id = sel_current_value(f.sprint_sel)
    assignee_id = sel_current_value(f.assignee_sel)
    label_ids = ms_selected_values(f.labels_ms)
    desc = text(f.desc_area)

    if m.card_issue_id === nothing
        iss = Stores.create_issue!(m.boardstore; title = String(title), description = desc,
                                   priority = priority, story_points = pts,
                                   epic_id = epic_id, sprint_id = sprint_id,
                                   assignee_id = assignee_id, start_date = start_date, due_date = due_date)
        Stores.set_labels!(m.boardstore, iss.id, label_ids)
        Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                             kind = :created, detail = "created $(iss.key)")
        assignee_id === nothing || _notify_issue!(m, iss, :assigned, assignee_id, "")
        m.message = "Created $(iss.key)"
    else
        prev = Stores.get_issue(m.boardstore, m.card_issue_id)
        Stores.update_issue!(m.boardstore, m.card_issue_id; title = String(title), description = desc,
                             priority = priority, story_points = pts, epic_id = epic_id,
                             sprint_id = sprint_id, assignee_id = assignee_id,
                             start_date = start_date, due_date = due_date)
        Stores.set_labels!(m.boardstore, m.card_issue_id, label_ids)
        iss = Stores.get_issue(m.boardstore, m.card_issue_id)
        Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                             kind = :updated, detail = "edited $(iss.key)")
        if assignee_id !== nothing && (prev === nothing || prev.assignee_id != assignee_id)
            _notify_issue!(m, iss, :assigned, assignee_id, "")
        end
        m.message = "Saved $(iss.key)"
    end
    _clamp_selection!(m)
    _close_modal!(m)
end

# ── Comments ────────────────────────────────────────────────────────────────
function _submit_comment!(m::AppModel)
    m.card_issue_id === nothing && return m
    body = strip(text(m.comment_input))
    if isempty(body) || m.current_user === nothing
        return m
    end
    Stores.add_comment!(m.boardstore; issue_id = m.card_issue_id, author_id = m.current_user.id, body = String(body))
    iss = Stores.get_issue(m.boardstore, m.card_issue_id)
    if iss !== nothing
        Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                             kind = :comment_added, detail = String(body))
        iss.assignee_id === nothing || iss.assignee_id == m.current_user.id ||
            _notify_issue!(m, iss, :comment_added, iss.assignee_id, String(body))
    end
    set_text!(m.comment_input, "")
    m.message = "Comment added"
    m
end

# ── Delete / confirm ────────────────────────────────────────────────────────
function _request_delete_one!(m::AppModel)
    iss = selected_issue(m); iss === nothing && return m
    m.confirm_kind = :delete_one; m.confirm_target = iss.id
    m.modal = :confirm; m.focus = FocusState()
    m
end
function _request_bulk_delete!(m::AppModel)
    isempty(m.selected_ids) && return m
    # Only currently-visible selected issues are deletable (finding C7): a card
    # hidden by a filter must never be destroyed from a stale selection.
    vis = _visible_ids(m)
    targets = [id for id in collect(m.selected_ids) if id in vis]
    isempty(targets) && (m.message = "No visible selected issues to delete"; return m)
    m.confirm_kind = :bulk_delete; m.confirm_target = targets
    m.modal = :confirm; m.focus = FocusState()
    m
end

function _confirm_yes!(m::AppModel)
    k = m.confirm_kind
    if k === :delete_one
        id = m.confirm_target
        if id !== nothing
            Stores.delete_issue!(m.boardstore, id)
            delete!(m.selected_ids, id)
            m.message = "Deleted issue"
        end
    elseif k === :bulk_delete
        n = 0
        for id in m.confirm_target
            Stores.delete_issue!(m.boardstore, id) && (n += 1)   # count only real deletes
        end
        empty!(m.selected_ids)
        m.message = "Deleted $(n) issues"
    elseif k === :close_sprint
        _do_close_sprint!(m, m.confirm_target)
    end
    _clamp_selection!(m)
    _close_modal!(m)
end

# ── Search ──────────────────────────────────────────────────────────────────
function _open_search!(m::AppModel)
    m.modal = :search
    m.focus = FocusState(Any[m.search_input]; active = true)
    m
end
function _apply_search!(m::AppModel)   # keep query, drop the overlay
    m.sel_lane = 1; m.sel_col = 1; m.sel_idx = 1
    _close_modal!(m)
end
function _clear_search!(m::AppModel)   # Esc clears the query and closes
    set_text!(m.search_input, "")
    m.sel_lane = 1; m.sel_col = 1; m.sel_idx = 1
    _close_modal!(m)
end

# ── New sprint ──────────────────────────────────────────────────────────────
function _open_new_sprint!(m::AppModel)
    set_text!(m.sprint_name_input, ""); set_text!(m.sprint_goal_input, "")
    m.modal = :new_sprint
    m.focus = FocusState(Any[m.sprint_name_input, m.sprint_goal_input]; active = true)
    m
end
function _submit_new_sprint!(m::AppModel)
    name = strip(text(m.sprint_name_input))
    if isempty(name)
        m.message = "Sprint name required"; return m
    end
    s = Stores.create_sprint!(m.boardstore; name = String(name), goal = String(strip(text(m.sprint_goal_input))))
    m.message = "Created sprint $(s.name)"
    _close_modal!(m)
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function _modal_box(content_area::Rect, w::Int, h::Int, title::String, buf::Buffer)
    r = _panel_rect(content_area, w, h)
    _clear_rect!(buf, r)
    render(Block(title = title, border_style = Style(; fg = col_primary()),
                 title_style = Style(; fg = col_primary(), bold = true)), r, buf)
end

function render_card_detail!(m::AppModel, buf::Buffer, content_area::Rect)
    id = m.card_issue_id
    iss = id === nothing ? nothing : Stores.get_issue(m.boardstore, id)
    iss === nothing && return
    w = clamp(content_area.width - 4, 30, content_area.width)
    h = clamp(content_area.height - 2, 10, content_area.height)
    inner = _modal_box(content_area, w, h, "$(iss.key) — Enter comment, Esc close", buf)
    x = inner.x + 1; y = inner.y + 1; maxy = inner.y + inner.height - 1
    set_string!(buf, x, y, _short(iss.title, inner.width - 2), Style(; fg = col_text(), bold = true)); y += 1
    meta = "Status:$(iss.status)  Prio:$(iss.priority)  " *
           (iss.story_points === nothing ? "" : "$(iss.story_points)sp  ") *
           "Epic:$(_epic_name(m, iss.epic_id))"
    set_string!(buf, x, y, _short(meta, inner.width - 2), Style(; fg = col_text_dim())); y += 1
    asg = iss.assignee_id === nothing ? "Unassigned" : _user_name(m, iss.assignee_id)
    due = iss.due_date === nothing ? "—" : string(iss.due_date)
    set_string!(buf, x, y, _short("Assignee:$(asg)  Due:$(due)", inner.width - 2), Style(; fg = col_text_dim())); y += 1
    if !isempty(iss.description)
        set_string!(buf, x, y, _short(iss.description, inner.width - 2), Style(; fg = col_text())); y += 1
    end
    # comments
    y += 1; y <= maxy && (set_string!(buf, x, y, "COMMENTS", Style(; fg = col_primary(), bold = true)); y += 1)
    for c in Stores.list_comments(m.boardstore, iss.id)
        y > maxy - 3 && break
        who = _user_name(m, c.author_id)
        set_string!(buf, x, y, _short("• $(who): $(c.body)", inner.width - 2), Style(; fg = col_text())); y += 1
    end
    # activity tail
    acts = Stores.list_activity(m.boardstore, iss.id)
    if !isempty(acts) && y <= maxy - 2
        set_string!(buf, x, y, "ACTIVITY", Style(; fg = col_primary(), bold = true)); y += 1
        for a in acts[max(1, end - 2):end]
            y > maxy - 1 && break
            set_string!(buf, x, y, _short("· $(a.kind): $(a.detail)", inner.width - 2), Style(; fg = col_text_muted())); y += 1
        end
    end
    # comment input on the last line
    set_string!(buf, x, maxy, "> ", Style(; fg = col_primary()))
    render(m.comment_input, Rect(x + 2, maxy, inner.width - 4, 1), buf)
end

function render_card_edit!(m::AppModel, buf::Buffer, content_area::Rect)
    f = m.edit_form; f === nothing && return
    w = clamp(content_area.width - 4, 40, content_area.width)
    h = clamp(content_area.height - 2, 14, content_area.height)
    inner = _modal_box(content_area, w, h, (m.card_issue_id === nothing ? "NEW CARD — Tab fields, ^S/Enter save, Esc cancel" : "EDIT CARD — Tab fields, ^S/Enter save"), buf)
    x = inner.x + 1; y = inner.y + 1; iw = inner.width - 2
    set_string!(buf, x, y, "Title:", f.title_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.title_input, Rect(x + 7, y, iw - 7, 1), buf); y += 1
    set_string!(buf, x, y, "Desc:", f.desc_area.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.desc_area, Rect(x + 7, y, iw - 7, 2), buf); y += 2
    render(f.priority_sel, Rect(x, y, iw, 1), buf); y += 1
    set_string!(buf, x, y, "Points:", f.points_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.points_input, Rect(x + 8, y, 8, 1), buf); y += 1
    render(f.epic_sel, Rect(x, y, iw, 1), buf); y += 1
    render(f.sprint_sel, Rect(x, y, iw, 1), buf); y += 1
    render(f.assignee_sel, Rect(x, y, iw, 1), buf); y += 1
    set_string!(buf, x, y, "Start:", f.start_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.start_input, Rect(x + 7, y, 12, 1), buf)
    set_string!(buf, x + 22, y, "Due:", f.due_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.due_input, Rect(x + 27, y, 12, 1), buf)
    if f.start_input.focused || f.due_input.focused
        hx = x + 27 + 12 + 1  # due rect end + 1 (relative, not hard x+40)
        hint = "(YYYY-MM-DD or blank to clear)"
        avail = (x + iw) - hx
        if avail > 0
            set_string!(buf, hx, y, _short(hint, avail), Style(; fg = col_text_muted()))
        end
    end
    y += 1
    render(f.labels_ms, Rect(x, y, iw, 1), buf)
end

function render_confirm!(m::AppModel, buf::Buffer, content_area::Rect)
    msg = m.confirm_kind === :bulk_delete ? "Delete $(length(m.confirm_target)) selected issues?" :
          m.confirm_kind === :close_sprint ? "Close sprint? Incomplete issues roll back to backlog." :
          "Delete this issue?"
    w = clamp(length(msg) + 6, 24, content_area.width)
    inner = _modal_box(content_area, w, 5, "CONFIRM", buf)
    set_string!(buf, inner.x + 1, inner.y + 1, _short(msg, inner.width - 2), Style(; fg = col_text()))
    set_string!(buf, inner.x + 1, inner.y + inner.height - 1, "[y] yes   [n] no",
                Style(; fg = col_primary(), dim = true))
end

function render_search!(m::AppModel, buf::Buffer, content_area::Rect)
    inner = _modal_box(content_area, clamp(50, 24, content_area.width), 5,
                       "SEARCH — Enter apply, Esc clear", buf)
    set_string!(buf, inner.x + 1, inner.y + 1, "Query:", Style(; fg = col_primary(), bold = true))
    render(m.search_input, Rect(inner.x + 8, inner.y + 1, inner.width - 9, 1), buf)
end

function render_new_sprint!(m::AppModel, buf::Buffer, content_area::Rect)
    inner = _modal_box(content_area, clamp(50, 24, content_area.width), 7,
                       "NEW SPRINT — Tab, Enter create, Esc cancel", buf)
    x = inner.x + 1; y = inner.y + 1
    set_string!(buf, x, y, "Name:", m.sprint_name_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(m.sprint_name_input, Rect(x + 6, y, inner.width - 7, 1), buf); y += 2
    set_string!(buf, x, y, "Goal:", m.sprint_goal_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(m.sprint_goal_input, Rect(x + 6, y, inner.width - 7, 1), buf)
end
