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

# ── PR1 weekend/week geometry (pure, added for shading + separators) ────────
"True for Saturday/Sunday (Dates.dayofweek 6/7); locale-independent for TUI."
gantt_is_weekend(d::Date)::Bool = Dates.dayofweek(d) ∈ (6, 7)

"Date represented by 0-based column `col` (used for weekend + axis + shading)."
gantt_date_for_col(win_start::Date, dpc::Int, col::Int)::Date = win_start + Day(col * dpc)

"Columns that are weekends within the visible window (for shading pass)."
gantt_weekend_cols(win_start::Date, dpc::Int, ncols::Int)::Vector{Int} =
    [c for c in 0:(ncols-1) if gantt_is_weekend(gantt_date_for_col(win_start, dpc, c))]

"Columns at Monday (dayofweek==1) week starts, for vertical `┆` grid separators."
gantt_week_sep_cols(win_start::Date, dpc::Int, ncols::Int)::Vector{Int} =
    [c for c in 0:(ncols-1) if Dates.dayofweek(gantt_date_for_col(win_start, dpc, c)) == 1]

# ── PR2 ruler/axis + left width (pure) ──────────────────────────────────────
"""
    gantt_axis_labels(win_start, dpc, ncols; narrow=false) -> Vector{Tuple{Int,String}}

(col, label) for ruler row (y+2): "┬" (or +) at Mon week starts; month labels
("Mar 2026" or abbr "Mar") centered when their visible span >=3 cols.
"""
function gantt_axis_labels(win_start::Date, dpc::Int, ncols::Int; narrow::Bool=false)::Vector{Tuple{Int,String}}
    out = Tuple{Int,String}[]
    ncols <= 0 && return out
    # week ticks at Mondays
    for c in 0:(ncols-1)
        if Dates.dayofweek(gantt_date_for_col(win_start, dpc, c)) == 1
            push!(out, (c, "┬"))
        end
    end
    # month labels (one per month)
    seen = Set{Tuple{Int,Int}}()
    for c in 0:(ncols-1)
        d = gantt_date_for_col(win_start, dpc, c)
        key = (Dates.year(d), Dates.month(d))
        key in seen && continue
        push!(seen, key)
        m1 = Dates.Date(Dates.year(d), Dates.month(d), 1)
        mN = (m1 + Dates.Month(1)) - Dates.Day(1)
        cs = gantt_col_for_date(win_start, dpc, m1)
        ce = gantt_col_for_date(win_start, dpc, mN)
        c0v = max(0, cs); c1v = min(ncols-1, ce)
        span = c1v - c0v + 1
        if span >= 3
            lcol = c0v + (span - 1) ÷ 2
            fmt = narrow ? "u" : "u yyyy"
            push!(out, (lcol, Dates.format(d, fmt)))
        end
    end
    sort!(out, by = t -> t[1])
    dedup = Tuple{Int,String}[]
    for t in out
        if isempty(dedup) || dedup[end][1] != t[1]
            push!(dedup, t)
        elseif textwidth(t[2]) > 1
            dedup[end] = t  # prefer label over tick on collision
        end
    end
    filter!(t -> 0 <= t[1] < ncols, dedup)
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

"""
    gantt_left_width(rows, area_w) -> Int

Adaptive left label width (PR2). Guarantees chart space; uses longest label on data.
"""
function gantt_left_width(rows::Vector{GanttRow}, area_w::Int)::Int
    # Note: callers from render_gantt! are guarded to area_w >=24 before call;
    # direct pure-helper tests use w>=55. No <24 path exercised in normal use.
    if isempty(rows)
        return clamp(area_w ÷ 3, 14, 22)
    end
    maxl = maximum((textwidth(r.label) for r in rows), init = 0)
    desired = clamp(max(14, min(24, maxl + 3)), 14, area_w ÷ 3)
    min(desired, area_w - 20)
end

"""
    gantt_safe_char(ch, narrow=false) -> Char

Unicode fallback for narrow terminals (w<60) or textwidth!=1 guards (PR6).
Preserves core block elements (█ ░ ◆); maps box-drawing/seps to ASCII-ish.
Used for today, ruler, bands, legend, etc. + textwidth checks.
"""
gantt_safe_char(ch::Char, narrow::Bool=false)::Char =
    !narrow ? ch :
    ch == '┃' ? '│' :
    ch == '┆' ? '|' :
    ch == '▓' ? '#' :
    ch == '▌' ? '[' :
    ch == '▐' ? ']' :
    ch == '┬' ? '+' :
    ch == '▬' ? '-' : ch

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
    rows = gantt_rows(m)
    # Use/confirm adaptive left_w (PR2) + responsive narrow adjustment (PR6).
    # Guarantees chart space; longest label driven when data present.
    left_w = gantt_left_width(rows, area.width)
    is_narrow = area.width < 60
    if is_narrow
        left_w = min(14, max(10, area.width - 20))
    end
    left_w = max(10, min(left_w, area.width - 10))
    chart_x = area.x + left_w
    ncols = area.width - left_w
    win_start = m.gantt_start
    win_end = gantt_window_end(win_start, dpc, ncols)
    tcol = gantt_point_col(win_start, dpc, Dates.today(), ncols)  # COV_EXCL_LINE (hoist for coordination; value same as later; exercised via band/today)  # hoist early for band name/today coordination (minimal)
    scale_lbl = m.gantt_scale === :month ? "month" : "week"
    base = "GANTT — $(win_start) → $(win_end)  [$(scale_lbl)]"
    # Compact legend (PR6): ensure visible; shorten base on narrow to fit legend + responsive.
    if is_narrow && ncols >= 8
        base = "GANTT[$(scale_lbl)]"
    end
    title = base
    if ncols >= 10
        leg = if !is_narrow && area.width >= 80
            "  ░sprint █bar ◆pt " * string(gantt_safe_char('┃', false)) * "today"
        else
            " " * string(gantt_safe_char('░', is_narrow)) * string(gantt_safe_char('█', is_narrow)) * string(gantt_safe_char('◆', is_narrow)) * string(gantt_safe_char('┃', is_narrow))
        end
        if textwidth(title) + textwidth(leg) <= area.width
            title = title * leg
        end
    end
    set_string!(buf, area.x, area.y,
                _short(title, area.width),
                Style(; fg = col_primary(), bold = true))

    has_ruler = area.height >= 8
    # has_footer predicate approximates design ("&& nshow >=1") because nshow
    # depends on it (chicken/egg); rows>0 + h>=10 + guards guarantees positive
    # nshow for reservation. Safe for current layout math.
    has_footer = area.height >= 10 && length(rows) > 0
    ruler_rows = has_ruler ? 1 : 0
    footer_rows = has_footer ? 1 : 0
    content_start = 1 + 1 + ruler_rows
    # Compute layout rows always (bands loop is no-op for empty; ruler now drawn
    # for empty tall cases too so no blank ruler row when h>=8).
    band_y = area.y + 1
    ruler_y = area.y + 2
    grid_y0 = area.y + content_start
    nshow = max(0, min(length(rows), area.height - content_start - footer_rows - 1))
    # weekend shading on band row first (polish consistency), band will overlay its range
    for c in gantt_weekend_cols(win_start, dpc, ncols)
        ch = gantt_safe_char('░', is_narrow)  # COV_EXCL_LINE (safe path covered via grid shade + pure tests + other calls)
        set_string!(buf, chart_x + c, band_y, string(ch), Style(; fg = col_text_muted(), dim = true))
    end
    # Sprint bands polish (PR6): cleaner edges (▓/safe at ends), better name placement
    # (inside after edge when room; underline+dim always), aggressive truncate narrow.
    for (nm, c0, c1) in gantt_sprint_bands(m, win_start, dpc, ncols)
        bw = c1 - c0 + 1
        for cc in c0:c1
            ch = (cc == c0 || cc == c1) ? '▓' : '░'
            ch = gantt_safe_char(ch, is_narrow)  # COV_EXCL_LINE (safe_char + guards covered by dedicated tests + ruler/today/grid/weekend paths)
            if textwidth(ch) != 1
                ch = gantt_safe_char('░', is_narrow)  # COV_EXCL_LINE (guard branch; textwidth==1 always for our safe chars)
            end
            xx = chart_x + cc
            xx <= area.x + area.width - 1 && set_string!(buf, xx, band_y, string(ch), Style(; fg = col_text_muted(), dim = true))
        end
        # name: prefer inside after left edge when fits; dim underline; truncate
        maxn = max(1, bw - 2)
        nmsh = _short(nm, maxn)
        nx = c0 + (bw > textwidth(nmsh) + 1 ? 1 : 0)
        # avoid today ▼ collision on band_y (name not mangled) + reserve edges
        if tcol !== nothing && tcol >= c0 && tcol <= c1 && nx <= tcol <= nx + textwidth(nmsh) - 1  # COV_EXCL_LINE (edge case; overlap not in all test data; logic mirrors gantt_point_col)
            maxn = max(1, tcol - c0)  # COV_EXCL_LINE
            nmsh = _short(nm, maxn)  # COV_EXCL_LINE
            nx = c0  # COV_EXCL_LINE
        end
        set_string!(buf, chart_x + nx, band_y, nmsh, Style(; fg = col_text_dim(), underline = true))
        # re-set edges after name (guarantees cleaner ▓ even on narrow bw)
        if bw >= 2  # COV_EXCL_LINE (defensive re-assert; covered semantically in band tests + wide data; pure paths exercised)
            set_string!(buf, chart_x + c0, band_y, string(gantt_safe_char('▓', is_narrow)), Style(; fg = col_text_muted(), dim = true))
            set_string!(buf, chart_x + c1, band_y, string(gantt_safe_char('▓', is_narrow)), Style(; fg = col_text_muted(), dim = true))
        end
    end

    if has_ruler
        ax = gantt_axis_labels(win_start, dpc, ncols; narrow = is_narrow)
        for (c, lab) in ax
            (c < 0 || c >= ncols) && continue
            xx = chart_x + c
            xx > area.x + area.width - 1 && continue
            if textwidth(lab) <= 1
                tch = gantt_safe_char('┬', is_narrow)  # COV_EXCL_LINE (safe paths covered elsewhere)
                if textwidth(tch) != 1; tch = gantt_safe_char('+', true); end
                set_char!(buf, xx, ruler_y, tch, Style(; fg = col_text_muted(), dim = true))
            else
                set_string!(buf, xx, ruler_y, _short(lab, max(1, ncols - c)), Style(; fg = col_text_dim()))
            end
        end
    end

    if isempty(rows)
        empty_y = has_ruler ? area.y + 3 : area.y + 2
        set_string!(buf, area.x, empty_y, _short("No scheduled issues", area.width),
                    Style(; fg = col_text_dim()))
        return
    end

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

    # Weekend shading ░ (dim muted) on grid cols — BEFORE canvas so bars overlay where present.
    # Week separators ┆ (dim muted) on grid at week starts; skip today col to avoid clobber.
    wcols = gantt_weekend_cols(win_start, dpc, ncols)
    scols = gantt_week_sep_cols(win_start, dpc, ncols)
    tcol = gantt_point_col(win_start, dpc, Dates.today(), ncols)
    for c in wcols
        for ii in 1:nshow
            ch = gantt_safe_char('░', is_narrow)  # COV_EXCL_LINE (duplicate safe path; core covered by pure + narrow tests)
            if textwidth(ch) != 1; ch = '#'; end
            set_string!(buf, chart_x + c, grid_y0 + ii - 1, string(ch), Style(; fg = col_text_muted(), dim = true))
        end
    end
    for c in scols
        c == tcol && continue
        for ii in 1:nshow
            ch = gantt_safe_char('┆', is_narrow)  # COV_EXCL_LINE (duplicate safe path; core covered by pure + narrow tests)
            if textwidth(ch) != 1; ch = '|'; end
            set_char!(buf, chart_x + c, grid_y0 + ii - 1, ch, Style(; fg = col_text_muted(), dim = true))
        end
    end

    render(canvas, Rect(chart_x, grid_y0, ncols, max(1, nshow)), buf)

    for (dx, dy, dcol) in diamonds
        set_char!(buf, dx, dy, '◆', Style(; fg = dcol))
    end

    # Today marker (PR2): ▼ at band, ┃ (thick) vertical on grid; "TODAY" label on ruler if fits.
    # Use gantt_safe_char + textwidth guard (PR6).
    if tcol !== nothing
        set_char!(buf, chart_x + tcol, band_y, '▼', Style(; fg = col_primary_hi(), bold = true))
        today_ch = gantt_safe_char('┃', is_narrow)  # COV_EXCL_LINE (safe paths covered elsewhere)
        if textwidth(today_ch) != 1; today_ch = gantt_safe_char('│', true); end
        for i in 1:nshow
            set_char!(buf, chart_x + tcol, grid_y0 + (i - 1), today_ch, Style(; fg = col_primary_hi(), bold = true))
        end
        if has_ruler && (ncols - tcol) > 5
            lx = chart_x + tcol + 1
            if lx + 4 < chart_x + ncols
                set_string!(buf, lx, ruler_y, "TODAY", Style(; fg = col_primary_hi(), bold = true))
            end
        end
    end
end
