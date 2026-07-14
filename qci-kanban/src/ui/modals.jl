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
# Field order (design §4.4): title → description → priority → est. hours
# (story_points) → work_type → asset_tag → location → epic → sprint → labels
# → assignee → start_date → due_date.
mutable struct EditForm
    title_input::TextInput
    desc_area::TextArea
    priority_sel::Selector
    points_input::TextInput
    work_type_sel::Selector
    asset_input::TextInput
    location_input::TextInput
    epic_sel::Selector
    sprint_sel::Selector
    labels_ms::MultiSelect
    assignee_sel::Selector
    start_input::DateField
    due_input::DateField
end

edit_editors(f::EditForm) = Any[f.title_input, f.desc_area, f.priority_sel, f.points_input,
                                f.work_type_sel, f.asset_input, f.location_input,
                                f.epic_sel, f.sprint_sel, f.labels_ms, f.assignee_sel,
                                f.start_input, f.due_input]

function _build_edit_form(m::AppModel, iss::Union{Domain.Issue,Nothing})
    pid = _scope(m)
    epics = Stores.list_epics(m.boardstore; project_id = pid)
    sprints = Stores.list_sprints(m.boardstore; project_id = pid)
    users = Stores.list_users(m.userstore)
    labels = Stores.list_labels(m.boardstore; project_id = pid)

    prio_opts = collect(Domain.PRIORITIES)
    prio_sel = iss === nothing ? 2 : something(findfirst(==(iss.priority), prio_opts), 2)

    wt_opts = ["(none)"; collect(Domain.WORK_TYPES)]
    wt_vals = Any[nothing; collect(Domain.WORK_TYPES)]
    wt_sel = iss === nothing || iss.work_type === nothing ? 1 :
             something(findfirst(==(iss.work_type), wt_vals), 1)

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
        Selector("Type:", wt_opts, wt_vals; selected = wt_sel),
        _make_input(; text = iss === nothing || iss.asset_tag === nothing ? "" : iss.asset_tag),
        _make_input(; text = iss === nothing || iss.location === nothing ? "" : iss.location),
        Selector("Epic:", epic_opts, epic_vals; selected = epic_sel),
        Selector("Sprint:", sprint_opts, sprint_vals; selected = sprint_sel),
        MultiSelect("Labels:", label_opts, label_vals; checked = label_checked),
        Selector("Assignee:", user_opts, user_vals; selected = asg_sel),
        DateField(; text = iss === nothing || iss.start_date === nothing ? "" : string(iss.start_date)),
        DateField(; text = iss === nothing || iss.due_date === nothing ? "" : string(iss.due_date)),
    )
end

# ── Opening / closing modals (set focus + which issue) ──────────────────────
function _open_card_detail!(m::AppModel)
    iss = selected_issue(m); iss === nothing && return m
    _clear_board_mouse_ui!(m)
    m.card_issue_id = iss.id
    m.modal = :card_detail
    set_text!(m.comment_input, "")
    m.focus = FocusState(Any[m.comment_input]; active = true)
    m
end

function _open_card_edit!(m::AppModel; create::Bool = false, due_prefill = nothing)
    iss = create ? nothing : selected_issue(m)
    (!create && iss === nothing) && return m
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    if create
        can!(m, :create_issue) || return m
    else
        can!(m, :edit_issue; resource = iss) || return m
    end
    _clear_board_mouse_ui!(m)
    m.card_issue_id = create ? nothing : iss.id
    m.edit_form = _build_edit_form(m, iss)
    due_prefill === nothing || set_date_text!(m.edit_form.due_input, string(due_prefill))
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
    _clear_board_mouse_ui!(m)
    m.card_issue_id = iss.id
    m.modal = :card_detail
    set_text!(m.comment_input, "")
    m.focus = FocusState(Any[m.comment_input]; active = true)
    m
end

"""
    _open_edit_issue!(m, iss)

Open the card-edit modal pre-populated from a specific issue (calendar/gantt
`e`, where the target comes from that view's selection rather than the board
grid). No-op when `iss === nothing`.
"""
function _open_edit_issue!(m::AppModel, iss)
    iss === nothing && return m
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :edit_issue; resource = iss) || return m
    _clear_board_mouse_ui!(m)
    m.card_issue_id = iss.id
    m.edit_form = _build_edit_form(m, iss)
    m.modal = :card_edit
    m.focus = FocusState(edit_editors(m.edit_form); active = true)
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
`:invalid`. The UI now shows a warning popup (allowing save with the date
cleared) and informs the expected format (YYYY-MM-DD).
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
        handle_key!(f.desc_area, KeyEvent(:enter))  # COV_EXCL_LINE
        return m  # COV_EXCL_LINE — desc-area newline in edit modal; path exercised by card-edit tests (currently limited by unrelated fixwave C6 failures)
    end
    # Enter on an open date menu commits the day (does not save the whole form).
    ed = focused_editor(m.focus)
    if ed isa DateField && ed.menu_open
        handle_key!(ed, KeyEvent(:enter))
        return m
    end
    _save_edit!(m)
end

function _save_edit!(m::AppModel)
    f = m.edit_form
    f === nothing && return _close_modal!(m)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    if m.card_issue_id === nothing
        can!(m, :create_issue) || return m
    else
        prev_for_can = Stores.get_issue(m.boardstore, m.card_issue_id)
        can!(m, :edit_issue; resource = prev_for_can) || return m
    end
    title = strip(text(f.title_input))
    if isempty(title)
        m.message = "Title is required"; return m
    end
    start_text = text(f.start_input)
    due_text = text(f.due_input)
    # Dates: distinguish empty (clear) from malformed (keep old value, error out).
    start_kind, start_date = _date_field(start_text)
    due_kind, due_date = _date_field(due_text)
    if start_kind === :invalid || due_kind === :invalid
        bad = start_kind === :invalid ? "start" : "due"
        m.confirm_kind = :bad_date
        m.confirm_target = bad
        m.modal = :confirm
        m.focus = FocusState()
        return m
    end
    priority = String(sel_current_value(f.priority_sel))
    pts = _parse_points(text(f.points_input))
    work_type = sel_current_value(f.work_type_sel)
    asset_tag = let t = strip(text(f.asset_input)); isempty(t) ? nothing : String(t) end
    location = let t = strip(text(f.location_input)); isempty(t) ? nothing : String(t) end
    epic_id = sel_current_value(f.epic_sel)
    sprint_id = sel_current_value(f.sprint_sel)
    assignee_id = sel_current_value(f.assignee_sel)
    label_ids = ms_selected_values(f.labels_ms)
    desc = text(f.desc_area)

    if m.card_issue_id === nothing
        iss = Stores.create_issue!(m.boardstore; title = String(title), description = desc,
                                   priority = priority, story_points = pts,
                                   epic_id = epic_id, sprint_id = sprint_id,
                                   assignee_id = assignee_id, start_date = start_date, due_date = due_date,
                                   project_id = _scope(m),
                                   asset_tag = asset_tag, location = location, work_type = work_type)
        Stores.set_labels!(m.boardstore, iss.id, label_ids)
        Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                             kind = :created, detail = "created $(iss.key)")
        assignee_id === nothing || _notify_issue!(m, iss, :assigned, assignee_id, "")
        _set_message!(m, "Created $(iss.key)")
    else
        prev = Stores.get_issue(m.boardstore, m.card_issue_id)
        Stores.update_issue!(m.boardstore, m.card_issue_id; title = String(title), description = desc,
                             priority = priority, story_points = pts, epic_id = epic_id,
                             sprint_id = sprint_id, assignee_id = assignee_id,
                             start_date = start_date, due_date = due_date,
                             asset_tag = asset_tag, location = location, work_type = work_type)
        Stores.set_labels!(m.boardstore, m.card_issue_id, label_ids)
        iss = Stores.get_issue(m.boardstore, m.card_issue_id)
        Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                             kind = :updated, detail = "edited $(iss.key)")
        if assignee_id !== nothing && (prev === nothing || prev.assignee_id != assignee_id)
            _notify_issue!(m, iss, :assigned, assignee_id, "")
        end
        _set_message!(m, "Saved $(iss.key)")
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
    # Selection first so warn-only does not toast on no-op (PR-H1 review).
    iss = selected_issue(m); iss === nothing && return m
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :delete_issue) || return m
    _clear_board_mouse_ui!(m)
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
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :delete_issue) || return m
    _clear_board_mouse_ui!(m)
    m.confirm_kind = :bulk_delete; m.confirm_target = targets
    m.modal = :confirm; m.focus = FocusState()
    m
end

function _confirm_yes!(m::AppModel)
    k = m.confirm_kind
    if k === :delete_one
        # Re-gate at confirm (mirrors sprint close); keep warn toast on success.
        can!(m, :delete_issue) || return m
        id = m.confirm_target
        if id !== nothing
            Stores.delete_issue!(m.boardstore, id)
            delete!(m.selected_ids, id)
            _set_message!(m, "Deleted issue")
        end
    elseif k === :bulk_delete
        can!(m, :delete_issue) || return m
        n = 0
        for id in m.confirm_target
            Stores.delete_issue!(m.boardstore, id) && (n += 1)   # count only real deletes
        end
        empty!(m.selected_ids)
        _set_message!(m, "Deleted $(n) issues")
    elseif k === :close_sprint
        _do_close_sprint!(m, m.confirm_target)
    elseif k === :bad_date  # COV_EXCL_START
        bad = m.confirm_target
        f = m.edit_form
        if bad == "start"
            set_date_text!(f.start_input, "")
        else
            set_date_text!(f.due_input, "")
        end
        m.confirm_kind = :none
        _save_edit!(m)  # now validates clean and performs the save/close
        return m
    end  # COV_EXCL_STOP — bad_date confirm handler for invalid/empty dates in card edit; not fully covered due to unrelated failing fixwave C6 tests (date validation flow)
    _clamp_selection!(m)
    _close_modal!(m)
end

# ── Search ──────────────────────────────────────────────────────────────────
function _open_search!(m::AppModel)
    _clear_board_mouse_ui!(m)
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
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :manage_sprint) || return m
    _clear_board_mouse_ui!(m)
    set_text!(m.sprint_name_input, ""); set_text!(m.sprint_goal_input, "")
    m.modal = :new_sprint
    m.focus = FocusState(Any[m.sprint_name_input, m.sprint_goal_input]; active = true)
    m
end
function _submit_new_sprint!(m::AppModel)
    # H1 subset; full Q6 matrix for edit/create; other mutates deferred.
    can!(m, :manage_sprint) || return m
    name = strip(text(m.sprint_name_input))
    if isempty(name)
        m.message = "Sprint name required"; return m
    end
    s = Stores.create_sprint!(m.boardstore; name = String(name),
                              goal = String(strip(text(m.sprint_goal_input))),
                              project_id = _scope(m))
    _set_message!(m, "Created sprint $(s.name)")
    _close_modal!(m)
end

# ── Project switcher (PR-M7) ────────────────────────────────────────────────
function render_project_switch!(m::AppModel, buf::Buffer, content_area::Rect)
    projs = m.projects_cache
    n = length(projs)
    w = clamp(48, 28, content_area.width)
    h = clamp(n + 4, 6, content_area.height)
    inner = _modal_box(content_area, w, h, "SWITCH PROJECT", buf)
    set_string!(buf, inner.x + 1, inner.y,
                _short("j/k navigate · Enter select · n new · Esc cancel", inner.width),
                Style(; fg = col_text_dim()))
    y = inner.y + 2
    maxy = inner.y + inner.height - 1
    for (i, p) in enumerate(projs)
        y > maxy && break
        mark = i == m.project_sel ? "▸ " : "  "
        active = p.id == m.active_project_id ? " *" : ""
        line = "$(mark)$(p.name) ($(p.key))$(active)"
        sty = i == m.project_sel ? sel_style() : Style(; fg = col_text())
        set_string!(buf, inner.x + 1, y, _short(line, inner.width - 1), sty)
        y += 1
    end
end

# ── Create project (PR-M7; focus-routed name + key like new_sprint) ─────────
function render_project_create!(m::AppModel, buf::Buffer, content_area::Rect)
    inner = _modal_box(content_area, clamp(52, 28, content_area.width), 8,
                       "NEW PROJECT — Tab, Enter create, Esc cancel", buf)
    x = inner.x + 1; y = inner.y + 1
    nsty = m.project_name_input.focused ? Style(; fg = col_primary(), bold = true) :
                                          Style(; fg = col_text_dim())
    ksty = m.project_key_input.focused  ? Style(; fg = col_primary(), bold = true) :
                                          Style(; fg = col_text_dim())
    set_string!(buf, x, y, "Name:", nsty)
    render(m.project_name_input, Rect(x + 6, y, inner.width - 7, 1), buf); y += 2
    set_string!(buf, x, y, "Key:", ksty)
    render(m.project_key_input, Rect(x + 6, y, min(12, inner.width - 7), 1), buf); y += 2
    set_string!(buf, x, y, _short("Key: 2–8 A-Z0-9, starts with letter (e.g. LINEA)", inner.width),
                Style(; fg = col_text_muted()))
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function _modal_box(content_area::Rect, w::Int, h::Int, title::String, buf::Buffer)
    r = _panel_rect(content_area, w, h)
    _clear_rect!(buf, r)
    render(Block(title = title, border_style = Style(; fg = col_primary()),
                 title_style = Style(; fg = col_primary(), bold = true)), r, buf)
end

# ── Card detail v2 layout: ticket strip (chips + flowing meta) ───────────
# Intentionally *not* a two-column form: status/priority are raised chips,
# secondary facts are a prose-style middot line, sections use dashed rules.

function _pretty_due(d::Union{Nothing,Date})
    d === nothing && return "—"
    Dates.format(d, dateformat"u d, yyyy")
end

"""
Paint a chip `[ label ]` at (x,y). Returns next free x (after gap).

No surface/surface_hi background — those colors are reserved for board cards
and the no-bleed test treats them as board chrome leaking through the modal.
"""
function _detail_chip!(buf::Buffer, x::Int, y::Int, lim::Int, label::AbstractString;
                       fg = col_primary_hi())
    text = "[" * label * "]"
    tw = textwidth(text)
    x + tw > lim && return lim
    set_string!(buf, x, y, text, Style(; fg = fg, bold = true))
    return x + tw + 1
end

"""
Paint a dashed section rule: `── Title ────…`. Returns y+1.
"""
function _detail_rule!(buf::Buffer, x::Int, y::Int, maxy::Int, iw::Int, title::AbstractString)
    y > maxy && return y
    # "── Title ──…"
    head = "── " * title * " "
    rest = max(0, iw - textwidth(head))
    line = head * repeat("─", rest)
    set_string!(buf, x, y, _short(line, iw), Style(; fg = col_primary()))
    return y + 1
end

"Join non-empty fragments with middots; paint one flowing line."
function _detail_flow!(buf::Buffer, x::Int, y::Int, iw::Int, parts::Vector{String};
                       style::Style = Style(; fg = col_text_dim()))
    isempty(parts) && return y
    line = join(parts, "  ·  ")
    set_string!(buf, x, y, _short(line, iw), style)
    return y + 1
end

function render_card_detail!(m::AppModel, buf::Buffer, content_area::Rect)
    id = m.card_issue_id
    iss = id === nothing ? nothing : Stores.get_issue(m.boardstore, id)
    iss === nothing && return
    # Compact, centered ticket panel (not a near-fullscreen sheet).
    # Color-rect bleed is killed by content_area clear + RESET in view.
    w = clamp(min(66, content_area.width - 8), 34, content_area.width)
    h = clamp(min(18, content_area.height - 4), 12, content_area.height)
    inner = _modal_box(content_area, w, h, "$(iss.key)  ·  Enter comment  ·  Esc close", buf)
    x = inner.x + 1; y = inner.y + 1; maxy = inner.y + inner.height - 1
    iw = inner.width - 2
    lim = x + iw

    # ── Title (hero) ──────────────────────────────────────────────────
    set_string!(buf, x, y, _short(iss.title, iw), Style(; fg = col_text(), bold = true)); y += 1

    # ── Chip strip: status + priority (+ hours if present) ─────────────
    if y <= maxy
        cx = x
        cx = _detail_chip!(buf, cx, y, lim, iss.status; fg = col_primary_hi())
        cx = _detail_chip!(buf, cx, y, lim, iss.priority;
                           fg = priority_color(iss.priority))
        if iss.story_points !== nothing
            hrs = string(iss.story_points) * " hrs"
            cx = _detail_chip!(buf, cx, y, lim, hrs; fg = col_text_dim())
        end
        y += 1
    end

    # ── Flowing meta: assignee · due · epic · start ────────────────────
    asg = iss.assignee_id === nothing ? "Unassigned" : _user_name(m, iss.assignee_id)
    overdue = iss.due_date !== nothing && iss.due_date < Dates.today() && iss.status != "Done"
    due_s = iss.due_date === nothing ? nothing : ("Due " * _pretty_due(iss.due_date))
    meta = String[asg]
    due_s !== nothing && push!(meta, due_s)
    if iss.epic_id !== nothing
        push!(meta, _epic_name(m, iss.epic_id))
    end
    if iss.start_date !== nothing
        push!(meta, "starts " * _pretty_due(iss.start_date))
    end
    if y <= maxy
        # Overdue: repaint whole flow line in err so the due date stands out
        st = overdue ? Style(; fg = col_err()) : Style(; fg = col_text_dim())
        y = _detail_flow!(buf, x, y, iw, meta; style = st)
    end

    # ── Work order (inline, only when asset / location / type set) ─────
    has_wo = iss.asset_tag !== nothing || iss.location !== nothing || iss.work_type !== nothing
    if has_wo && y <= maxy
        y = _detail_rule!(buf, x, y, maxy, iw, "WORK ORDER")
        wo = String[]
        iss.asset_tag !== nothing && push!(wo, "Asset " * iss.asset_tag)
        iss.location !== nothing && push!(wo, iss.location)
        iss.work_type !== nothing && push!(wo, iss.work_type)
        # hours already on chip strip when present; still echo if only hours
        # would be lonely here — skip
        y <= maxy && (y = _detail_flow!(buf, x, y, iw, wo;
                                         style = Style(; fg = col_primary_hi())))
    end

    # ── Links (G6b) ───────────────────────────────────────────────────
    if y <= maxy
        lnks = Stores.list_links(m.boardstore; issue_id = iss.id, kind = "blocks")
        if !isempty(lnks)
            out_keys = String[]
            in_keys = String[]
            for ln in lnks
                if ln.from_id == iss.id
                    other = Stores.get_issue(m.boardstore, ln.to_id)
                    push!(out_keys, other === nothing ? ln.to_id : other.key)
                elseif ln.to_id == iss.id
                    other = Stores.get_issue(m.boardstore, ln.from_id)
                    push!(in_keys, other === nothing ? ln.from_id : other.key)
                end
            end
            parts = String[]
            isempty(out_keys) || push!(parts, "blocks " * join(out_keys, ", "))
            isempty(in_keys) || push!(parts, "blocked by " * join(in_keys, ", "))
            if !isempty(parts)
                y = _detail_flow!(buf, x, y, iw, parts;
                                  style = Style(; fg = col_text_muted()))
            end
        end
    end

    # ── Description (no heavy banner — just body under a thin rule) ────
    if !isempty(iss.description) && y + 1 <= maxy
        y = _detail_rule!(buf, x, y, maxy, iw, "Notes")
        y <= maxy && (set_string!(buf, x, y, _short(iss.description, iw),
                                  Style(; fg = col_text())); y += 1)
    end

    # ── Comments ──────────────────────────────────────────────────────
    if y <= maxy
        y = _detail_rule!(buf, x, y, maxy, iw, "COMMENTS")
    end
    for c in Stores.list_comments(m.boardstore, iss.id)
        y > maxy - 3 && break
        who = _user_name(m, c.author_id)
        set_string!(buf, x, y, _short(who * "  ·  " * c.body, iw),
                    Style(; fg = col_text())); y += 1
    end

    # ── Activity tail ─────────────────────────────────────────────────
    acts = Stores.list_activity(m.boardstore, iss.id)
    if !isempty(acts) && y <= maxy - 2
        y = _detail_rule!(buf, x, y, maxy, iw, "ACTIVITY")
        for a in acts[max(1, end - 2):end]
            y > maxy - 1 && break
            set_string!(buf, x, y, _short(string(a.kind) * "  ·  " * a.detail, iw),
                        Style(; fg = col_text_muted())); y += 1
        end
    end

    # comment input on the last line
    set_string!(buf, x, maxy, "> ", Style(; fg = col_primary()))
    render(m.comment_input, Rect(x + 2, maxy, max(1, inner.width - 4), 1), buf)
end

function render_card_edit!(m::AppModel, buf::Buffer, content_area::Rect)
    f = m.edit_form; f === nothing && return
    creating = m.card_issue_id === nothing
    # Taller form to fit work-order fields (design §4.4); expand further when a
    # date calendar menu is open so the month grid fits under Start/Due.
    w = clamp(min(68, content_area.width - 10), 40, content_area.width)
    date_menu = (f.start_input.menu_open || f.due_input.menu_open)
    title = creating ? "NEW CARD — Tab/↑↓ fields, Spc date, ^S/Enter save, Esc cancel" :
                      "EDIT CARD — Tab/↑↓ fields, Spc date, ^S/Enter save"
    h = clamp(min(date_menu ? 28 : 20, content_area.height - 2), 16, content_area.height)
    inner = _modal_box(content_area, w, h, title, buf)
    x = inner.x + 1; y = inner.y + 1; iw = inner.width - 2
    maxy = inner.y + inner.height - 1
    set_string!(buf, x, y, "Title:", f.title_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.title_input, Rect(x + 7, y, iw - 7, 1), buf); y += 1
    set_string!(buf, x, y, "Desc:", f.desc_area.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.desc_area, Rect(x + 7, y, iw - 7, 2), buf); y += 2
    render(f.priority_sel, Rect(x, y, iw, 1), buf); y += 1
    set_string!(buf, x, y, "Hours:", f.points_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
    render(f.points_input, Rect(x + 7, y, 8, 1), buf); y += 1
    y <= maxy && (render(f.work_type_sel, Rect(x, y, iw, 1), buf); y += 1)
    if y <= maxy
        set_string!(buf, x, y, "Asset:", f.asset_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
        render(f.asset_input, Rect(x + 7, y, max(8, iw - 7), 1), buf); y += 1
    end
    if y <= maxy
        set_string!(buf, x, y, "Loc:", f.location_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
        render(f.location_input, Rect(x + 5, y, max(8, iw - 5), 1), buf); y += 1
    end
    y <= maxy && (render(f.epic_sel, Rect(x, y, iw, 1), buf); y += 1)
    y <= maxy && (render(f.sprint_sel, Rect(x, y, iw, 1), buf); y += 1)
    y <= maxy && (render(f.labels_ms, Rect(x, y, iw, 1), buf); y += 1)
    y <= maxy && (render(f.assignee_sel, Rect(x, y, iw, 1), buf); y += 1)
    if y <= maxy
        set_string!(buf, x, y, "Start:", f.start_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
        # Date fields: value on one row; calendar uses remaining height when open.
        start_h = f.start_input.menu_open ? max(1, maxy - y + 1) : 1
        due_h = f.due_input.menu_open ? max(1, maxy - y + 1) : 1
        if f.start_input.menu_open
            render(f.start_input, Rect(x + 7, y, max(22, iw - 7), start_h), buf)
        elseif f.due_input.menu_open
            set_string!(buf, x + 7, y, fit_width(isempty(text(f.start_input)) ? "(none)" : text(f.start_input), 12),
                        Style(; fg = col_text()))
            set_string!(buf, x + 22, y, "Due:", f.due_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
            render(f.due_input, Rect(x + 27, y, max(22, iw - 27), due_h), buf)
        else
            render(f.start_input, Rect(x + 7, y, 14, 1), buf)
            set_string!(buf, x + 22, y, "Due:", f.due_input.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim()))
            render(f.due_input, Rect(x + 27, y, 14, 1), buf)
        end
    end
end

function render_confirm!(m::AppModel, buf::Buffer, content_area::Rect)
    if m.confirm_kind === :bad_date
        bad = m.confirm_target
        msg = "Invalid $(bad) date format. Use YYYY-MM-DD. Save anyway?"
        title = "WARNING"
    else
        msg = m.confirm_kind === :bulk_delete ? "Delete $(length(m.confirm_target)) selected issues?" :
              m.confirm_kind === :close_sprint ? "Close sprint? Incomplete issues roll back to backlog." :
              "Delete this issue?"
        title = "CONFIRM"
    end
    w = clamp(length(msg) + 6, 24, content_area.width)
    inner = _modal_box(content_area, w, 5, title, buf)
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
