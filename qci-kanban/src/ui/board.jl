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
        asp = Stores.active_sprint(m.boardstore; project_id = _scope(m))
        (asp !== nothing && iss.sprint_id == asp.id) || return false
    end
    if m.label_filter !== nothing
        (m.label_filter in iss.labels) || return false
    end
    q = strip(text(m.search_input))
    if !isempty(q)
        ql = lowercase(q)
        # Include asset_tag so shop-floor search by machine tag works (PR-M6).
        asset = iss.asset_tag === nothing ? "" : iss.asset_tag
        hay = lowercase(join([iss.title, iss.key, iss.description, asset, join(iss.labels, " ")], " "))
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
    issues = filter(i -> _passes_filters(m, i),
                    Stores.list_issues(m.boardstore; project_id = _scope(m)))
    # bucket: lane key -> (name, status -> issues)
    order = String[]
    names = Dict{String,String}()
    buckets = Dict{String,Vector{Domain.Issue}}()
    for iss in issues
        k, nm = _lane_of(m, iss)
        if !haskey(buckets, k)
            buckets[k] = Domain.Issue[]; names[k] = nm; push!(order, k)
        end
        push!(buckets[k], iss)
    end
    isempty(order) && return Lane[Lane("~all", m.swimlane_by === :none ? "All Issues" : "(no matches)",
                                       [Domain.Issue[] for _ in BOARD_STATUSES])]
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
    (1 <= lane <= length(g) && 1 <= col <= length(BOARD_STATUSES)) ? g[lane].cols[col] : Domain.Issue[]

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
        m.sel_col = max(1, m.sel_col - 1); m.sel_idx = 1
    elseif dir === :right
        m.sel_col = min(length(BOARD_STATUSES), m.sel_col + 1); m.sel_idx = 1
    elseif dir === :down
        cell = _cell(g, m.sel_lane, m.sel_col)
        if m.sel_idx < length(cell)
            m.sel_idx += 1
        elseif m.sel_lane < nl
            m.sel_lane += 1; m.sel_idx = 1
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
            m.sel_lane = li; m.sel_col = ci; m.sel_idx = k
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
    m.swimlane_by = SWIMLANE_MODES[mod1((i === nothing ? 1 : i) + 1, length(SWIMLANE_MODES))]
    m.sel_lane = 1; m.sel_col = 1; m.sel_idx = 1
    m.message = "Swimlanes: $(m.swimlane_by)"
    m
end

# ── WIP limits ──────────────────────────────────────────────────────────────
_col_count(m::AppModel, status::AbstractString) =
    length(Stores.list_issues(m.boardstore; status = status, project_id = _scope(m)))
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
function _notify_issue!(m::AppModel, iss::Domain.Issue, kind::Symbol, recipient_id, detail::AbstractString)
    email = _user_email(m, recipient_id)
    email === nothing && return
    actor = m.current_user === nothing ? "" : m.current_user.name
    ev = Domain.NotificationEvent(; kind = kind, recipient_email = email, actor_name = actor,
                                  issue_key = iss.key, issue_title = iss.title, detail = detail)
    Notify.notify!(m.notifier, ev)
end

_actor_id(m::AppModel) = m.current_user === nothing ? nothing : m.current_user.id

# ── Board ops (all mutate the store, then re-clamp selection) ───────────────
function _move_status!(m::AppModel, delta::Int)
    iss = selected_issue(m); iss === nothing && return m
    ci = findfirst(==(iss.status), BOARD_STATUSES)
    ci === nothing && return m
    nci = clamp(ci + delta, 1, length(BOARD_STATUSES))
    nci == ci && return m
    target = BOARD_STATUSES[nci]
    Stores.move_issue!(m.boardstore, iss.id; status = target)
    Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                         kind = :status_changed, detail = "$(iss.status) → $(target)")
    _notify_issue!(m, iss, :status_changed, iss.assignee_id, "$(iss.status) → $(target)")
    m.message = "$(iss.key) → $(target)"
    _warn_if_over_wip!(m, target)
    _select_issue!(m, iss.id)
    m
end

function _rank!(m::AppModel, delta::Int)
    iss = selected_issue(m); iss === nothing && return m
    Stores.rank_issue!(m.boardstore, iss.id; position = max(0, iss.position + delta))
    m.message = "Ranked $(iss.key)"
    _select_issue!(m, iss.id)
    m
end

function _assign_me!(m::AppModel)
    iss = selected_issue(m); iss === nothing && return m
    m.current_user === nothing && return m
    Stores.update_issue!(m.boardstore, iss.id; assignee_id = m.current_user.id)
    Stores.log_activity!(m.boardstore; issue_id = iss.id, actor_id = _actor_id(m),
                         kind = :assigned, detail = "assigned to $(m.current_user.name)")
    _notify_issue!(m, iss, :assigned, m.current_user.id, "")
    m.message = "$(iss.key) assigned to you"
    m
end

function _toggle_select!(m::AppModel)
    iss = selected_issue(m); iss === nothing && return m
    iss.id in m.selected_ids ? delete!(m.selected_ids, iss.id) : push!(m.selected_ids, iss.id)
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
        iss = Stores.get_issue(m.boardstore, id); iss === nothing && continue
        Stores.move_issue!(m.boardstore, id; status = target)
        Stores.log_activity!(m.boardstore; issue_id = id, actor_id = _actor_id(m),
                             kind = :status_changed, detail = "$(iss.status) → $(target)")
        _notify_issue!(m, iss, :status_changed, iss.assignee_id, "$(iss.status) → $(target)")
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
        iss = Stores.get_issue(m.boardstore, id); iss === nothing && continue
        Stores.update_issue!(m.boardstore, id; assignee_id = m.current_user.id)
        Stores.log_activity!(m.boardstore; issue_id = id, actor_id = _actor_id(m),
                             kind = :assigned, detail = "assigned to $(m.current_user.name)")
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
    m.sel_lane = 1; m.sel_col = 1; m.sel_idx = 1
    m.message = isempty(m.active_filters) && m.label_filter === nothing ? "Filters cleared" :
                "Filter: " * join(sort(collect(string.(m.active_filters))), ",")
    m
end

function _cycle_label_filter!(m::AppModel)
    lbls = Stores.list_labels(m.boardstore; project_id = _scope(m))
    if isempty(lbls)
        m.message = "No labels"; return m
    end
    ids = [l.id for l in lbls]
    cur = m.label_filter === nothing ? 0 : something(findfirst(==(m.label_filter), ids), 0)
    m.label_filter = cur >= length(ids) ? nothing : ids[cur + 1]
    nm = m.label_filter === nothing ? "off" :
         something(findfirst(l -> l.id == m.label_filter, lbls), 1) |> i -> lbls[i].name
    m.message = "Label filter: $(nm)"
    m.sel_lane = 1; m.sel_col = 1; m.sel_idx = 1
    m
end

# ── The bordered card grid ───────────────────────────────────────────────
const MODERN_CARD_H = 6                      # ╭ + key + 2 title lines + meta + ╰

# B2 move-chrome geometry (ASCII `[<]` / `[>]` inside modern card border)
const BOARD_BTN_MIN_W = 14
const BOARD_BTN_W = 3
const BOARD_BTN_GAP = 1
const BOARD_BTN_PAIR_W = 2 * BOARD_BTN_W + BOARD_BTN_GAP  # 7

# ═══════════════════════════ LAYOUT (B0/B2) ═════════════════════════════════
"""
One painted card cell on the board grid. Geometry matches `_render_board_grid!`
so paint and hit-test share a single snapshot. When `bordered` and outer width
≥ `BOARD_BTN_MIN_W`, move-chrome rects are filled (B2); flat / narrow cards
leave them `nothing`.
"""
struct BoardCardSlot
    rect::Rect
    lane::Int
    col::Int
    idx::Int                 # 1-based index within the status cell
    issue_id::String
    bordered::Bool
    prev_btn::Union{Nothing,Rect}
    next_btn::Union{Nothing,Rect}
    gap_btn::Union{Nothing,Rect}
    chrome::Union{Nothing,Rect}
end

"""
Snapshot of board card geometry for a given AppModel + content Rect.
Same geometry formulas as paint. **Not fully pure**: clamps `m.sel_*` via
`_clamp_selection!` (identical to render) so scroll-follow uses in-range
selection. Paint and hit-test both consume this builder.
"""
struct BoardLayout
    area::Rect                 # original body rect (pre-stats split input)
    grid_area::Rect            # after optional stats strip
    show_stats::Bool
    col_w::Int
    nlanes::Int
    slots::Vector{BoardCardSlot}
end

"""
Move-button rects for a modern card outer rect, or `nothing` when chrome is
hidden (flat / narrow / short). Formulas (design §4):

    by = r.y + r.height - 2
    bx_next = r.x + r.width - 2 - (BOARD_BTN_W - 1)
    bx_prev = bx_next - BOARD_BTN_GAP - BOARD_BTN_W
"""
function _board_btn_rects(r::Rect; bordered::Bool = true)
    (!bordered || r.width < BOARD_BTN_MIN_W || r.height < MODERN_CARD_H) &&
        return nothing
    by = r.y + r.height - 2
    bx_next = r.x + r.width - 2 - (BOARD_BTN_W - 1)
    bx_prev = bx_next - BOARD_BTN_GAP - BOARD_BTN_W
    prev_btn = Rect(bx_prev, by, BOARD_BTN_W, 1)
    next_btn = Rect(bx_next, by, BOARD_BTN_W, 1)
    gap_btn  = Rect(bx_prev + BOARD_BTN_W, by, BOARD_BTN_GAP, 1)
    chrome   = Rect(bx_prev, by, BOARD_BTN_PAIR_W, 1)
    return (prev_btn = prev_btn, next_btn = next_btn, gap_btn = gap_btn, chrome = chrome)
end

"""
    board_layout(m, area) -> BoardLayout

Encode stats strip, filter/header rows, lane heights, scroll-follow start,
bordered vs flat cards, each visible card `Rect`, and B2 move-chrome rects.

**Side effect:** calls `_clamp_selection!(m)` (same as render) so scroll-follow
uses in-range `sel_*`. Not safe for speculative “what-if” layouts without
restoring selection.
"""
function board_layout(m::AppModel, area::Rect)::BoardLayout
    show_stats = m.show_stats && area.height >= STATS_HEIGHT + 6
    grid_area = show_stats ?
        Rect(area.x, area.y + STATS_HEIGHT, area.width, area.height - STATS_HEIGHT) :
        Rect(area.x, area.y, area.width, area.height)

    g = _clamp_selection!(m)
    ncols = length(BOARD_STATUSES)
    nlanes = length(g)
    if grid_area.width < 4 || grid_area.height < 1
        return BoardLayout(area, grid_area, show_stats, 0, nlanes, BoardCardSlot[])
    end

    inner_x = grid_area.x + 1
    inner_w = grid_area.width - 2
    col_w = max(0, inner_w ÷ ncols)
    board_total = sum(sum(length, lane.cols; init = 0) for lane in g; init = 0)
    avail_h = grid_area.height - 2                # minus filter line + header row
    lane_h = max(MODERN_CARD_H + 2, avail_h ÷ max(1, nlanes))
    bottom_lim = grid_area.y + grid_area.height
    y = grid_area.y + 2                           # after filter (y0) + headers (y1)
    if board_total == 0 && y < bottom_lim
        y += 1                                    # empty-board hint row
    end

    slots = BoardCardSlot[]
    for (li, lane) in enumerate(g)
        lh = min(lane_h, bottom_lim - y)
        lh < 3 && break
        inner_h = lh - 2
        bordered = inner_h >= MODERN_CARD_H
        card_h = bordered ? MODERN_CARD_H : clamp(inner_h, 1, 4)
        max_cards = max(1, inner_h ÷ max(1, card_h))
        for (ci, cell) in enumerate(lane.cols)
            cx = inner_x + (ci - 1) * col_w
            sel_here = (li == m.sel_lane && ci == m.sel_col)
            # scroll-follow: the cursor card is always included (finding U5)
            start = (sel_here && m.sel_idx > max_cards) ? (m.sel_idx - max_cards + 1) : 1
            last = min(length(cell), start + max_cards - 1)
            slot_i = 0
            for k in start:last
                cy = y + 1 + slot_i * card_h
                ch = min(card_h, y + lh - 1 - cy)   # clip to the lane interior
                ch < 1 && break
                r = Rect(cx, cy, max(0, col_w - 1), ch)
                btns = _board_btn_rects(r; bordered = bordered)
                push!(slots, BoardCardSlot(
                    r, li, ci, k, cell[k].id, bordered,
                    btns === nothing ? nothing : btns.prev_btn,
                    btns === nothing ? nothing : btns.next_btn,
                    btns === nothing ? nothing : btns.gap_btn,
                    btns === nothing ? nothing : btns.chrome))
                slot_i += 1
            end
        end
        y += lh
    end
    BoardLayout(area, grid_area, show_stats, col_w, nlanes, slots)
end

"""
Armed / hot target for move chrome under the 1002 press-drag-release path (K8).
Stored in `AppModel.board_hover::Any` (app.jl included before board.jl — K12).
"""
struct BoardHoverTarget
    kind::Symbol          # :move_prev | :move_next | :none (armed but not over a button)
    issue_id::String
    armed::Bool
end

_clear_board_mouse_ui!(m::AppModel) = (m.board_hover = nothing; m)

_board_arm_active(m::AppModel) = begin
    h = m.board_hover
    h === nothing && return false
    # NamedTuple or BoardHoverTarget both expose .armed
    try
        return h.armed === true
    catch
        return false
    end
end

function _board_is_hot(m::AppModel, issue_id::AbstractString, kind::Symbol)
    h = m.board_hover
    h === nothing && return false
    try
        return h.kind === kind && h.issue_id == issue_id
    catch
        return false
    end
end

# ═══════════════════════════ HIT-TEST + MOUSE (B1/B2) ═══════════════════════
"""
Hit kinds for pure board mouse hit-testing. Priority: move buttons → gap chrome
band → card body → other chrome.
"""
@enum BoardHitKind begin
    board_hit_none
    board_hit_card_body      # select / open-detail
    board_hit_move_prev      # [<]
    board_hit_move_next      # [>]
    board_hit_move_chrome    # gap / non-button chrome band — no-op
    board_hit_chrome         # headers, filter line, lane frame, stats
end

"""Result of `board_hit_test`. Lane/col/idx/issue_id set when a card is hit."""
struct BoardHit
    kind::BoardHitKind
    lane::Union{Nothing,Int}
    col::Union{Nothing,Int}
    idx::Union{Nothing,Int}
    issue_id::Union{Nothing,String}
end

const _BOARD_HIT_NONE = BoardHit(board_hit_none, nothing, nothing, nothing, nothing)

"""
    board_hit_test(layout, x, y) -> BoardHit

Pure hit-test against a `BoardLayout` snapshot. Coordinates are absolute
terminal cells (same space as `MouseEvent.x/y` and `layout.area`). Uses
`Base.contains` for rect membership — does not invent a parallel geometry.
"""
function board_hit_test(layout::BoardLayout, x::Int, y::Int)::BoardHit
    area = layout.area
    (area.width < 1 || area.height < 1) && return _BOARD_HIT_NONE
    Base.contains(area, x, y) || return _BOARD_HIT_NONE

    # Priority: specific buttons > gap chrome band > card body > other chrome
    for s in layout.slots
        if s.prev_btn !== nothing && Base.contains(s.prev_btn, x, y)
            return BoardHit(board_hit_move_prev, s.lane, s.col, s.idx, s.issue_id)
        end
        if s.next_btn !== nothing && Base.contains(s.next_btn, x, y)
            return BoardHit(board_hit_move_next, s.lane, s.col, s.idx, s.issue_id)
        end
        if s.chrome !== nothing && Base.contains(s.chrome, x, y)
            # gap (or band padding): never body / never open detail
            return BoardHit(board_hit_move_chrome, s.lane, s.col, s.idx, s.issue_id)
        end
        if Base.contains(s.rect, x, y)
            return BoardHit(board_hit_card_body, s.lane, s.col, s.idx, s.issue_id)
        end
    end
    return BoardHit(board_hit_chrome, nothing, nothing, nothing, nothing)
end

"""
Left-press on card body: first press selects (cursor only — K13, no bulk
`selected_ids` change); second press on the already-selected card opens detail
via `_open_card_detail!` (same as `v`).
"""
function _board_body_press!(m::AppModel, hit::BoardHit)
    hit.issue_id === nothing && return m
    cur = selected_issue(m)
    already = cur !== nothing && cur.id == hit.issue_id
    if already
        _clear_board_mouse_ui!(m)
        return _open_card_detail!(m)
    else
        # Cursor only — do NOT touch selected_ids (K13)
        _select_issue!(m, hit.issue_id)
        return m
    end
end

"""Drag while armed: update hot button kind from hit (do not fire)."""
function _board_update_arm_from_hit!(m::AppModel, hit::BoardHit)
    arm = m.board_hover
    arm === nothing && return m
    id = try arm.issue_id catch; return m end
    if hit.kind === board_hit_move_prev && hit.issue_id == id
        m.board_hover = BoardHoverTarget(:move_prev, id, true)
    elseif hit.kind === board_hit_move_next && hit.issue_id == id
        m.board_hover = BoardHoverTarget(:move_next, id, true)
    else
        # Off the armed issue's buttons: keep armed, drop hot paint
        m.board_hover = BoardHoverTarget(:none, id, true)
    end
    m
end

"""Release while armed: fire `_move_status!` only if still over same button kind."""
function _board_commit_or_cancel_arm!(m::AppModel, hit::BoardHit)
    arm = m.board_hover
    arm === nothing && return m
    kind = try arm.kind catch; m.board_hover = nothing; return m end
    id = arm.issue_id
    m.board_hover = nothing
    ok = (kind === :move_prev && hit.kind === board_hit_move_prev && hit.issue_id == id) ||
         (kind === :move_next && hit.kind === board_hit_move_next && hit.issue_id == id)
    ok || return m
    _select_issue!(m, id)
    _move_status!(m, kind === :move_prev ? -1 : +1)
    m
end

"""
    _handle_board_mouse!(m, evt)

Body: left-press select / second-press open detail.
Move chrome (B2, 1002 path): press arms hot state; drag updates hot target;
release on same button kind fires `_move_status!` (ungated — K7); release off
cancels. Gap (`board_hit_move_chrome`) is a no-op (never opens detail — K11).
Free-pointer hover (B3 / DECSET 1003) is **not** implemented.
"""
function _handle_board_mouse!(m::AppModel, evt::MouseEvent)
    area = m.board_last_area
    (area.width < 1 || area.height < 1) && return m
    lay = board_layout(m, area)
    hit = board_hit_test(lay, evt.x, evt.y)

    # ── MVP 1002 path: arm / drag / release for move chrome ──
    if _board_arm_active(m)
        if evt.button === mouse_left && evt.action === mouse_drag
            return _board_update_arm_from_hit!(m, hit)
        elseif evt.button === mouse_left && evt.action === mouse_release
            return _board_commit_or_cancel_arm!(m, hit)
        elseif evt.button === mouse_left && evt.action === mouse_press
            # rare synthetic: commit previous then fall through to new press
            _board_commit_or_cancel_arm!(m, hit)
            # fall through
        else
            return m
        end
    end

    if evt.button === mouse_left && evt.action === mouse_press
        if hit.kind === board_hit_move_prev || hit.kind === board_hit_move_next
            hit.issue_id === nothing && return m
            _select_issue!(m, hit.issue_id)
            kind = hit.kind === board_hit_move_prev ? :move_prev : :move_next
            m.board_hover = BoardHoverTarget(kind, hit.issue_id, true)
            return m
        elseif hit.kind === board_hit_move_chrome
            return m   # gap: no-op (do not open detail — K11)
        elseif hit.kind === board_hit_card_body
            return _board_body_press!(m, hit)
        end
    end
    m
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function _wrap_title(t::AbstractString, w::Int, maxlines::Int)
    w <= 0 && return String[]
    words = split(t)
    lines = String[]; cur = ""
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
    if !isempty(lines) && textwidth(join(words, " ")) > sum(textwidth, lines) + length(lines) - 1
        last = lines[end]
        lines[end] = textwidth(last) > w - 1 ? fit_width(last, max(1, w - 1)) * "…" : last * "…"
    end
    lines
end

_priority_glyph(p::AbstractString) = p == "High" ? "▲" : p == "Low" ? "▼" : "■"

function _due_chip(iss::Domain.Issue)
    iss.due_date === nothing && return ("", false)
    overdue = iss.due_date < Dates.today() && iss.status != "Done"
    ("▣" * Dates.format(iss.due_date, "u-dd"), overdue)
end

"""
Render one rich card's content into a rect; returns nothing. Selected/bulk
styling applied. `bg` threads a card-surface background through every style
(the modern bordered card fills its interior); `inline_marker=false` drops the
leading ▸/space (the modern card draws its arrow on the frame instead).
`right_reserve` shortens **only the meta chip line** (B2 move buttons).
"""
function _render_card!(m::AppModel, buf::Buffer, r::Rect, iss::Domain.Issue, selected::Bool;
                       bg = nothing, inline_marker::Bool = true, right_reserve::Int = 0)
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
        set_string!(buf, gx, r.y, _priority_glyph(iss.priority), stl(; fg = priority_color(iss.priority)))
        pxs = gx + 2
        isempty(pts) || pxs + length(pts) > r.x + r.width || set_string!(buf, pxs, r.y, pts, stl(; fg = col_text_dim()))
    end
    # line 2-3: wrapped title (full width — buttons live on meta row only)
    if r.height >= 2
        tlines = _wrap_title(iss.title, r.width, min(2, r.height - 1))
        for (i, ln) in enumerate(tlines)
            set_string!(buf, r.x, r.y + i, ln, stl(; fg = col_text()))
        end
    end
    # line 4: epic / work_type / asset chips / labels / assignee / due
    # Meta-only right_reserve leaves room for ASCII move buttons (B2).
    if r.height >= 4
        y = r.y + 3
        x = r.x
        meta_right = r.x + r.width - max(0, right_reserve)
        if iss.epic_id !== nothing
            tag = "◆" * _short(_epic_name(m, iss.epic_id), 7)
            tw = textwidth(tag)
            if x + tw <= meta_right
                set_string!(buf, x, y, tag, stl(; fg = epic_color(iss.epic_id)))
                x += tw + 1
            end
        end
        if iss.work_type !== nothing
            wt = "⟨" * iss.work_type * "⟩"
            tw = textwidth(wt)
            if x + tw <= meta_right
                set_string!(buf, x, y, wt, stl(; fg = col_warn()))
                x += tw + 1
            end
        end
        if iss.asset_tag !== nothing
            avail = meta_right - x
            at = _asset_chip(iss.asset_tag; max_w = avail)
            if !isempty(at)
                set_string!(buf, x, y, at, stl(; fg = col_primary_hi()))
                x += textwidth(at) + 1
            end
        end
        for lid in iss.labels
            chip = "•"
            tw = textwidth(chip)
            if x + tw <= meta_right
                set_string!(buf, x, y, chip, stl(; fg = col_warn()))
                x += tw
            end
        end
        if iss.assignee_id !== nothing
            ini = _initials(_user_name(m, iss.assignee_id))
            tw = textwidth(ini)
            if x + tw <= meta_right
                set_string!(buf, x, y, ini, stl(; fg = col_primary_hi()))
                x += tw + 1
            end
        end
        chip, overdue = _due_chip(iss)
        tw = textwidth(chip)
        if !isempty(chip) && x + tw <= meta_right
            set_string!(buf, x, y, chip, stl(; fg = overdue ? col_err() : col_text_muted()))
        end
    end
end

"""
    _asset_chip(tag; max_w) -> String

Asset meta chip (`⚙` + tag) fitted to `max_w` display columns.

U+2699 GEAR is *ambiguous width*: Julia `textwidth` often reports 1 while many
terminals paint it as 2 columns. Reserve **2 glyph columns** (pad when needed)
plus **1 gap column** so the tag sits clear of the icon — especially on selected
cards next to `[<]`/`[>]`.
"""
function _asset_chip(tag::AbstractString; max_w::Int)
    max_w < 2 && return ""
    glyph = "⚙"
    gw = 2                                      # forced budget for ambiguous emoji
    gap = 1                                     # breathing room before tag text
    prefix_w = gw + gap
    pad_n = max(0, gw - textwidth(glyph))
    prefix = glyph * " "^pad_n * " "^gap
    body_w = max_w - prefix_w
    # ellipsize needs ≥2 cols for "x…"; smaller budgets keep prefix only
    body_w < 2 && return fit_width(prefix, max_w)
    out = prefix * _short(String(tag), body_w)
    textwidth(out) <= max_w ? out : fit_width(prefix, max_w)
end

"""
Paint ASCII `[<]` / `[>]` on the meta row inside a modern card border.
Hot state when `board_hover` matches kind+issue_id (armed 1002 path).
Edge statuses dim with `col_text_muted`. No Unicode arrows.
"""
function _paint_card_move_buttons!(m::AppModel, buf::Buffer, r::Rect, iss::Domain.Issue,
                                   selected::Bool; bordered::Bool = true)
    btns = _board_btn_rects(r; bordered = bordered)
    btns === nothing && return
    card_bg = selected ? col_surface_hi() : col_surface()
    for (btn_r, label, kind) in ((btns.prev_btn, "[<]", :move_prev),
                                 (btns.next_btn, "[>]", :move_next))
        hot = _board_is_hot(m, iss.id, kind)
        edge = (kind === :move_prev && iss.status == BOARD_STATUSES[1]) ||
               (kind === :move_next && iss.status == BOARD_STATUSES[end])
        st = if hot
            Style(; fg = col_bg(), bg = col_primary_hi(), bold = true)
        elseif edge
            Style(; fg = col_text_muted(), bg = card_bg)
        else
            Style(; fg = col_text_dim(), bg = card_bg)
        end
        set_string!(buf, btn_r.x, btn_r.y, label, st)
    end
end

_short(s::AbstractString, n::Int) = ellipsize(s, n)

"Main board render (view router calls this when m.view === :board)."
function render_board!(m::AppModel, buf::Buffer, area::Rect)
    # B0: cache area for future mouse hit-tests (B1/B2); zero default on AppModel.
    m.board_last_area = area
    (area.width < 20 || area.height < 6) && return
    # Single layout snapshot: paint cards exclusively from layout.slots (acceptance A).
    layout = board_layout(m, area)
    # Invariant: show_stats ⇒ area.width ≥ 20 ⇒ render_board_stats! returns STATS_HEIGHT
    # (never 0). Layout insets by STATS_HEIGHT; must stay aligned with used height.
    if layout.show_stats
        render_board_stats!(m, buf, Rect(area.x, area.y, area.width, STATS_HEIGHT))
    end
    _render_board_grid!(m, buf, layout)
end

"Column headers with WIP count/limit."
function _render_col_headers!(m::AppModel, buf::Buffer, x::Int, y::Int, col_w::Int)
    for (ci, st) in enumerate(BOARD_STATUSES)
        cx = x + (ci - 1) * col_w
        lim = _wip_limit(m, st)
        cnt = _col_count(m, st)
        hdr = lim > 0 ? "$(st) $(cnt)/$(lim)" : "$(st) $(cnt)"
        over = _is_over_wip(m, st)
        hstyle = over ? Style(; fg = col_err(), bold = true) :
                 (ci == m.sel_col ? Style(; fg = col_primary_hi(), bold = true) : Style(; fg = col_primary()))
        set_string!(buf, cx, y, _short(hdr, col_w - 1), hstyle)
    end
end

"""
One bordered task card: rounded frame over a card-surface fill, with the left
edge tinted by priority. The selected card pops — bright border, raised
`col_surface_hi` background, a ▸ arrow on its frame, and (animations on) a
subtle border shimmer.
"""
function _render_card_modern!(m::AppModel, buf::Buffer, r::Rect, iss::Domain.Issue, selected::Bool)
    (r.width < 6 || r.height < 3) && return
    bg = selected ? col_surface_hi() : col_surface()
    border = selected ? Style(; fg = col_primary_hi(), bold = true) : Style(; fg = col_text_muted())
    render(Block(; border_style = border), r, buf)
    inner = Rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2)
    set_style!(buf, inner, Style(; bg = bg))
    # Meta-only reserve for `[<]`/`[>]` when chrome is wide enough (K3).
    show_btns = r.width >= BOARD_BTN_MIN_W && r.height >= MODERN_CARD_H
    meta_reserve = show_btns ? BOARD_BTN_PAIR_W + 1 : 0
    _render_card!(m, buf, inner, iss, selected; bg = bg, inline_marker = false,
                  right_reserve = meta_reserve)
    _paint_card_move_buttons!(m, buf, r, iss, selected; bordered = true)
    if selected
        animations_enabled() && border_shimmer!(buf, r, col_primary_hi(), m.tick; intensity = 0.25)
        set_string!(buf, r.x, r.y + 1, "▸", Style(; fg = col_primary_hi(), bold = true))
    else
        pstyle = Style(; fg = priority_color(iss.priority))
        for yy in (r.y + 1):(r.y + r.height - 2)
            set_char!(buf, r.x, yy, '│', pstyle)
        end
    end
end

"""
The swimlane × status card grid from a `BoardLayout` snapshot (board render
minus the optional stats strip). Lane frames / headers use shared lane metrics;
**"+N more" and cards derive from `layout.slots`** (no second scroll-window formula).
"""
function _render_board_grid!(m::AppModel, buf::Buffer, layout::BoardLayout)
    area = layout.grid_area
    g = board_grid(m)                         # selection already clamped in board_layout
    ncols = length(BOARD_STATUSES)
    col_w = layout.col_w
    set_string!(buf, area.x, area.y, _short(_filter_line(m), area.width), Style(; fg = col_text_dim()))

    grid_y = area.y + 1
    inner_x = area.x + 1                     # lane panels inset content by the frame
    _render_col_headers!(m, buf, inner_x, grid_y, col_w)

    nlanes = length(g)
    # Total cards across the filtered grid (empty-state copy when zero).
    board_total = sum(sum(length, lane.cols; init = 0) for lane in g; init = 0)
    avail_h = area.height - 2                # minus filter line + header row
    lane_h = max(MODERN_CARD_H + 2, avail_h ÷ max(1, nlanes))
    bottom_lim = area.y + area.height        # first row past the drawable area
    y = grid_y + 1
    # Empty production board (PR-M3 / design §4.7): clear create path above lanes.
    if board_total == 0 && y < bottom_lim
        empty_msg = "No work orders — press [n] to create"
        set_string!(buf, area.x, y, _short(empty_msg, area.width),
                    Style(; fg = col_text_dim()))
        y += 1
    end
    # Index slots by (lane, col) once — drives +N more without re-deriving the window.
    slots_by_cell = Dict{Tuple{Int,Int},Vector{BoardCardSlot}}()
    for s in layout.slots
        push!(get!(() -> BoardCardSlot[], slots_by_cell, (s.lane, s.col)), s)
    end
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
            tstyle = li == m.sel_lane ? Style(; fg = col_primary_hi(), bold = true) :
                                        Style(; fg = col_text_dim())
            set_string!(buf, area.x + 2, y, _short(" $(lane.name) ($(total)) ", area.width - 4), tstyle)
        end
        # "+N more" from layout.slots (last shown idx + bottom of last slot rect).
        for (ci, cell) in enumerate(lane.cols)
            col_slots = get(slots_by_cell, (li, ci), BoardCardSlot[])
            isempty(col_slots) && continue
            last_idx = maximum(s.idx for s in col_slots)
            hidden = length(cell) - last_idx
            hidden <= 0 && continue
            bot = maximum(s.rect.y + s.rect.height for s in col_slots)
            my = bot
            cx = col_slots[1].rect.x
            my <= y + lh - 2 &&
                set_string!(buf, cx, my, _short("+$(hidden) more", col_w - 1), Style(; fg = col_text_muted()))
        end
        y += lh
    end
    # Acceptance A: paint cards exclusively from layout.slots.
    # Resolve Issue from the in-memory grid by (lane,col,idx) — no N× store get_issue.
    for s in layout.slots
        cell = _cell(g, s.lane, s.col)
        (1 <= s.idx <= length(cell)) || continue
        iss = cell[s.idx]
        iss.id == s.issue_id || continue      # layout/grid must agree
        sel = (s.lane == m.sel_lane && s.col == m.sel_col && s.idx == m.sel_idx)
        if s.bordered
            _render_card_modern!(m, buf, s.rect, iss, sel)
        else
            _render_card!(m, buf, s.rect, iss, sel)
        end
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
    isempty(parts) ? "Filters: none • $(sw)$(bulk)" : "Filters: " * join(parts, " ") * " • $(sw)$(bulk)"
end
