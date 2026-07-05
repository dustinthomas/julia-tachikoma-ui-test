# ═══════════════════════════════════════════════════════════════════════
# ui/gantt.jl — Phase 4 Gantt timeline view.
#
# Rows = issues that have a start_date and/or due_date, grouped under epic
# header rows. Bars span start_date→due_date rendered with `BlockCanvas`
# (quadrant blocks → ordinary text cells, so fully TestBackend-assertable);
# single-date issues render as a diamond. A today marker is a vertical line;
# sprint start→end are shaded bands with the sprint name. `z` toggles the
# week/month scale, h/l scroll the window, j/k select a row, Enter opens the
# card detail modal.
#
# The date→column geometry lives in small PURE functions with direct unit
# tests (`gantt_col_for_date`, `gantt_bar_extent`, `gantt_point_col`,
# `gantt_window_end`) kept separate from rendering. No raw ColorRGB literals —
# color goes through Theming accessors (test-enforced).
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates

# ── Scale geometry (pure) ───────────────────────────────────────────────────
"Days represented by one chart column at the given scale."
gantt_days_per_col(scale::Symbol)::Int = scale === :month ? 7 : 1

"Days the window scrolls per h/l press at the given scale."
gantt_scroll_days(scale::Symbol)::Int = scale === :month ? 28 : 7

"0-based column offset of date `d` from the window's left edge (floored)."
gantt_col_for_date(win_start::Date, dpc::Int, d::Date)::Int =
    fld(Dates.value(d) - Dates.value(win_start), dpc)

"Last date visible in a window of `ncols` columns."
gantt_window_end(win_start::Date, dpc::Int, ncols::Int)::Date =
    win_start + Day(dpc * max(ncols, 1) - 1)

"""
    gantt_bar_extent(win_start, dpc, sd, ed, ncols) -> (c0, c1) | nothing

Inclusive column span of a bar from `sd`→`ed` (order-insensitive), clamped to
the visible `[0, ncols-1]` window. Returns `nothing` when the bar lies wholly
outside the window.
"""
function gantt_bar_extent(win_start::Date, dpc::Int, sd::Date, ed::Date, ncols::Int)
    lo, hi = sd <= ed ? (sd, ed) : (ed, sd)
    c0 = gantt_col_for_date(win_start, dpc, lo)
    c1 = gantt_col_for_date(win_start, dpc, hi)
    (c1 < 0 || c0 > ncols - 1) && return nothing
    (clamp(c0, 0, ncols - 1), clamp(c1, 0, ncols - 1))
end

"""
    gantt_point_col(win_start, dpc, d, ncols) -> Int | nothing

Column of a single date `d` (a diamond / the today marker), or `nothing` when
`d === nothing` or falls outside the visible window.
"""
function gantt_point_col(win_start::Date, dpc::Int, d, ncols::Int)
    d === nothing && return nothing
    c = gantt_col_for_date(win_start, dpc, d)
    (c < 0 || c > ncols - 1) && return nothing
    c
end

# ── Rows (pure projection of the store) ─────────────────────────────────────
struct GanttRow
    kind::Symbol                       # :epic | :issue
    label::String
    issue::Union{Domain.Issue,Nothing}
    color_key::String                  # epic id ("" = no epic) for row coloring
end

"Issues that carry at least one date (start or due) — the only ones plotted."
gantt_dated_issues(m::AppModel)::Vector{Domain.Issue} =
    [i for i in Stores.list_issues(m.boardstore)
     if i.start_date !== nothing || i.due_date !== nothing]

_gantt_anchor(i::Domain.Issue)::Date = i.start_date === nothing ? i.due_date : i.start_date
_gantt_sort(v::Vector{Domain.Issue}) = sort(v; by = i -> (_gantt_anchor(i), i.key))

"""
    gantt_rows(m) -> Vector{GanttRow}

Epic header rows in `list_epics` order (then a trailing "No Epic" group),
each followed by its dated issues sorted by anchor date then key.
"""
function gantt_rows(m::AppModel)::Vector{GanttRow}
    groups = Dict{String,Vector{Domain.Issue}}()
    for i in gantt_dated_issues(m)
        k = i.epic_id === nothing ? "~none" : i.epic_id
        push!(get!(groups, k, Domain.Issue[]), i)
    end
    rows = GanttRow[]
    for e in Stores.list_epics(m.boardstore)
        haskey(groups, e.id) || continue
        push!(rows, GanttRow(:epic, e.name, nothing, e.id))
        for iss in _gantt_sort(groups[e.id])
            push!(rows, GanttRow(:issue, "$(iss.key) $(iss.title)", iss, e.id))
        end
    end
    if haskey(groups, "~none")
        push!(rows, GanttRow(:epic, "No Epic", nothing, ""))
        for iss in _gantt_sort(groups["~none"])
            push!(rows, GanttRow(:issue, "$(iss.key) $(iss.title)", iss, ""))
        end
    end
    rows
end

"Just the issue rows, in display order (the j/k selection index space)."
gantt_issue_rows(m::AppModel)::Vector{GanttRow} = [r for r in gantt_rows(m) if r.kind === :issue]

"""
    gantt_sprint_bands(m, win_start, dpc, ncols) -> Vector{(name, c0, c1)}

Visible sprint bands: for each sprint with both start and end dates, the
clamped column span within the window.
"""
function gantt_sprint_bands(m::AppModel, win_start::Date, dpc::Int, ncols::Int)
    bands = Tuple{String,Int,Int}[]
    for s in Stores.list_sprints(m.boardstore)
        (s.start_date === nothing || s.end_date === nothing) && continue
        ext = gantt_bar_extent(win_start, dpc, s.start_date, s.end_date, ncols)
        ext === nothing && continue
        push!(bands, (s.name, ext[1], ext[2]))
    end
    bands
end

# ── Initialisation + actions ────────────────────────────────────────────────
"Set the window to start at the earliest dated issue (or today), week scale."
function _gantt_init!(m::AppModel)
    dates = Date[]
    for i in gantt_dated_issues(m)
        i.start_date === nothing || push!(dates, i.start_date)
        i.due_date === nothing || push!(dates, i.due_date)
    end
    m.gantt_start = isempty(dates) ? Dates.today() : minimum(dates)
    m.gantt_scale = :week
    m.gantt_sel = 1
    m
end

function _gantt_scroll!(m::AppModel, dir::Int)
    m.gantt_start += Day(dir * gantt_scroll_days(m.gantt_scale))
    m.message = "Gantt window from $(m.gantt_start)"
    m
end

function _gantt_row!(m::AppModel, delta::Int)
    n = length(gantt_issue_rows(m))
    n == 0 && return m
    m.gantt_sel = clamp(m.gantt_sel + delta, 1, n)
    m
end

function _gantt_zoom!(m::AppModel)
    m.gantt_scale = m.gantt_scale === :week ? :month : :week
    m.message = "Gantt scale: $(m.gantt_scale)"
    m
end

function _gantt_selected_issue(m::AppModel)
    irows = gantt_issue_rows(m)
    isempty(irows) && return nothing
    irows[clamp(m.gantt_sel, 1, length(irows))].issue
end

_gantt_open_detail!(m::AppModel) = _open_detail_issue!(m, _gantt_selected_issue(m))

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function render_gantt!(m::AppModel, buf::Buffer, area::Rect)
    if area.width < 24 || area.height < 6
        set_string!(buf, area.x, area.y,
                    _short("Gantt needs a bigger window", area.width), Style(; fg = col_text_dim()))
        return
    end
    dpc = gantt_days_per_col(m.gantt_scale)
    left_w = clamp(area.width ÷ 3, 14, 22)
    chart_x = area.x + left_w
    ncols = area.width - left_w
    win_start = m.gantt_start
    win_end = gantt_window_end(win_start, dpc, ncols)
    scale_lbl = m.gantt_scale === :month ? "month" : "week"
    set_string!(buf, area.x, area.y,
                _short("GANTT — $(win_start) → $(win_end)  [$(scale_lbl)]", area.width),
                Style(; fg = col_primary(), bold = true))

    rows = gantt_rows(m)
    if isempty(rows)
        set_string!(buf, area.x, area.y + 2, _short("No scheduled issues", area.width),
                    Style(; fg = col_text_dim()))
        return
    end

    # Sprint bands live on the row directly under the header.
    band_y = area.y + 1
    for (nm, c0, c1) in gantt_sprint_bands(m, win_start, dpc, ncols)
        for cc in c0:c1
            xx = chart_x + cc
            xx <= area.x + area.width - 1 && set_string!(buf, xx, band_y, "░", Style(; fg = col_text_muted()))
        end
        set_string!(buf, chart_x + c0, band_y, _short(nm, ncols - c0),
                    Style(; fg = col_text_dim(), underline = true))
    end

    grid_y0 = area.y + 2
    nshow = min(length(rows), area.height - 2)
    canvas = BlockCanvas(ncols, max(1, nshow); style = Style(; fg = col_primary()))
    diamonds = Tuple{Int,Int,Any}[]
    sel_issue = _gantt_selected_issue(m)

    # Scroll the row window so the selected issue is always drawn (U5): without
    # this a j-navigated selection below the fold is invisible yet actionable.
    row_start = 1
    if sel_issue !== nothing
        sri = findfirst(r -> r.kind === :issue && r.issue !== nothing && r.issue.id == sel_issue.id, rows)
        (sri !== nothing && sri > nshow) && (row_start = sri - nshow + 1)
    end

    for i in 1:nshow
        ri = row_start + i - 1
        ri > length(rows) && break
        row = rows[ri]
        rowy = grid_y0 + (i - 1)
        if row.kind === :epic
            ecol = isempty(row.color_key) ? col_primary() : epic_color(row.color_key)
            set_string!(buf, area.x, rowy, _short("▬ " * row.label, left_w - 1), Style(; fg = ecol, bold = true))
        else
            iss = row.issue
            selected = sel_issue !== nothing && iss.id == sel_issue.id
            lstyle = selected ? sel_style() : Style(; fg = col_text())
            set_string!(buf, area.x, rowy, _short((selected ? "▸ " : "  ") * row.label, left_w - 1), lstyle)
            if iss.start_date !== nothing && iss.due_date !== nothing
                ext = gantt_bar_extent(win_start, dpc, iss.start_date, iss.due_date, ncols)
                if ext !== nothing
                    c0, c1 = ext
                    for dx in (2 * c0):(2 * c1 + 1), dy in (2 * (i - 1)):(2 * (i - 1) + 1)
                        set_point!(canvas, dx, dy)
                    end
                end
            else
                d = iss.start_date === nothing ? iss.due_date : iss.start_date
                col = gantt_point_col(win_start, dpc, d, ncols)
                col === nothing || push!(diamonds, (chart_x + col, rowy, priority_color(iss.priority)))
            end
        end
    end

    render(canvas, Rect(chart_x, grid_y0, ncols, max(1, nshow)), buf)

    for (dx, dy, dcol) in diamonds
        set_char!(buf, dx, dy, '◆', Style(; fg = dcol))
    end

    # Today marker — a distinct vertical line spanning the band + grid rows.
    tcol = gantt_point_col(win_start, dpc, Dates.today(), ncols)
    if tcol !== nothing
        set_char!(buf, chart_x + tcol, band_y, '▼', Style(; fg = col_primary_hi(), bold = true))
        for i in 1:nshow
            set_char!(buf, chart_x + tcol, grid_y0 + (i - 1), '│', Style(; fg = col_primary_hi(), bold = true))
        end
    end
end
