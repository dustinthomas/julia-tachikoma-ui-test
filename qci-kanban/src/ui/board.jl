# ═══════════════════════════════════════════════════════════════════════
# ui/board.jl — Phase 3 Jira board: swimlane × status grid, rich cards,
# board ops (move/rank/assign/delete/bulk), quick filters, search, WIP limits.
#
# The board is derived state: `board_grid(m)` is a PURE function of the store
# + model UI state (swimlane mode, filters, search). Navigation and rendering
# both consult it, so selection can never disagree with what is drawn. All
# color goes through Theming accessors (test-enforced: no raw ColorRGB here).
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates

const BOARD_STATUSES = Domain.STATUSES   # ("Backlog","To Do","In Progress","Review","Done")
const SWIMLANE_MODES = (:none, :assignee, :epic, :priority)

# ── A single swimlane band: display name + a card list per status column ────
struct Lane
    key::String
    name::String
    cols::Vector{Vector{Domain.Issue}}   # length == length(BOARD_STATUSES)
end

# ── Lookups ─────────────────────────────────────────────────────────────────
function _user_name(m::AppModel, id)
    id === nothing && return "Unassigned"
    u = Stores.get_user(m.userstore, id)
    u === nothing ? "Unknown" : u.name
end
function _user_email(m::AppModel, id)
    id === nothing && return nothing
    u = Stores.get_user(m.userstore, id)
    u === nothing ? nothing : u.email
end
function _epic_name(m::AppModel, id)
    id === nothing && return "No Epic"
    e = Stores.get_epic(m.boardstore, id)
    e === nothing ? "No Epic" : e.name
end

function _initials(name::AbstractString)
    parts = filter(!isempty, split(strip(name)))
    isempty(parts) && return "?"
    length(parts) == 1 ? uppercase(string(first(parts[1]))) :
    uppercase(string(first(parts[1])) * string(first(parts[end])))
end

# ── Filtering + search (pure predicate over an issue) ───────────────────────
function _passes_filters(m::AppModel, iss::Domain.Issue)
    fs = m.active_filters
    if :mine in fs
        (m.current_user !== nothing && iss.assignee_id == m.current_user.id) || return false
    end
    if :high in fs
        iss.priority == "High" || return false
    end
    if :due_soon in fs
        (iss.due_date !== nothing && iss.due_date <= Dates.today() + Day(7)) || return false
    end
    if :sprint in fs
        asp = Stores.active_sprint(m.boardstore)
        (asp !== nothing && iss.sprint_id == asp.id) || return false
    end
    if m.label_filter !== nothing
        (m.label_filter in iss.labels) || return false
    end
    q = strip(text(m.search_input))
    if !isempty(q)
        ql = lowercase(q)
        hay = lowercase(
            join([iss.title, iss.key, iss.description, join(iss.labels, " ")], " "),
        )
        occursin(ql, hay) || return false
    end
    true
end

# ── Lane grouping key + display name for one issue in the current mode ───────
function _lane_of(m::AppModel, iss::Domain.Issue)
    mode = m.swimlane_by
    if mode === :assignee
        id = iss.assignee_id === nothing ? "~none" : iss.assignee_id
        return (id, _user_name(m, iss.assignee_id))
    elseif mode === :epic
        id = iss.epic_id === nothing ? "~none" : iss.epic_id
        return (id, _epic_name(m, iss.epic_id))
    elseif mode === :priority
        return (iss.priority, iss.priority)
    else
        return ("~all", "All Issues")
    end
end

"Sort key so lanes are stable and 'none' buckets sort last / priority sorts H→L."
function _lane_order(m::AppModel, key::String, name::String)
    if m.swimlane_by === :priority
        return get(Dict("High" => 1, "Medium" => 2, "Low" => 3), key, 9)
    end
    startswith(key, "~none") ? (2, name) : (1, name)
end

"""
    board_grid(m) -> Vector{Lane}

Pure projection of the store into the current swimlane × status grid, after
applying quick filters + live search. Each `Lane` has one card list per status
column, ordered by store position.
"""
function board_grid(m::AppModel)::Vector{Lane}
    issues = filter(i -> _passes_filters(m, i), Stores.list_issues(m.boardstore))
    # bucket: lane key -> (name, status -> issues)
    order = String[]
    names = Dict{String, String}()
    buckets = Dict{String, Vector{Domain.Issue}}()
    for iss in issues
        k, nm = _lane_of(m, iss)
        if !haskey(buckets, k)
            buckets[k] = Domain.Issue[];
            names[k] = nm;
            push!(order, k)
        end
        push!(buckets[k], iss)
    end
    isempty(order) && return Lane[Lane(
        "~all",
        m.swimlane_by === :none ? "All Issues" : "(no matches)",
        [Domain.Issue[] for _ in BOARD_STATUSES],
    )]
    sort!(order; by = k -> _lane_order(m, k, names[k]))
    lanes = Lane[]
    for k in order
        cols = [Domain.Issue[] for _ in BOARD_STATUSES]
        for iss in buckets[k]
            ci = findfirst(==(iss.status), BOARD_STATUSES)
            ci === nothing || push!(cols[ci], iss)
        end
        for c in cols
            sort!(c; by = i -> (i.position, i.key))
        end
        push!(lanes, Lane(k, names[k], cols))
    end
    lanes
end

# ── Selection ───────────────────────────────────────────────────────────────
_cell(g::Vector{Lane}, lane::Int, col::Int) =
    (1 <= lane <= length(g) && 1 <= col <= length(BOARD_STATUSES)) ? g[lane].cols[col] :
    Domain.Issue[]

function _clamp_selection!(m::AppModel, g::Vector{Lane} = board_grid(m))
    m.sel_lane = clamp(m.sel_lane, 1, max(1, length(g)))
    m.sel_col = clamp(m.sel_col, 1, length(BOARD_STATUSES))
    cell = _cell(g, m.sel_lane, m.sel_col)
    m.sel_idx = isempty(cell) ? 1 : clamp(m.sel_idx, 1, length(cell))
    g
end

"""
    _visible_ids(m) -> Set{String}

Ids of issues currently visible in the board grid (i.e. surviving the active
quick filters / label filter / search). Bulk operations are restricted to this
set so a selection made before a filter was applied can never act on — or
miscount — cards the user can no longer see (finding C7).
"""
function _visible_ids(m::AppModel, g::Vector{Lane} = board_grid(m))
    ids = Set{String}()
    for lane in g, cell in lane.cols, iss in cell
        push!(ids, iss.id)
    end
    ids
end

"The issue under the cursor, or nothing when the current cell is empty."
function selected_issue(m::AppModel)
    g = board_grid(m)
    cell = _cell(g, m.sel_lane, m.sel_col)
    isempty(cell) && return nothing
    cell[clamp(m.sel_idx, 1, length(cell))]
end

function _nav!(m::AppModel, dir::Symbol)
    g = _clamp_selection!(m)
    nl = length(g)
    if dir === :left
        m.sel_col = max(1, m.sel_col - 1);
        m.sel_idx = 1
    elseif dir === :right
        m.sel_col = min(length(BOARD_STATUSES), m.sel_col + 1);
        m.sel_idx = 1
    elseif dir === :down
        cell = _cell(g, m.sel_lane, m.sel_col)
        if m.sel_idx < length(cell)
            m.sel_idx += 1
        elseif m.sel_lane < nl
            m.sel_lane += 1;
            m.sel_idx = 1
        end
    elseif dir === :up
        if m.sel_idx > 1
            m.sel_idx -= 1
        elseif m.sel_lane > 1
            m.sel_lane -= 1
            prev = _cell(g, m.sel_lane, m.sel_col)
            m.sel_idx = max(1, length(prev))
        end
    end
    _clamp_selection!(m)
    m
end

"Point the selection at issue `id` wherever it now lives in the grid."
function _select_issue!(m::AppModel, id)
    id === nothing && return m
    g = board_grid(m)
    for (li, lane) in enumerate(g), (ci, cell) in enumerate(lane.cols)
        k = findfirst(i -> i.id == id, cell)
        if k !== nothing
            m.sel_lane = li;
            m.sel_col = ci;
            m.sel_idx = k
            return m
        end
    end
    _clamp_selection!(m, g)
    m
end

function _toggle_stats!(m::AppModel)
    m.show_stats = !m.show_stats
    m.message = m.show_stats ? "Stats on" : "Stats off"
    m
end

function _cycle_swimlane!(m::AppModel)
    i = findfirst(==(m.swimlane_by), SWIMLANE_MODES)
    m.swimlane_by =
        SWIMLANE_MODES[mod1((i === nothing ? 1 : i) + 1, length(SWIMLANE_MODES))]
    m.sel_lane = 1;
    m.sel_col = 1;
    m.sel_idx = 1
    m.message = "Swimlanes: $(m.swimlane_by)"
    m
end

# ── WIP limits ──────────────────────────────────────────────────────────────
_col_count(m::AppModel, status::AbstractString) =
    length(Stores.list_issues(m.boardstore; status = status))
_wip_limit(m::AppModel, status::AbstractString) = get(m.wip_limits, status, 0)
function _is_over_wip(m::AppModel, status::AbstractString)
    lim = _wip_limit(m, status)
    lim > 0 && _col_count(m, status) > lim
end
function _warn_if_over_wip!(m::AppModel, status::AbstractString)
    lim = _wip_limit(m, status)
    if lim > 0 && _col_count(m, status) > lim
        m.message = "⚠ WIP limit exceeded: $(status) ($(_col_count(m, status))/$(lim))"
    end
    m
end

# ── Notifications helper (only when a valid recipient email exists) ─────────
function _notify_issue!(
    m::AppModel,
    iss::Domain.Issue,
    kind::Symbol,
    recipient_id,
    detail::AbstractString,
)
    email = _user_email(m, recipient_id)
    email === nothing && return
    actor = m.current_user === nothing ? "" : m.current_user.name
    ev = Domain.NotificationEvent(;
        kind = kind,
        recipient_email = email,
        actor_name = actor,
        issue_key = iss.key,
        issue_title = iss.title,
        detail = detail,
    )
    Notify.notify!(m.notifier, ev)
end

_actor_id(m::AppModel) = m.current_user === nothing ? nothing : m.current_user.id

# ── Board ops (all mutate the store, then re-clamp selection) ───────────────
function _move_status!(m::AppModel, delta::Int)
    iss = selected_issue(m);
    iss === nothing && return m
    ci = findfirst(==(iss.status), BOARD_STATUSES)
    ci === nothing && return m
    nci = clamp(ci + delta, 1, length(BOARD_STATUSES))
    nci == ci && return m
    target = BOARD_STATUSES[nci]
    Stores.move_issue!(m.boardstore, iss.id; status = target)
    Stores.log_activity!(
        m.boardstore;
        issue_id = iss.id,
        actor_id = _actor_id(m),
        kind = :status_changed,
        detail = "$(iss.status) → $(target)",
    )
    _notify_issue!(m, iss, :status_changed, iss.assignee_id, "$(iss.status) → $(target)")
    m.message = "$(iss.key) → $(target)"
    _warn_if_over_wip!(m, target)
    _select_issue!(m, iss.id)
    m
end

function _rank!(m::AppModel, delta::Int)
    iss = selected_issue(m);
    iss === nothing && return m
    Stores.rank_issue!(m.boardstore, iss.id; position = max(0, iss.position + delta))
    m.message = "Ranked $(iss.key)"
    _select_issue!(m, iss.id)
    m
end

function _assign_me!(m::AppModel)
    iss = selected_issue(m);
    iss === nothing && return m
    m.current_user === nothing && return m
    Stores.update_issue!(m.boardstore, iss.id; assignee_id = m.current_user.id)
    Stores.log_activity!(
        m.boardstore;
        issue_id = iss.id,
        actor_id = _actor_id(m),
        kind = :assigned,
        detail = "assigned to $(m.current_user.name)",
    )
    _notify_issue!(m, iss, :assigned, m.current_user.id, "")
    m.message = "$(iss.key) assigned to you"
    m
end

function _toggle_select!(m::AppModel)
    iss = selected_issue(m);
    iss === nothing && return m
    iss.id in m.selected_ids ? delete!(m.selected_ids, iss.id) :
    push!(m.selected_ids, iss.id)
    m.message = "$(length(m.selected_ids)) selected"
    m
end

function _bulk_move!(m::AppModel)
    isempty(m.selected_ids) && (m.message = "Nothing selected"; return m)
    target = BOARD_STATUSES[m.sel_col]
    vis = _visible_ids(m)
    n = 0
    for id in collect(m.selected_ids)
        id in vis || continue                       # never act on filtered-out cards
        iss = Stores.get_issue(m.boardstore, id);
        iss === nothing && continue
        Stores.move_issue!(m.boardstore, id; status = target)
        Stores.log_activity!(
            m.boardstore;
            issue_id = id,
            actor_id = _actor_id(m),
            kind = :status_changed,
            detail = "$(iss.status) → $(target)",
        )
        _notify_issue!(
            m,
            iss,
            :status_changed,
            iss.assignee_id,
            "$(iss.status) → $(target)",
        )
        n += 1
    end
    m.message = "Moved $(n) → $(target)"
    _warn_if_over_wip!(m, target)
    empty!(m.selected_ids)
    _clamp_selection!(m)
    m
end

function _bulk_assign!(m::AppModel)
    (isempty(m.selected_ids) || m.current_user === nothing) && return m
    vis = _visible_ids(m)
    n = 0
    for id in collect(m.selected_ids)
        id in vis || continue                       # never act on filtered-out cards
        iss = Stores.get_issue(m.boardstore, id);
        iss === nothing && continue
        Stores.update_issue!(m.boardstore, id; assignee_id = m.current_user.id)
        Stores.log_activity!(
            m.boardstore;
            issue_id = id,
            actor_id = _actor_id(m),
            kind = :assigned,
            detail = "assigned to $(m.current_user.name)",
        )
        _notify_issue!(m, iss, :assigned, m.current_user.id, "")
        n += 1
    end
    m.message = "Assigned $(n) to you"
    empty!(m.selected_ids)
    m
end

# ── Quick filters ───────────────────────────────────────────────────────────
function _toggle_filter!(m::AppModel, f::Symbol)
    f in m.active_filters ? delete!(m.active_filters, f) : push!(m.active_filters, f)
    m.sel_lane = 1;
    m.sel_col = 1;
    m.sel_idx = 1
    m.message =
        isempty(m.active_filters) && m.label_filter === nothing ? "Filters cleared" :
        "Filter: " * join(sort(collect(string.(m.active_filters))), ",")
    m
end

function _cycle_label_filter!(m::AppModel)
    lbls = Stores.list_labels(m.boardstore)
    if isempty(lbls)
        m.message = "No labels";
        return m
    end
    ids = [l.id for l in lbls]
    cur = m.label_filter === nothing ? 0 : something(findfirst(==(m.label_filter), ids), 0)
    m.label_filter = cur >= length(ids) ? nothing : ids[cur + 1]
    nm =
        m.label_filter === nothing ? "off" :
        something(findfirst(l -> l.id == m.label_filter, lbls), 1) |> i -> lbls[i].name
    m.message = "Label filter: $(nm)"
    m.sel_lane = 1;
    m.sel_col = 1;
    m.sel_idx = 1
    m
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function _wrap_title(t::AbstractString, w::Int, maxlines::Int)
    w <= 0 && return String[]
    words = split(t)
    lines = String[];
    cur = ""
    for wd in words
        cand = isempty(cur) ? wd : cur * " " * wd
        if textwidth(cand) <= w
            cur = cand
        else
            isempty(cur) || push!(lines, cur)
            cur = fit_width(wd, w)                # width-safe (no-op if it fits)
            length(lines) >= maxlines && break
        end
    end
    length(lines) < maxlines && !isempty(cur) && push!(lines, cur)
    if !isempty(lines) &&
       textwidth(join(words, " ")) > sum(textwidth, lines) + length(lines) - 1
        last = lines[end]
        lines[end] =
            textwidth(last) > w - 1 ? fit_width(last, max(1, w - 1)) * "…" : last * "…"
    end
    lines
end

_priority_glyph(p::AbstractString) = p == "High" ? "▲" : p == "Low" ? "▼" : "■"

function _due_chip(iss::Domain.Issue)
    iss.due_date === nothing && return ("", false)
    overdue = iss.due_date < Dates.today() && iss.status != "Done"
    ("▣" * Dates.format(iss.due_date, "u-dd"), overdue)
end

function _start_chip(iss::Domain.Issue)
    iss.start_date === nothing && return ""
    "S:" * Dates.format(iss.start_date, "u-dd")
end

"""
Render one rich card's content into a rect; returns nothing. Selected/bulk
styling applied. `bg` threads a card-surface background through every style
(the modern bordered card fills its interior); `inline_marker=false` drops the
leading ▸/space (the modern card draws its arrow on the frame instead).
"""
function _render_card!(
    m::AppModel,
    buf::Buffer,
    r::Rect,
    iss::Domain.Issue,
    selected::Bool;
    bg = nothing,
    inline_marker::Bool = true,
)
    (r.width < 4 || r.height < 1) && return
    stl(; kw...) = bg === nothing ? Style(; kw...) : Style(; kw..., bg = bg)
    bulk = iss.id in m.selected_ids
    key_style = selected ? sel_style() : stl(; fg = col_primary())
    marker = inline_marker ? (selected ? "▸" : (bulk ? "●" : " ")) : (bulk ? "●" : "")
    # line 1: marker + key + priority glyph + points
    pts = iss.story_points === nothing ? "" : " $(iss.story_points)sp"
    head = "$(marker)$(iss.key)"
    set_string!(buf, r.x, r.y, fit_width(head, r.width), key_style)
    gx = r.x + textwidth(head) + 1
    if gx + 1 <= r.x + r.width
        set_string!(
            buf,
            gx,
            r.y,
            _priority_glyph(iss.priority),
            stl(; fg = priority_color(iss.priority)),
        )
        pxs = gx + 2
        isempty(pts) ||
            pxs + length(pts) > r.x + r.width ||
            set_string!(buf, pxs, r.y, pts, stl(; fg = col_text_dim()))
    end
    # line 2-3: wrapped title
    if r.height >= 2
        tlines = _wrap_title(iss.title, r.width, min(2, r.height - 1))
        for (i, ln) in enumerate(tlines)
            set_string!(buf, r.x, r.y + i, ln, stl(; fg = col_text()))
        end
    end
    # line 4: epic tag / labels / assignee / start / due (PR1 date surfacing)
    if r.height >= 4
        y = r.y + 3
        x = r.x
        if iss.epic_id !== nothing
            tag = "◆" * _short(_epic_name(m, iss.epic_id), 7)
            x + textwidth(tag) <= r.x + r.width &&
                set_string!(buf, x, y, tag, stl(; fg = epic_color(iss.epic_id)))
            x += textwidth(tag) + 1
        end
        for lid in iss.labels
            chip = "•"
            x + 1 <= r.x + r.width && set_string!(buf, x, y, chip, stl(; fg = col_warn()))
            x += 1
        end
        if iss.assignee_id !== nothing
            ini = _initials(_user_name(m, iss.assignee_id))
            x + textwidth(ini) <= r.x + r.width &&
                set_string!(buf, x, y, ini, stl(; fg = col_primary_hi()))
            x += textwidth(ini) + 1
        end
        sch = _start_chip(iss)
        if !isempty(sch) && x + textwidth(sch) <= r.x + r.width
            set_string!(buf, x, y, sch, stl(; fg = col_text_muted()))
            x += textwidth(sch) + 1
        end
        chip, overdue = _due_chip(iss)
        if !isempty(chip) && x + textwidth(chip) <= r.x + r.width
            set_string!(buf, x, y, chip, stl(; fg = overdue ? col_err() : col_text_muted()))
        end
    end
end

_short(s::AbstractString, n::Int) = ellipsize(s, n)

"Main board render (view router calls this when m.view === :board)."
function render_board!(m::AppModel, buf::Buffer, area::Rect)
    (area.width < 20 || area.height < 6) && return
    # Optional stats strip at the top (toggle `t`); grid renders below it.
    if m.show_stats && area.height >= STATS_HEIGHT + 6
        used = render_board_stats!(m, buf, Rect(area.x, area.y, area.width, STATS_HEIGHT))
        used > 0 && (area = Rect(area.x, area.y + used, area.width, area.height - used))
    end
    _render_board_grid!(m, buf, area)
end

"Column headers with WIP count/limit."
function _render_col_headers!(m::AppModel, buf::Buffer, x::Int, y::Int, col_w::Int)
    for (ci, st) in enumerate(BOARD_STATUSES)
        cx = x + (ci - 1) * col_w
        lim = _wip_limit(m, st)
        cnt = _col_count(m, st)
        hdr = lim > 0 ? "$(st) $(cnt)/$(lim)" : "$(st) $(cnt)"
        over = _is_over_wip(m, st)
        hstyle =
            over ? Style(; fg = col_err(), bold = true) :
            (
                ci == m.sel_col ? Style(; fg = col_primary_hi(), bold = true) :
                Style(; fg = col_primary())
            )
        set_string!(buf, cx, y, _short(hdr, col_w - 1), hstyle)
    end
end

# ── The bordered card grid ───────────────────────────────────────────────
const MODERN_CARD_H = 6                      # ╭ + key + 2 title lines + meta + ╰

"""
One bordered task card: rounded frame over a card-surface fill, with the left
edge tinted by priority. The selected card pops — bright border, raised
`col_surface_hi` background, a ▸ arrow on its frame, and (animations on) a
subtle border shimmer.
"""
function _render_card_modern!(
    m::AppModel,
    buf::Buffer,
    r::Rect,
    iss::Domain.Issue,
    selected::Bool,
)
    (r.width < 6 || r.height < 3) && return
    bg = selected ? col_surface_hi() : col_surface()
    border =
        selected ? Style(; fg = col_primary_hi(), bold = true) :
        Style(; fg = col_text_muted())
    render(Block(; border_style = border), r, buf)
    inner = Rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2)
    set_style!(buf, inner, Style(; bg = bg))
    _render_card!(m, buf, inner, iss, selected; bg = bg, inline_marker = false)
    if selected
        animations_enabled() &&
            border_shimmer!(buf, r, col_primary_hi(), m.tick; intensity = 0.25)
        set_string!(buf, r.x, r.y + 1, "▸", Style(; fg = col_primary_hi(), bold = true))
    else
        pstyle = Style(; fg = priority_color(iss.priority))
        for yy in (r.y + 1):(r.y + r.height - 2)
            set_char!(buf, r.x, yy, '│', pstyle)
        end
    end
end

"""
The swimlane × status card grid (board render minus the optional stats strip):
every swimlane is a rounded full-width panel with the lane name set into its
frame, status columns separated by joined rules, and each card a bordered
mini-panel (`_render_card_modern!`).
"""
function _render_board_grid!(m::AppModel, buf::Buffer, area::Rect)
    g = _clamp_selection!(m)
    ncols = length(BOARD_STATUSES)
    set_string!(
        buf,
        area.x,
        area.y,
        _short(_filter_line(m), area.width),
        Style(; fg = col_text_dim()),
    )

    grid_y = area.y + 1
    inner_x = area.x + 1                     # lane panels inset content by the frame
    inner_w = area.width - 2
    col_w = inner_w ÷ ncols                  # floor-divide: never overruns (finding U4)
    _render_col_headers!(m, buf, inner_x, grid_y, col_w)

    nlanes = length(g)
    avail_h = area.height - 2                # minus filter line + header row
    lane_h = max(MODERN_CARD_H + 2, avail_h ÷ max(1, nlanes))
    bottom_lim = area.y + area.height        # first row past the drawable area
    y = grid_y + 1
    frame = Style(; fg = col_text_muted())
    for (li, lane) in enumerate(g)
        lh = min(lane_h, bottom_lim - y)
        lh < 3 && break
        render(Block(; border_style = frame), Rect(area.x, y, area.width, lh), buf)
        # column separators joined into the lane frame
        for ci in 1:(ncols - 1)
            sx = inner_x + ci * col_w - 1
            set_char!(buf, sx, y, '┬', frame)
            for yy in (y + 1):(y + lh - 2)
                set_char!(buf, sx, yy, '│', frame)
            end
            set_char!(buf, sx, y + lh - 1, '┴', frame)
        end
        # lane title over the frame (drawn after the tees so it always reads clean)
        if m.swimlane_by !== :none && area.width > 6
            total = sum(length, lane.cols)
            tstyle =
                li == m.sel_lane ? Style(; fg = col_primary_hi(), bold = true) :
                Style(; fg = col_text_dim())
            set_string!(
                buf,
                area.x + 2,
                y,
                _short(" $(lane.name) ($(total)) ", area.width - 4),
                tstyle,
            )
        end
        # When the lane interior can't hold a full bordered card, degrade to the
        # flat card so the cursor card is never invisible while ops
        # still target it (finding U5; verifier W1). Bordered slots always fit
        # whole cards (max_cards = inner_h ÷ MODERN_CARD_H), so `hidden` counts
        # exactly the cards not drawn in either mode.
        inner_h = lh - 2
        bordered = inner_h >= MODERN_CARD_H
        card_h = bordered ? MODERN_CARD_H : clamp(inner_h, 1, 4)
        max_cards = max(1, inner_h ÷ card_h)
        for (ci, cell) in enumerate(lane.cols)
            cx = inner_x + (ci - 1) * col_w
            sel_here = (li == m.sel_lane && ci == m.sel_col)
            # scroll-follow: the cursor card is always rendered (finding U5)
            start = (sel_here && m.sel_idx > max_cards) ? (m.sel_idx - max_cards + 1) : 1
            last = min(length(cell), start + max_cards - 1)
            slot = 0
            for k in start:last
                cy = y + 1 + slot * card_h
                ch = min(card_h, y + lh - 1 - cy)          # clip to the lane interior
                ch < 1 && break
                sel = (sel_here && k == m.sel_idx)
                if bordered
                    _render_card_modern!(m, buf, Rect(cx, cy, col_w - 1, ch), cell[k], sel)
                else
                    _render_card!(m, buf, Rect(cx, cy, col_w - 1, ch), cell[k], sel)
                end
                slot += 1
            end
            hidden = length(cell) - last
            if hidden > 0
                my = y + 1 + slot * card_h
                my <= y + lh - 2 && set_string!(
                    buf,
                    cx,
                    my,
                    _short("+$(hidden) more", col_w - 1),
                    Style(; fg = col_text_muted()),
                )
            end
        end
        y += lh
    end
end

function _filter_line(m::AppModel)
    parts = String[]
    q = strip(text(m.search_input))
    isempty(q) || push!(parts, "search:'$(q)'")
    :mine in m.active_filters && push!(parts, "Mine")
    :high in m.active_filters && push!(parts, "High")
    :due_soon in m.active_filters && push!(parts, "DueSoon")
    :sprint in m.active_filters && push!(parts, "Sprint")
    m.label_filter === nothing || push!(parts, "label")
    sw = "lanes:$(m.swimlane_by)"
    bulk = isempty(m.selected_ids) ? "" : " • $(length(m.selected_ids)) selected"
    line =
        isempty(parts) ? "Filters: none • $(sw)$(bulk)" :
        "Filters: " * join(parts, " ") * " • $(sw)$(bulk)"
    sel = selected_issue(m)
    if sel !== nothing
        ds = String[]
        sel.start_date !== nothing && push!(ds, "S:$(sel.start_date)")
        sel.due_date !== nothing && push!(ds, "D:$(sel.due_date)")
        !isempty(ds) && (line *= " • " * join(ds, " "))
    end
    # Note (nit): _short() on caller may truncate date suffix at narrow widths;
    # selected date visibility relies on filter meta + wider terminals in practice.
    line
end
