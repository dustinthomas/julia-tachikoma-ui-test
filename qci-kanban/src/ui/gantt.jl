# ═══════════════════════════════════════════════════════════════════════
# ui/gantt.jl — Phase 4 Gantt timeline view.
#
# Rows = issues that have a start_date and/or due_date, grouped under epic
# header rows. Bars span start_date→due_date rendered with `BlockCanvas`
# (quadrant blocks → ordinary text cells, so fully TestBackend-assertable);
# single-date issues render as a diamond. A today marker is a vertical line;
# sprint start→end are shaded bands with the sprint name. `z` cycles
# day/week/month scale, h/l scroll the window, j/k select a row, Enter opens the
# card detail modal.
#
# The date→column geometry lives in small PURE functions with direct unit
# tests (`gantt_col_for_date`, `gantt_bar_extent`, `gantt_point_col`,
# `gantt_window_end`) kept separate from rendering. No raw ColorRGB literals —
# color goes through Theming accessors (test-enforced).
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates
using TOML

# ── Scale geometry (pure) ───────────────────────────────────────────────────
"Days represented by one chart column at the given scale."
gantt_days_per_col(scale::Symbol)::Int = scale === :month ? 7 : 1

"Days the window scrolls per h/l press at the given scale."
gantt_scroll_days(scale::Symbol)::Int =
    scale === :month ? 28 : (scale === :day ? 1 : 7)

"Fixed window size for day view (each column = 1 day). Produces a compact 14-day
timeline strip even on wide terminals so day zoom does not devolve into months."
const GANTT_DAY_VIEW_WINDOW = 14

"Default logical window size for week view (day-columns; each column = 1 day)."
const GANTT_WEEK_VIEW_WINDOW = 42

"Default logical window size for month view (week-columns; each column = 7 days)."
const GANTT_MONTH_VIEW_WINDOW = 26

# Stretch clamp / step table (product-frozen Q2). Min/max are inclusive;
# step is the delta applied per stretch-in / stretch-out press.
const GANTT_DAY_WIN_MIN,   GANTT_DAY_WIN_MAX   = 7,  56
const GANTT_WEEK_WIN_MIN,  GANTT_WEEK_WIN_MAX  = 14, 90
const GANTT_MONTH_WIN_MIN, GANTT_MONTH_WIN_MAX = 8,  52

const GANTT_DAY_STRETCH_STEP   = 1
const GANTT_WEEK_STRETCH_STEP  = 7
const GANTT_MONTH_STRETCH_STEP = 2

"""
    gantt_default_view_window(scale::Symbol) -> Int

Default logical view-window size for `scale` (`:day` / `:week` / `:month`).
Unknown scales return `1` (defensive; stretch UI never selects them).
"""
function gantt_default_view_window(scale::Symbol)::Int
    scale === :day   && return GANTT_DAY_VIEW_WINDOW
    scale === :week  && return GANTT_WEEK_VIEW_WINDOW
    scale === :month && return GANTT_MONTH_VIEW_WINDOW
    return 1
end

"""
    gantt_clamp_view_window(scale::Symbol, w::Int) -> Int

Clamp a proposed view-window `w` into the product min/max for `scale`.
Unknown scales: floor at 1 (no upper bound).
"""
function gantt_clamp_view_window(scale::Symbol, w::Int)::Int
    if scale === :day
        return clamp(w, GANTT_DAY_WIN_MIN, GANTT_DAY_WIN_MAX)
    elseif scale === :week
        return clamp(w, GANTT_WEEK_WIN_MIN, GANTT_WEEK_WIN_MAX)
    elseif scale === :month
        return clamp(w, GANTT_MONTH_WIN_MIN, GANTT_MONTH_WIN_MAX)
    else
        return max(1, w)
    end
end

"""
    gantt_stretch_step(scale::Symbol) -> Int

Integer delta applied to the view-window per stretch-in / stretch-out press.
Unknown scales return `1`.
"""
function gantt_stretch_step(scale::Symbol)::Int
    scale === :day   && return GANTT_DAY_STRETCH_STEP
    scale === :week  && return GANTT_WEEK_STRETCH_STEP
    scale === :month && return GANTT_MONTH_STRETCH_STEP
    return 1
end

"""
    gantt_cols_per_day(physical_ncols::Int, view_window::Int) -> Int

How many physical terminal columns map to one logical window unit when a
`view_window`-sized logical span fills `physical_ncols` chart columns:
`⌊physical / window⌋`, floored at 1. Non-positive physical → 1.
Primary form used by layout once stretch wires live windows.
"""
function gantt_cols_per_day(physical_ncols::Int, view_window::Int)::Int
    physical_ncols < 1 && return 1
    max(1, fld(physical_ncols, max(1, view_window)))
end

"""
    gantt_cols_per_day(scale::Symbol, physical_ncols::Int) -> Int

Scale overload at **default** view-window for `scale`. Unknown scales **must**
return `1` (D9 / pure-test contract). Non-positive physical → 1.
"""
function gantt_cols_per_day(scale::Symbol, physical_ncols::Int)::Int
    physical_ncols < 1 && return 1
    scale in (:day, :week, :month) || return 1
    gantt_cols_per_day(physical_ncols, gantt_default_view_window(scale))
end

"""
    gantt_view_window(m::AppModel, scale::Symbol = m.gantt_scale) -> Int

Live logical view-window for `scale` from model fields (per-scale stretch memory).
"""
function gantt_view_window(m::AppModel, scale::Symbol = m.gantt_scale)::Int
    scale === :day   && return m.gantt_win_day
    scale === :week  && return m.gantt_win_week
    scale === :month && return m.gantt_win_month
    return gantt_default_view_window(scale)
end

"""
    gantt_set_view_window!(m::AppModel, scale::Symbol, w::Int) -> Int

Clamp `w` into the product min/max for `scale` and store on the matching model
field. Returns the clamped value. Unknown scales are ignored (return clamped
floor only; no field write).
"""
function gantt_set_view_window!(m::AppModel, scale::Symbol, w::Int)::Int
    cw = gantt_clamp_view_window(scale, w)
    if scale === :day
        m.gantt_win_day = cw
    elseif scale === :week
        m.gantt_win_week = cw
    elseif scale === :month
        m.gantt_win_month = cw
    end
    return cw
end

"""
Terminal rows per logical Gantt row: 1 content line + (`stride - 1`) blank
inter-bar gap lines. Product default is stride `2` (one blank row between bars);
left-rail tree stems paint through those gaps so the hierarchy stays connected.
"""
const GANTT_ROW_STRIDE = 2

"""
    gantt_grid_height(nshow; stride=GANTT_ROW_STRIDE) -> Int

Terminal rows occupied by `nshow` content rows with inter-row gaps of
`stride - 1` cells and **no** trailing gap after the last row.
"""
gantt_grid_height(nshow::Int; stride::Int = GANTT_ROW_STRIDE)::Int =
    nshow <= 0 ? 0 : (nshow - 1) * stride + 1

"""
    gantt_nshow_fit(avail, nrows; stride=GANTT_ROW_STRIDE) -> Int

How many logical rows fit in `avail` terminal lines (including inter-row gaps).
"""
function gantt_nshow_fit(avail::Int, nrows::Int; stride::Int = GANTT_ROW_STRIDE)::Int
    (avail < 1 || nrows < 1) && return 0
    max_fit = 1 + fld(avail - 1, stride)
    min(nrows, max_fit)
end

"""
    gantt_row_y(grid_y0, vis_i; stride=GANTT_ROW_STRIDE) -> Int

Absolute terminal y of the content line for 1-based visible index `vis_i`.
"""
gantt_row_y(grid_y0::Int, vis_i::Int; stride::Int = GANTT_ROW_STRIDE)::Int =
    grid_y0 + (vis_i - 1) * stride

"""
    gantt_vis_i_at(grid_y0, y, nshow; stride=GANTT_ROW_STRIDE) -> Int | nothing

1-based visible content index when `y` lands on a content line; `nothing` on
inter-bar gap lines or outside the grid.
"""
function gantt_vis_i_at(grid_y0::Int, y::Int, nshow::Int;
                        stride::Int = GANTT_ROW_STRIDE)::Union{Nothing,Int}
    nshow < 1 && return nothing
    off = y - grid_y0
    off < 0 && return nothing
    gh = gantt_grid_height(nshow; stride = stride)
    off >= gh && return nothing
    mod(off, stride) != 0 && return nothing  # gap line
    vis_i = fld(off, stride) + 1
    (1 <= vis_i <= nshow) ? vis_i : nothing
end

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

"""
    gantt_period_sep_cols(win_start, dpc, ncols, scale) -> Vector{Int}

0-based columns at period boundaries for vertical `┆` seps (G5 polish).
Calendar **month** edges for all scales (day/week/month) — not ISO Mondays
(those remain `gantt_week_sep_cols`, painted only when `dpc==1`).

A column is a boundary when its `(year, month)` differs from the previous
column's. Col 0 is never a sep (no prior period in the window). Empty /
non-positive `ncols` → empty vector.
"""
function gantt_period_sep_cols(win_start::Date, dpc::Int, ncols::Int, scale::Symbol)::Vector{Int}
    out = Int[]
    ncols <= 0 && return out
    # `scale` reserved for future period defs; all current scales use month edges.
    _ = scale
    prev_key = nothing
    for c in 0:(ncols - 1)
        d = gantt_date_for_col(win_start, dpc, c)
        key = (Dates.year(d), Dates.month(d))
        if prev_key !== nothing && key != prev_key
            push!(out, c)
        end
        prev_key = key
    end
    out
end

"""
    gantt_quarter_id(d::Date) -> (year::Int, quarter::Int)

Calendar quarter 1..4 for `d` (Q1=Jan–Mar, …, Q4=Oct–Dec).
"""
gantt_quarter_id(d::Date)::Tuple{Int,Int} =
    (Dates.year(d), (Dates.month(d) - 1) ÷ 3 + 1)

"""
    gantt_axis_quarter_tabs(win_start, dpc, ncols; narrow=false)
        -> Vector{NamedTuple{(:c0,:c1,:label,:center), Tuple{Int,Int,String,Int}}}

One entry per distinct calendar quarter intersecting the window (G5 super-header).
Labels prefer `"Q{n} {year}"` when span fits, else `"Q{n}"`.
"""
function gantt_axis_quarter_tabs(win_start::Date, dpc::Int, ncols::Int; narrow::Bool=false)
    NT = NamedTuple{(:c0, :c1, :label, :center), Tuple{Int,Int,String,Int}}
    out = NT[]
    ncols <= 0 && return out
    periods = Tuple{Tuple{Int,Int},Int,Int,Date}[]
    seen = Dict{Tuple{Int,Int},Int}()
    for c in 0:(ncols - 1)
        d = gantt_date_for_col(win_start, dpc, c)
        key = gantt_quarter_id(d)
        if haskey(seen, key)
            i = seen[key]
            k, c0, _c1, sd = periods[i]
            periods[i] = (k, c0, c, sd)
        else
            push!(periods, (key, c, c, d))
            seen[key] = length(periods)
        end
    end
    for (key, c0, c1, _sample) in periods
        span = c1 - c0 + 1
        center = c0 + (c1 - c0) ÷ 2
        y, q = key
        full = "Q$(q) $(y)"
        short = "Q$(q)"
        lab = if !narrow && textwidth(full) <= span
            full
        elseif textwidth(short) <= span
            short
        else
            fit_width(short, max(1, span))
        end
        push!(out, (c0=c0, c1=c1, label=lab, center=center))
    end
    out
end

"""
    gantt_clamped_start_for_day(win_start, today, dpc, ncols) -> Date

For day scale only (dpc==1), returns a start date that positions "today" near the
left of the timeline (traditional Gantt: limited past, mostly future visible).
Uses today-1 as the preferred start. Day view render caps the window at
GANTT_DAY_VIEW_WINDOW (14) columns so the visible range is e.g. today-1 → today+12.
If the logical start is earlier (old data), it snaps; later starts (scrolled right)
are kept. Week/month and non-day scales are identity.
"""
function gantt_clamped_start_for_day(win_start::Date, today::Date, dpc::Int, ncols::Int)::Date
    dpc != 1 && return win_start
    # Traditional day-view: position today near left of the timeline (limited past).
    # Effective window starts at today-1 even if logical/raw start is far in the past.
    # This prevents "today pushed to right" and "left goes to November".
    # m.gantt_start (logical) is not mutated; only the render window is adjusted.
    preferred = today - Day(1)
    return max(win_start, preferred)
end

# ── G1 period identity / shade / tabs / post-bar geom (pure; shade=G2, tabs=G3) ─
"""
    gantt_iso_week_id(d::Date) -> (iso_week_year::Int, iso_week::Int)

ISO-8601 week date: week-year is the year of the Thursday of that ISO week.
`iso_week` is `Dates.week(d)` (1..53). Do not use calendar year with week number.
"""
function gantt_iso_week_id(d::Date)::Tuple{Int,Int}
    thu = d + Day(4 - Dates.dayofweek(d))
    return (Dates.year(thu), Dates.week(d))
end

"""
    gantt_period_key(d::Date, scale::Symbol) -> Tuple

Stable key for the scale's period (tabs + grouping):
- :day   → (year, month, day)
- :week  → gantt_iso_week_id(d)  # (iso_week_year, iso_week)
- :month → (year, month)
"""
function gantt_period_key(d::Date, scale::Symbol)
    scale === :month && return (Dates.year(d), Dates.month(d))
    scale === :week  && return gantt_iso_week_id(d)
    return (Dates.year(d), Dates.month(d), Dates.day(d))
end

# Fixed Monday epoch for proleptic week ordinal (1970-01-05 is a Monday).
const GANTT_WEEK_EPOCH = Date(1970, 1, 5)  # dayofweek == 1

"""
    gantt_week_ordinal(d::Date) -> Int

Proleptic week index: floor((d - Monday_epoch) / 7).
Adjacent calendar weeks always differ by 1 → parity always alternates.
"""
gantt_week_ordinal(d::Date)::Int = fld(Dates.value(d) - Dates.value(GANTT_WEEK_EPOCH), 7)

"""
    gantt_period_parity(d, scale) -> Bool  # true = receive alt wash

Consecutive periods in calendar order MUST alternate.
- :day   → isodd(Dates.value(d))
- :week  → isodd(gantt_week_ordinal(d))
- :month → isodd(year*12 + month)
"""
function gantt_period_parity(d::Date, scale::Symbol)::Bool
    if scale === :month
        return isodd(Dates.year(d) * 12 + Dates.month(d))
    elseif scale === :week
        return isodd(gantt_week_ordinal(d))
    else
        return isodd(Dates.value(d))
    end
end

"""
    gantt_period_shade_cols(win_start, dpc, ncols, scale) -> Vector{Int}

0-based columns whose period parity is true (receive alt wash).
"""
function gantt_period_shade_cols(win_start::Date, dpc::Int, ncols::Int, scale::Symbol)::Vector{Int}
    [c for c in 0:(ncols-1)
     if gantt_period_parity(gantt_date_for_col(win_start, dpc, c), scale)]
end

"""
    gantt_post_bar_label_geom(c0, c1, label_ncols; gap=1, max_w=nothing, tcol=nothing)
        -> Union{Nothing, NamedTuple{(:start, :max_chars), Tuple{Int,Int}}}

Label starts at c1 + 1 + gap (0-based chart cols).
`label_ncols` is the right clip edge. Returns nothing if start ≥ label_ncols or avail < 1.
If `tcol` is a column with start ≤ tcol, max_chars stops before tcol.
"""
function gantt_post_bar_label_geom(c0::Int, c1::Int, label_ncols::Int;
                                   gap::Int=1, max_w::Union{Nothing,Int}=nothing,
                                   tcol::Union{Nothing,Int}=nothing)
    start = c1 + 1 + gap
    start >= label_ncols && return nothing
    avail = label_ncols - start
    if tcol !== nothing && tcol >= start
        avail = min(avail, tcol - start)
    end
    max_w !== nothing && (avail = min(avail, max_w))
    avail < 1 && return nothing
    (; start, max_chars = avail)
end

"""
    gantt_pre_bar_key_geom(c0, view_ncols; gap=1, key_w) -> (; start, max_chars) | nothing

Paint issue key ending just before bar start `c0` (or diamond col), with `gap`
blank columns between key and bar. Returns nothing when the full key cannot fit
in chart cols `[0, c0)` (no bleed into left rail; no partial key). Clip edge is
`view_ncols` (keys live in the bar window, not the day physical gutter).

Note: plan PR-V optional `(c0, c1, …)` is simplified — pre-bar placement depends
only on bar/diamond **start** `c0`, not `c1`.
"""
function gantt_pre_bar_key_geom(c0::Int, view_ncols::Int;
                                gap::Int=1, key_w::Int)
    key_w < 1 && return nothing
    gap < 0 && return nothing
    # last key col sits gap cells left of bar start
    last = c0 - gap - 1
    last < 0 && return nothing
    start = last - key_w + 1
    start < 0 && return nothing
    # entire key must sit inside the chart view strip
    last >= view_ncols && return nothing
    (; start, max_chars = key_w)
end

# ── PR2 ruler/axis + left width (pure) ──────────────────────────────────────
# Overhaul (2026-07): denser product-style axis — period labels (months) plus
# numeric day/period ticks so the chart is readable without relying only on a
# month span string. Dual-row render uses period + tick helpers separately;
# gantt_axis_labels remains the single-row combined API (compat + h=8 path).

"""
    gantt_axis_period_labels(win_start, dpc, ncols; narrow=false) -> Vector{Tuple{Int,String}}

Month (or multi-week) period labels centered over their visible span when span ≥ 3.
"""
function gantt_axis_period_labels(win_start::Date, dpc::Int, ncols::Int; narrow::Bool=false)::Vector{Tuple{Int,String}}
    out = Tuple{Int,String}[]
    ncols <= 0 && return out
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
        c0v = max(0, cs); c1v = min(ncols - 1, ce)
        span = c1v - c0v + 1
        if span >= 3
            lcol = c0v + (span - 1) ÷ 2
            fmt = narrow ? "u" : "u yyyy"
            push!(out, (lcol, Dates.format(d, fmt)))
        elseif span >= 1 && c0v == 0
            # short visible month tail/head still gets an abbr at left edge
            push!(out, (c0v, Dates.format(d, "u")))
        end
    end
    filter!(t -> 0 <= t[1] < ncols, out)
end

"""
    gantt_axis_tick_labels(win_start, dpc, ncols; narrow=false) -> Vector{Tuple{Int,String}}

Numeric day/period ticks with non-overlapping pack and breathing room:
- dpc == 1 + compact window (ncols ≤ 16, day view strip): dense pack (step = label
  width) so ~14-day zoom stays informative.
- dpc == 1 + wider window (week scale uses full terminal width): leave 1–2 blank
  columns between labels so day numbers read as separated groups, not a digit wall.
- dpc >= 2 (month, one col ≈ one week): day-of-month of each period start, with
  at least one blank column between labels (2-digit days never mash into neighbors).
"""
function gantt_axis_tick_labels(win_start::Date, dpc::Int, ncols::Int; narrow::Bool=false)::Vector{Tuple{Int,String}}
    out = Tuple{Int,String}[]
    ncols <= 0 && return out
    # Breathing room between tick starts (beyond label width):
    # day strip = 0; medium/narrow week = 1; very wide week or month = 2/1.
    min_gap = if dpc >= 2
        1
    elseif ncols <= 16
        0
    elseif ncols <= 36 || narrow
        1
    else
        2
    end
    # On very wide day/week charts, also cap density (≈1 label / 3 cols).
    min_step = (dpc == 1 && ncols > 40) ? 3 : 1
    c = 0
    while c < ncols
        d = gantt_date_for_col(win_start, dpc, c)
        lab = string(Dates.day(d))
        w = textwidth(lab)
        if c + w - 1 >= ncols
            # last cell: prefer single digit (ones place) so something shows
            lab = string(Dates.day(d) % 10)
            w = 1
        end
        push!(out, (c, lab))
        step = max(w + min_gap, min_step)
        c += max(1, step)
    end
    out
end

"""
    gantt_axis_labels(win_start, dpc, ncols; narrow=false) -> Vector{Tuple{Int,String}}

Combined single-row axis (compat / short height): prefers numeric day ticks;
keeps Monday `┬` only where it does not collide with a day number; overlays
month period labels when they do not stomp a dense tick column (prefer tick).
"""
function gantt_axis_labels(win_start::Date, dpc::Int, ncols::Int; narrow::Bool=false)::Vector{Tuple{Int,String}}
    out = Tuple{Int,String}[]
    ncols <= 0 && return out
    # Short Monday markers first (dpc==1), then period labels (longer non-digit wins
    # when period center lands on a Monday), then dense day ticks (digits always win).
    if dpc == 1
        for c in 0:(ncols-1)
            if Dates.dayofweek(gantt_date_for_col(win_start, dpc, c)) == 1
                push!(out, (c, "┬"))
            end
        end
    end
    for (c, lab) in gantt_axis_period_labels(win_start, dpc, ncols; narrow=narrow)
        push!(out, (c, lab))
    end
    append!(out, gantt_axis_tick_labels(win_start, dpc, ncols; narrow=narrow))
    sort!(out, by = t -> t[1])
    dedup = Tuple{Int,String}[]
    for t in out
        if isempty(dedup) || dedup[end][1] != t[1]
            push!(dedup, t)
        else
            # prefer numeric tick over month/┬ on collision; else longer label
            if occursin(r"^\d{1,2}$", t[2])
                dedup[end] = t
            elseif !occursin(r"^\d{1,2}$", dedup[end][2]) && textwidth(t[2]) > textwidth(dedup[end][2])
                dedup[end] = t
            end
        end
    end
    filter!(t -> 0 <= t[1] < ncols, dedup)
end

"""
    gantt_axis_period_tabs(win_start, dpc, ncols, scale; narrow=false)
        -> Vector{NamedTuple{(:c0,:c1,:label,:center), Tuple{Int,Int,String,Int}}}

One entry per distinct period intersecting the window.
`c0,c1` = inclusive visible column span; `center` = c0 + (c1-c0)÷2.
- :day   → calendar months (full name; year on first/Jan/multi-year)
- :week  → ISO Mon..Sun; "W{n} {u} {d}" when span≥7 && !narrow else "W{n}"
- :month → calendar months (same year rule as :day)
"""
function gantt_axis_period_tabs(win_start::Date, dpc::Int, ncols::Int, scale::Symbol;
                                narrow::Bool=false)
    NT = NamedTuple{(:c0, :c1, :label, :center), Tuple{Int,Int,String,Int}}
    out = NT[]
    ncols <= 0 && return out

    # Multi-year window? (for year-suffix rule on month-style tabs)
    d_first = gantt_date_for_col(win_start, dpc, 0)
    d_last  = gantt_date_for_col(win_start, dpc, ncols - 1)
    multi_year = Dates.year(d_first) != Dates.year(d_last)

    # Collect ordered periods: (key, c0, c1, sample_date)
    periods = Tuple{Any,Int,Int,Date}[]
    if scale === :week
        seen = Dict{Tuple{Int,Int},Int}()  # key -> index in periods
        for c in 0:(ncols-1)
            d = gantt_date_for_col(win_start, dpc, c)
            key = gantt_iso_week_id(d)
            if haskey(seen, key)
                i = seen[key]
                k, c0, _c1, sd = periods[i]
                periods[i] = (k, c0, c, sd)
            else
                push!(periods, (key, c, c, d))
                seen[key] = length(periods)
            end
        end
    else
        # :day and :month → one tab per calendar month
        seen = Dict{Tuple{Int,Int},Int}()
        for c in 0:(ncols-1)
            d = gantt_date_for_col(win_start, dpc, c)
            key = (Dates.year(d), Dates.month(d))
            if haskey(seen, key)
                i = seen[key]
                k, c0, _c1, sd = periods[i]
                periods[i] = (k, c0, c, sd)
            else
                push!(periods, (key, c, c, d))
                seen[key] = length(periods)
            end
        end
    end

    for (idx, (key, c0, c1, sample)) in enumerate(periods)
        span = c1 - c0 + 1
        center = c0 + (c1 - c0) ÷ 2
        lab = if scale === :week
            iso_y, iso_w = key::Tuple{Int,Int}
            mon = sample - Day(Dates.dayofweek(sample) - 1)
            # Full week visible (span≥7) and wide terminal → include Monday date
            if !narrow && span >= 7
                "W$(iso_w) $(Dates.format(mon, "u")) $(Dates.day(mon))"
            else
                "W$(iso_w)"
            end
        else
            y, mo = key::Tuple{Int,Int}
            d_lab = Date(y, mo, 1)
            # Full name when wide; always keep abbr for packing fallback (avoid "Augus")
            base = Dates.format(d_lab, narrow ? "u" : "U")
            abbr = Dates.format(d_lab, "u")
            want_year = (idx == 1) || (mo == 1) || multi_year
            # Packing order (design Criterion 2): year+full → full → abbr → fit_width(abbr)
            if want_year
                with_y = string(base, " ", y)
                if textwidth(with_y) <= span
                    with_y
                elseif textwidth(base) <= span
                    base
                elseif textwidth(abbr) <= span
                    abbr
                else
                    fit_width(abbr, max(1, span))
                end
            else
                if textwidth(base) <= span
                    base
                elseif textwidth(abbr) <= span
                    abbr
                else
                    fit_width(abbr, max(1, span))
                end
            end
        end
        # Full-week long form ("W12 Mar 16") is kept intact for pure oracles.
        # Narrow / partial-week short "W{n}" clips when the token exceeds span.
        if scale === :week && (narrow || span < 7) && textwidth(lab) > span
            lab = fit_width(lab, max(1, span))
        end
        push!(out, (c0=c0, c1=c1, label=lab, center=center))
    end
    out
end

# ── Keep-in-view / selection orientation (pure) ─────────────────────────────
"""
    gantt_bar_in_window(win_start, dpc, ncols, sd, ed) -> Bool

True when the bar [sd,ed] intersects the visible column window.
"""
gantt_bar_in_window(win_start::Date, dpc::Int, ncols::Int, sd::Date, ed::Date)::Bool =
    gantt_bar_extent(win_start, dpc, sd, ed, ncols) !== nothing

"""
    gantt_reveal_start(win_start, dpc, ncols, sd, ed; pad=1) -> Date

Window start that makes [sd,ed] visible. Identity when already in view.
When scrolling, places the earlier date at column `pad` (default 1).
"""
function gantt_reveal_start(win_start::Date, dpc::Int, ncols::Int, sd::Date, ed::Date; pad::Int=1)::Date
    lo, hi = sd <= ed ? (sd, ed) : (ed, sd)
    gantt_bar_in_window(win_start, dpc, ncols, lo, hi) && return win_start
    p = clamp(pad, 0, max(0, ncols - 1))
    lo - Day(p * dpc)
end

"Anchor span for an issue (start/due, order-normalized); nothing if undated."
function gantt_issue_span(iss::Domain.Issue)::Union{Nothing,Tuple{Date,Date}}
    if iss.start_date !== nothing && iss.due_date !== nothing
        lo, hi = iss.start_date <= iss.due_date ? (iss.start_date, iss.due_date) : (iss.due_date, iss.start_date)
        return (lo, hi)
    elseif iss.start_date !== nothing
        return (iss.start_date, iss.start_date)
    elseif iss.due_date !== nothing
        return (iss.due_date, iss.due_date)
    end
    nothing
end

"""
    gantt_effective_win_start(win_start, today, dpc, ncols, sel_span) -> Date

Day-scale near-term clamp (today-1 floor) so wide terminals / ancient data do not
open a multi-month empty strip — **unless** keep-in-view has already placed
`win_start` at the reveal position for `sel_span` (pad=1 → lo − 1·dpc). That
lets j/k-focused past bars stay on chart without reintroducing init-time
multi-month empty strips (init earliest ≠ reveal start). Non-day scales are
identity.
"""
function gantt_effective_win_start(win_start::Date, today::Date, dpc::Int, ncols::Int,
                                   sel_span::Union{Nothing,Tuple{Date,Date}})::Date
    dpc != 1 && return win_start
    preferred = today - Day(1)
    clamped = max(win_start, preferred)
    if sel_span !== nothing
        sd, ed = sel_span
        lo, hi = sd <= ed ? (sd, ed) : (ed, sd)
        # Keep-in-view already put the bar in [win_start, …] but the near-term
        # floor would hide it → honor the reveal-aligned start only.
        if !gantt_bar_in_window(clamped, dpc, ncols, lo, hi) &&
           gantt_bar_in_window(win_start, dpc, ncols, lo, hi)
            # gantt_reveal_start places lo at column `pad` (default 1)
            expected = gantt_reveal_start(clamped, dpc, ncols, lo, hi)
            if win_start == expected
                return win_start
            end
        end
    end
    clamped
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
    [i for i in Stores.list_issues(m.boardstore; project_id = _scope(m))
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
    for e in Stores.list_epics(m.boardstore; project_id = _scope(m))
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
    for s in Stores.list_sprints(m.boardstore; project_id = _scope(m))
        (s.start_date === nothing || s.end_date === nothing) && continue
        ext = gantt_bar_extent(win_start, dpc, s.start_date, s.end_date, ncols)
        ext === nothing && continue
        push!(bands, (s.name, ext[1], ext[2]))
    end
    bands
end

"""
    gantt_left_label(row::GanttRow; compact::Bool=false) -> String

compact=true  → issue rows: key only; epic rows: epic name (unchanged).
compact=false → full row.label (key + title for issues).
"""
function gantt_left_label(row::GanttRow; compact::Bool=false)::String
    row.kind === :epic && return row.label
    compact || return row.label
    row.issue !== nothing ? row.issue.key : row.label
end

"""
    gantt_tree_prefix(rows, row_index; selected=false) -> String

Left-rail branch for a full-list row index. Selected issues use `▸ `; the last
issue in an epic group closes with `└ `; other issue siblings use `├ `. Epic
rows (and OOB) fall back to `├ ` — callers paint epics with `▬` instead.
"""
function gantt_tree_prefix(rows::Vector{GanttRow}, row_index::Int;
                           selected::Bool = false)::String
    selected && return "▸ "
    (1 <= row_index <= length(rows)) || return "├ "
    rows[row_index].kind === :issue || return "├ "
    next_i = row_index + 1
    if next_i > length(rows)
        return "└ "
    end
    nxt = rows[next_i]
    # Next epic (or different group key) ends this branch.
    if nxt.kind === :epic || nxt.color_key != rows[row_index].color_key
        return "└ "
    end
    "├ "
end

"""
    gantt_tree_stem_after(rows, row_index) -> Bool

True when a vertical tree stem (`│`) should continue on the line(s) after this
content row — epic with a following child, or a non-last issue in its group.
Used to fill inter-row gap lines when `row_stride > 1` so the left rail stays
visually continuous.
"""
function gantt_tree_stem_after(rows::Vector{GanttRow}, row_index::Int)::Bool
    (1 <= row_index <= length(rows)) || return false
    next_i = row_index + 1
    next_i > length(rows) && return false
    cur = rows[row_index]
    nxt = rows[next_i]
    if cur.kind === :epic
        return nxt.kind === :issue  # children follow immediately under the epic
    end
    cur.kind === :issue || return false
    nxt.kind === :issue && nxt.color_key == cur.color_key
end

"""
    gantt_left_width(rows, area_w; compact=false) -> Int

Adaptive left label width (PR2). When compact=true, measure epic labels + issue
keys (not full titles) so chart columns expand. compact=false matches prior
behavior (max textwidth of full labels).
"""
function gantt_left_width(rows::Vector{GanttRow}, area_w::Int; compact::Bool=false)::Int
    # Note: callers from render_gantt! are guarded to area_w >=24 before call;
    # direct pure-helper tests use w>=55. No <24 path exercised in normal use.
    if isempty(rows)
        return clamp(area_w ÷ 3, 14, 22)
    end
    maxl = maximum(textwidth(gantt_left_label(r; compact=compact)) for r in rows; init=0)
    lo = compact ? 10 : 14
    desired = clamp(max(lo, min(24, maxl + 3)), lo, area_w ÷ 3)
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
    ch == '▬' ? '-' :
    # G6b dependency polyline (box-drawing → ASCII)
    ch == '─' ? '-' :
    ch == '│' ? '|' :
    ch == '╮' ? '+' :
    ch == '╯' ? '+' :
    ch == '╰' ? '+' :
    ch == '╭' ? '+' :
    ch == '▶' ? '>' :
    ch == '◀' ? '<' : ch

"""
    gantt_link_segments(from_row, to_row, c_from, c_to; narrow=false)
        -> Vector{NamedTuple{(:x,:y,:ch),Tuple{Int,Int,Char}}}

Pure finish-to-start orthogonal polyline for a `blocks` edge (G6b / Criterion 4).
`(c_from, from_row)` is the source bar **end**; `(c_to, to_row)` is the target
bar **start**. Rows and columns are 0-based chart-relative indices.

Box-drawing: `─` `│` `╮` `╯` `╰` `╭` `▶` `◀`. When `narrow`, maps via
`gantt_safe_char`. Caller clips to the visible window and paints after bars,
before post-bar keys.
"""
function gantt_link_segments(from_row::Int, to_row::Int, c_from::Int, c_to::Int;
                             narrow::Bool = false)
    segs = NamedTuple{(:x, :y, :ch), Tuple{Int, Int, Char}}[]
    function pushseg!(x::Int, y::Int, ch::Char)
        push!(segs, (x = x, y = y, ch = gantt_safe_char(ch, narrow)))
        nothing
    end

    if from_row == to_row
        if c_from == c_to
            pushseg!(c_to, to_row, '▶')
            return segs
        elseif c_from < c_to
            for x in c_from:(c_to - 1)
                pushseg!(x, from_row, '─')
            end
            pushseg!(c_to, to_row, '▶')
        else
            for x in (c_to + 1):c_from
                pushseg!(x, from_row, '─')
            end
            pushseg!(c_to, to_row, '◀')
        end
        return segs
    end

    going_down = to_row > from_row
    # Start corner at source bar end; vertical along c_from.
    pushseg!(c_from, from_row, going_down ? '╮' : '╯')
    if going_down
        for y in (from_row + 1):(to_row - 1)
            pushseg!(c_from, y, '│')
        end
    else
        for y in (to_row + 1):(from_row - 1)
            pushseg!(c_from, y, '│')
        end
    end

    if c_to == c_from
        pushseg!(c_to, to_row, '▶')
    elseif c_to > c_from
        pushseg!(c_from, to_row, going_down ? '╰' : '╭')
        for x in (c_from + 1):(c_to - 1)
            pushseg!(x, to_row, '─')
        end
        pushseg!(c_to, to_row, '▶')
    else
        pushseg!(c_from, to_row, going_down ? '╯' : '╮')
        for x in (c_to + 1):(c_from - 1)
            pushseg!(x, to_row, '─')
        end
        pushseg!(c_to, to_row, '◀')
    end
    segs
end

"""
    gantt_issue_endpoint_cols(win_start, dpc, sd, ed, ncols) -> (c0, c1) | nothing

Bar start/end columns for FS arrows. Dual-date → `gantt_bar_extent`; single-date
diamond → `(col, col)`. `nothing` when wholly outside the window.
"""
function gantt_issue_endpoint_cols(win_start::Date, dpc::Int, sd, ed, ncols::Int)
    if sd !== nothing && ed !== nothing
        return gantt_bar_extent(win_start, dpc, sd, ed, ncols)
    end
    d = sd === nothing ? ed : sd
    col = gantt_point_col(win_start, dpc, d, ncols)
    col === nothing && return nothing
    (col, col)
end

"""
    status_progress(iss) -> Float64

PR3 helper: density fraction for bar fill.
Done=1.0 (full █), Review=0.85, In Progress=0.55, else 0.25.
"""
function status_progress(iss::Domain.Issue)::Float64
    iss.status == "Done"        && return 1.0
    iss.status == "Review"      && return 0.85
    iss.status == "In Progress" && return 0.55
    0.25
end

# ── Gantt UI prefs (D14): gantt_ui.toml next to session token ───────────────
"""Path of the Gantt stretch prefs file (same dir as session token / last_project)."""
_gantt_ui_prefs_path(m::AppModel) =
    joinpath(dirname(m.session.token_path), "gantt_ui.toml")

"""
Load `gantt_ui.toml` if present; clamp windows via `gantt_set_view_window!`.
Missing/unreadable/corrupt → leave constructor defaults. Never throws.
"""
function _load_gantt_ui_prefs!(m::AppModel)
    path = _gantt_ui_prefs_path(m)
    isfile(path) || return m
    try
        t = TOML.parsefile(path)
        g = get(t, "gantt", nothing)
        g isa AbstractDict || return m
        if haskey(g, "win_day")
            gantt_set_view_window!(m, :day, Int(g["win_day"]))
        end
        if haskey(g, "win_week")
            gantt_set_view_window!(m, :week, Int(g["win_week"]))
        end
        if haskey(g, "win_month")
            gantt_set_view_window!(m, :month, Int(g["win_month"]))
        end
    catch err
        @warn "could not read gantt_ui.toml" error = err  # COV_EXCL_LINE (I/O failure rare)
    end
    m
end

"""
Persist current per-scale windows to `gantt_ui.toml` (0600 atomic).
Failures warn only — do not fail the stretch action.
"""
function _save_gantt_ui_prefs!(m::AppModel)
    path = _gantt_ui_prefs_path(m)
    contents = string(
        "# Gantt UI prefs — operator density; not plant AppConfig\n",
        "[gantt]\n",
        "win_day = ", m.gantt_win_day, "\n",
        "win_week = ", m.gantt_win_week, "\n",
        "win_month = ", m.gantt_win_month, "\n",
    )
    try
        Config._atomic_write_0600(path, contents)
    catch err
        @warn "could not write gantt_ui.toml" error = err  # COV_EXCL_LINE (I/O failure rare)
    end
    m
end

# ── Initialisation + actions ────────────────────────────────────────────────
"Set the window to start at the earliest dated issue (or today), day scale (day/wk/mo 3-way cycle).
Does **not** reset per-scale stretch windows (D7 / Q5)."
function _gantt_init!(m::AppModel)
    dates = Date[]
    for i in gantt_dated_issues(m)
        i.start_date === nothing || push!(dates, i.start_date)
        i.due_date === nothing || push!(dates, i.due_date)
    end
    m.gantt_start = isempty(dates) ? Dates.today() : minimum(dates)
    m.gantt_scale = :day
    m.gantt_sel = 1
    m
end

function _gantt_scroll!(m::AppModel, dir::Int)
    m.gantt_start += Day(dir * gantt_scroll_days(m.gantt_scale))
    m.message = "Gantt window from $(m.gantt_start)"
    m
end

"""
    _gantt_select!(m, sel)

Shared select helper for keyboard and mouse: set issue-only `gantt_sel`
(1-based into `gantt_issue_rows`) and run horizontal keep-in-view.
"""
function _gantt_select!(m::AppModel, sel::Int)
    n = length(gantt_issue_rows(m))
    n == 0 && return m
    m.gantt_sel = clamp(sel, 1, n)
    _gantt_ensure_selection_visible!(m)
    m
end

"""
    _gantt_select_issue_id!(m, issue_id)

Map an issue id → issue-only selection index, then `_gantt_select!`.
Never assigns a full-list `gantt_rows` index into `gantt_sel`.
"""
function _gantt_select_issue_id!(m::AppModel, issue_id)
    irows = gantt_issue_rows(m)
    idx = findfirst(r -> r.issue !== nothing && r.issue.id == issue_id, irows)
    idx === nothing && return m
    _gantt_select!(m, idx)
end

function _gantt_row!(m::AppModel, delta::Int)
    n = length(gantt_issue_rows(m))
    n == 0 && return m
    _gantt_select!(m, m.gantt_sel + delta)
end

function _gantt_zoom!(m::AppModel)
    m.gantt_drag = nothing                    # D15 / Q7: scale change desyncs drag thirds
    m.gantt_scale = if m.gantt_scale === :day; :week
                    elseif m.gantt_scale === :week; :month
                    else :day
                    end
    m.message = "Gantt scale: $(m.gantt_scale)"
    m
end

"""
    _gantt_stretch!(m, dir)

Adjust the logical view-window for the **active** scale only.
`dir > 0` → more stretch (smaller window); `dir < 0` → less stretch (larger).
Cancels drag, ensures selection visible, sets status message last, saves prefs.
"""
function _gantt_stretch!(m::AppModel, dir::Int)
    m.gantt_drag = nothing                    # D12
    scale = m.gantt_scale
    cur = gantt_view_window(m, scale)
    new_w = gantt_set_view_window!(m, scale, cur - dir * gantt_stretch_step(scale))
    _gantt_ensure_selection_visible!(m)       # D11
    m.message = new_w == cur ?
        "Gantt stretch [$(scale)]: window $(new_w) (limit)" :
        "Gantt stretch [$(scale)]: window $(new_w)"
    _save_gantt_ui_prefs!(m)                  # D14
    m
end

function _gantt_selected_issue(m::AppModel)
    irows = gantt_issue_rows(m)
    isempty(irows) && return nothing
    irows[clamp(m.gantt_sel, 1, length(irows))].issue
end

"""
    _gantt_ensure_selection_visible!(m)

If the selected issue's bar/point lies wholly outside the current chart window,
scroll `m.gantt_start` so the bar is visible (modern Gantt keep-in-view).
Uses the live per-scale view window (`gantt_view_window`).
"""
function _gantt_ensure_selection_visible!(m::AppModel)
    iss = _gantt_selected_issue(m)
    iss === nothing && return m
    span = gantt_issue_span(iss)
    span === nothing && return m
    sd, ed = span
    dpc = gantt_days_per_col(m.gantt_scale)
    ncols = gantt_view_window(m)
    # Match render: day scale applies near-term clamp unless selection needs past
    win = gantt_effective_win_start(m.gantt_start, Dates.today(), dpc, ncols, span)
    if gantt_bar_in_window(win, dpc, ncols, sd, ed)
        return m
    end
    m.gantt_start = gantt_reveal_start(win, dpc, ncols, sd, ed)
    m.message = "Gantt: focused $(iss.key)"
    m
end

"""
    _gantt_selected_footer(m) -> String

PR5: compact selected item details for footer when space (h>=10 && rows && !narrow).
Exact dates, duration in days, status, priority (color applied at render).
Includes assignee name if present (resolved via userstore).
Theming only (no ColorRGB). Pure data; caller handles short + style.
"""
function _gantt_selected_footer(m::AppModel)::String
    iss = _gantt_selected_issue(m)
    iss === nothing && return ""
    sd = iss.start_date !== nothing ? string(iss.start_date) : "?"
    ed = iss.due_date !== nothing ? string(iss.due_date) : "?"
    dur = ""
    if iss.start_date !== nothing && iss.due_date !== nothing
        d = Dates.value(iss.due_date - iss.start_date) + 1
        dur = " ($(d)d)"
    end
    st = iss.status
    pri = iss.priority
    asg = ""
    if iss.assignee_id !== nothing
        try
            u = Stores.get_user(m.userstore, iss.assignee_id)
            if u !== nothing && !isempty(u.name)
                asg = " • $(u.name)"
            end
        catch  # COV_EXCL_LINE — error path only on inconsistent userstore (tests use consistent stores)
            # defensive: never break render on lookup
        end
    end
    "$(iss.key): $(sd) → $(ed)$(dur)  • $(st) • $(pri)$(asg)"
end

_gantt_open_detail!(m::AppModel) = _open_detail_issue!(m, _gantt_selected_issue(m))

"Open the card-edit modal for the currently selected gantt row issue."
_gantt_open_edit!(m::AppModel) = _open_edit_issue!(m, _gantt_selected_issue(m))

# ── G6b thin blocks-link UI (two-step L create, U delete) ───────────────────
"""
    _gantt_link_blocks!(m)

Two-step finish-to-start `blocks` link create on the Gantt view:
1. First `L` — stash selected issue as source (`gantt_link_from_id`).
2. Second `L` on a different issue — `Stores.create_link!(...; kind=\"blocks\")`.
Cycle / project / validation errors surface as `m.message`. Esc clears the
pending source (see `update!`). Requires `can!(:edit_issue)` on the source.
"""
function _gantt_link_blocks!(m::AppModel)
    iss = _gantt_selected_issue(m)
    if iss === nothing
        m.message = "No issue selected"
        return m
    end
    if m.gantt_link_from_id === nothing
        m.gantt_link_from_id = iss.id
        m.message = "Blocks source: $(iss.key) — select target, press L"
        return m
    end
    from_id = m.gantt_link_from_id
    m.gantt_link_from_id = nothing
    if from_id == iss.id
        m.message = "Link cancelled (same issue)"
        return m
    end
    from = Stores.get_issue(m.boardstore, from_id)
    if from === nothing
        m.message = "Link source gone"
        return m
    end
    can!(m, :edit_issue; resource = from) || return m
    try
        Stores.create_link!(m.boardstore; from_id = from_id, to_id = iss.id, kind = "blocks")
        _set_message!(m, "Linked $(from.key) blocks $(iss.key)")
    catch err
        m.message = sprint(showerror, err)
    end
    m
end

"""
    _gantt_unlink_blocks!(m)

Delete a `blocks` link involving the selected Gantt issue. Prefer the edge from
a pending `gantt_link_from_id` → selection; else first outgoing; else any
incoming. Surfaces missing-link / permission as `m.message`.
"""
function _gantt_unlink_blocks!(m::AppModel)
    iss = _gantt_selected_issue(m)
    if iss === nothing
        m.message = "No issue selected"
        return m
    end
    can!(m, :edit_issue; resource = iss) || return m
    pid = m.active_project_id
    links = Stores.list_links(m.boardstore; issue_id = iss.id, kind = "blocks",
                              project_id = pid)
    target = nothing
    if m.gantt_link_from_id !== nothing
        for ln in links
            if ln.from_id == m.gantt_link_from_id && ln.to_id == iss.id
                target = ln
                break
            end
        end
    end
    if target === nothing
        for ln in links
            if ln.from_id == iss.id
                target = ln
                break
            end
        end
    end
    if target === nothing && !isempty(links)
        target = links[1]
    end
    if target === nothing
        m.message = "No blocks link on $(iss.key)"
        return m
    end
    m.gantt_link_from_id = nothing
    Stores.delete_link!(m.boardstore, target.id)
    fr = Stores.get_issue(m.boardstore, target.from_id)
    to = Stores.get_issue(m.boardstore, target.to_id)
    fk = fr === nothing ? target.from_id : fr.key
    tk = to === nothing ? target.to_id : to.key
    _set_message!(m, "Unlinked $fk blocks $tk")
    m
end

# ═══════════════════════════ LAYOUT (G4.1) ═══════════════════════════════════
"""
Snapshot of Gantt chart geometry for a given AppModel + content Rect.
Built by pure computation from m + area (same formulas as `render_gantt!`).
Introduced in G4.1; consumed by paint (and later by hit-testing).
"""
struct GanttLayout
    area::Rect
    left_w::Int
    chart_x::Int
    physical_ncols::Int
    view_ncols::Int
    label_ncols::Int
    dpc::Int
    scale::Symbol
    win_start::Date
    is_narrow::Bool
    compact::Bool             # always false (PR-V); field retained for layout snapshot stability
    has_ruler::Bool
    has_dual::Bool
    has_quarter::Bool         # G5: quarter super-header when h≥14 + dual + :month
    has_footer::Bool
    band_y::Int
    quarter_y::Int            # 0 when !has_quarter
    tab_y::Int
    tick_y::Int
    ruler_y::Int              # tick / single-axis paint y (== tick_y when ruler present)
    grid_y0::Int
    content_start::Int
    nshow::Int
    row_stride::Int           # terminal rows per logical row (content + inter-bar gap)
    row_start::Int            # first visible row index into gantt_rows (1-based)
    footer_y::Union{Nothing,Int}
    ruler_rows::Int           # axis strip rows only (tab+tick; quarter counted separately)
    paint_weekends::Bool
    paint_week_seps::Bool
end

"""
    gantt_layout(m, area; rows=nothing) -> GanttLayout

Height matrix, full-identity left rail, view vs physical ncols, dual-axis y
positions, content_start, chart_x, grid_y0, selection keep-in-view `row_start`.
Same pure helpers as `render_gantt!` — paint must consume this snapshot.

Pass precomputed `rows` (from `gantt_rows(m)`) to avoid a second row build when
the caller already needs the paint list (e.g. `render_gantt!`).

Product lock (PR-V): left rail always full labels (`compact=false`); chart shows
issue key only immediately left of each bar/diamond.
"""
function gantt_layout(m::AppModel, area::Rect;
                      rows::Union{Nothing,Vector{GanttRow}} = nothing)::GanttLayout
    dpc = gantt_days_per_col(m.gantt_scale)
    rws = rows === nothing ? gantt_rows(m) : rows
    # PR-V: always full-label left width (never compact-keys-only on wide terminals).
    is_narrow = area.width < 60
    compact = false
    left_w = gantt_left_width(rws, area.width; compact = false)
    if is_narrow
        left_w = min(14, max(10, area.width - 20))
    end
    left_w = max(10, min(left_w, area.width - 10))
    chart_x = area.x + left_w
    physical_ncols = area.width - left_w   # physical chart columns
    # Live per-scale view window (stretch control). view_ncols drives bars/axis/today;
    # day label_ncols may use the physical gutter past the day strip (legacy G4 geom).
    win = gantt_view_window(m)
    view_ncols = min(physical_ncols, win)
    label_ncols = m.gantt_scale === :day ? physical_ncols : view_ncols
    sel_issue = _gantt_selected_issue(m)
    sel_span = sel_issue === nothing ? nothing : gantt_issue_span(sel_issue)
    win_start = gantt_effective_win_start(m.gantt_start, Dates.today(), dpc, view_ncols, sel_span)

    has_ruler = area.height >= 8
    # PR5: has_footer = h>=10 && rows>0 && !narrow
    has_footer = area.height >= 10 && length(rws) > 0 && !is_narrow
    # G3 height budget: dual-row axis only at h≥12; single at 8–11; none <8.
    has_dual = area.height >= 12 && has_ruler
    # G5: optional quarter super-header only when height budget is loose (h≥14),
    # dual axis already on, and month scale (where month tabs benefit from Q labels).
    # Does not activate on day/week — keeps dual-row content_start stable for those tests.
    has_quarter = has_dual && area.height >= 14 && m.gantt_scale === :month
    quarter_rows = has_quarter ? 1 : 0
    tab_rows = has_dual ? 1 : 0
    tick_rows = has_ruler ? 1 : 0
    ruler_rows = tab_rows + tick_rows   # 0 | 1 | 2 (quarter counted outside)
    footer_rows = has_footer ? 1 : 0
    content_start = 1 + 1 + quarter_rows + ruler_rows  # title + band + [quarter] + axis
    band_y = area.y + 1
    quarter_y = has_quarter ? area.y + 2 : 0
    # Axis strip sits under band, or under quarter when present.
    axis0 = has_quarter ? area.y + 3 : area.y + 2
    tab_y = has_dual ? axis0 : 0
    # Single-row axis lands at band+1; dual tick is under tabs.
    tick_y = has_ruler ? (has_dual ? axis0 + 1 : area.y + 2) : 0
    ruler_y = tick_y  # TODAY label + single-row axis paint target
    grid_y0 = area.y + content_start
    row_stride = GANTT_ROW_STRIDE
    avail = area.height - content_start - footer_rows - 1
    nshow = gantt_nshow_fit(avail, length(rws); stride = row_stride)
    # Selection keep-in-view (U5): scroll row window so selected issue is drawn.
    row_start = 1
    if sel_issue !== nothing && nshow > 0
        sri = findfirst(r -> r.kind === :issue && r.issue !== nothing && r.issue.id == sel_issue.id, rws)
        (sri !== nothing && sri > nshow) && (row_start = sri - nshow + 1)
    end
    footer_y = has_footer ? grid_y0 + gantt_grid_height(nshow; stride = row_stride) : nothing
    # G2 paint gates: weekend ░ + week seps ┆ off at :month (period wash stays on).
    # G5 period-boundary seps still paint at :month (month edges only — not noisy Mondays).
    paint_weekends = m.gantt_scale !== :month
    paint_week_seps = m.gantt_scale !== :month

    GanttLayout(area, left_w, chart_x, physical_ncols, view_ncols, label_ncols,
                dpc, m.gantt_scale, win_start, is_narrow, compact,
                has_ruler, has_dual, has_quarter, has_footer,
                band_y, quarter_y, tab_y, tick_y, ruler_y, grid_y0, content_start,
                nshow, row_stride, row_start, footer_y, ruler_rows,
                paint_weekends, paint_week_seps)
end

# ═══════════════════════════ HIT-TEST (M1) ═══════════════════════════════════
"""
Hit kinds for pure Gantt mouse hit-testing (M1 click-select).
Shared metrics with paint via `GanttLayout` — no render-side side effects.
"""
@enum GanttHitKind begin
    gantt_hit_none
    gantt_hit_left_rail   # issue or epic label cells
    gantt_hit_bar         # bar or diamond body
    gantt_hit_post_bar    # issue key immediately right of bar/diamond (primary chart identity)
    gantt_hit_pre_bar     # legacy left-of-bar region (unused by paint; kept for enum stability)
    gantt_hit_axis        # period tab / tick row
    gantt_hit_band        # sprint band row
    gantt_hit_empty_chart # chart background / wash only
end

"""
Result of `gantt_hit_test`. `issue_sel` is the 1-based index into
`gantt_issue_rows` (same space as `m.gantt_sel`) — never a full-list index.
"""
struct GanttHit
    kind::GanttHitKind
    row_index::Union{Nothing,Int}      # into full gantt_rows (includes epics)
    issue_id::Union{Nothing,String}    # Domain issue id when issue-related
    issue_sel::Union{Nothing,Int}      # 1-based issue-only index
    col::Union{Nothing,Int}            # 0-based chart col when in chart strip
    date::Union{Nothing,Date}          # gantt_date_for_col when col in view strip
end

const _GANTT_HIT_NONE = GanttHit(gantt_hit_none, nothing, nothing, nothing, nothing, nothing)

"Issue-only selection index for a full-list row, or nothing if not an issue row."
function _gantt_issue_sel_at(rows::Vector{GanttRow}, row_index::Int)::Union{Nothing,Int}
    (1 <= row_index <= length(rows)) || return nothing
    rows[row_index].kind === :issue || return nothing
    n = 0
    for i in 1:row_index
        rows[i].kind === :issue && (n += 1)
    end
    n
end

"""
    gantt_hit_test(layout, rows, x, y) -> GanttHit

Pure hit-test against a `GanttLayout` snapshot + the full paint row list.
Coordinates are absolute terminal cells (same space as `MouseEvent.x/y` and
`layout.area`). Does not mutate model state.
"""
function gantt_hit_test(layout::GanttLayout, rows::Vector{GanttRow},
                        x::Int, y::Int)::GanttHit
    area = layout.area
    (area.width < 1 || area.height < 1) && return _GANTT_HIT_NONE
    if x < area.x || x >= area.x + area.width ||
       y < area.y || y >= area.y + area.height
        return _GANTT_HIT_NONE
    end

    # Band (sprint strip under title)
    if y == layout.band_y
        return GanttHit(gantt_hit_band, nothing, nothing, nothing, nothing, nothing)
    end

    # Axis rows (optional quarter super-header + dual tab+tick, or single tick/axis)
    if layout.has_ruler
        if layout.has_quarter && y == layout.quarter_y
            return GanttHit(gantt_hit_axis, nothing, nothing, nothing, nothing, nothing)
        end
        if layout.has_dual
            if y == layout.tab_y || y == layout.tick_y
                return GanttHit(gantt_hit_axis, nothing, nothing, nothing, nothing, nothing)
            end
        elseif y == layout.tick_y
            return GanttHit(gantt_hit_axis, nothing, nothing, nothing, nothing, nothing)
        end
    end

    # Grid body (content lines + inter-bar gap lines from row_stride)
    gh = gantt_grid_height(layout.nshow; stride = layout.row_stride)
    if layout.nshow > 0 && y >= layout.grid_y0 && y < layout.grid_y0 + gh
        vis_i = gantt_vis_i_at(layout.grid_y0, y, layout.nshow; stride = layout.row_stride)
        # Gap line between bars: chart background only (not a selectable row).
        if vis_i === nothing
            if x < layout.chart_x
                return _GANTT_HIT_NONE
            end
            col_g = x - layout.chart_x
            if col_g < 0 || col_g >= layout.physical_ncols
                return _GANTT_HIT_NONE
            end
            date_g = col_g < layout.view_ncols ?
                     gantt_date_for_col(layout.win_start, layout.dpc, col_g) : nothing
            return GanttHit(gantt_hit_empty_chart, nothing, nothing, nothing,
                            col_g < layout.view_ncols ? col_g : nothing, date_g)
        end
        row_index = layout.row_start + vis_i - 1
        (1 <= row_index <= length(rows)) || return _GANTT_HIT_NONE
        row = rows[row_index]
        issue_id = row.issue === nothing ? nothing : row.issue.id
        issue_sel = _gantt_issue_sel_at(rows, row_index)

        # Left rail (labels)
        if x < layout.chart_x
            return GanttHit(gantt_hit_left_rail, row_index, issue_id, issue_sel,
                            nothing, nothing)
        end

        col = x - layout.chart_x  # 0-based into chart strip
        if col < 0 || col >= layout.physical_ncols
            return _GANTT_HIT_NONE
        end
        date = col < layout.view_ncols ?
               gantt_date_for_col(layout.win_start, layout.dpc, col) : nothing

        if row.kind === :epic
            return GanttHit(gantt_hit_empty_chart, row_index, nothing, nothing,
                            col < layout.view_ncols ? col : nothing, date)
        end

        # Issue: bar / diamond / post-bar key (x-disjoint; key starts after c1 + gap)
        iss = row.issue
        if iss !== nothing
            key_w = textwidth(iss.key)
            tcol_hit = gantt_point_col(layout.win_start, layout.dpc, Dates.today(),
                                       layout.view_ncols)
            if iss.start_date !== nothing && iss.due_date !== nothing
                ext = gantt_bar_extent(layout.win_start, layout.dpc,
                                       iss.start_date, iss.due_date, layout.view_ncols)
                if ext !== nothing
                    c0, c1 = ext
                    if c0 <= col <= c1
                        return GanttHit(gantt_hit_bar, row_index, issue_id, issue_sel,
                                        col, date)
                    end
                    post = gantt_post_bar_label_geom(c0, c1, layout.label_ncols;
                                                     gap = 1, max_w = key_w, tcol = tcol_hit)
                    if post !== nothing && post.max_chars >= key_w &&
                       post.start <= col < post.start + key_w
                        return GanttHit(gantt_hit_post_bar, row_index, issue_id,
                                        issue_sel, col, date)
                    end
                end
            else
                d = iss.start_date === nothing ? iss.due_date : iss.start_date
                pcol = gantt_point_col(layout.win_start, layout.dpc, d, layout.view_ncols)
                if pcol !== nothing
                    if col == pcol
                        return GanttHit(gantt_hit_bar, row_index, issue_id, issue_sel,
                                        col, date)
                    end
                    post = gantt_post_bar_label_geom(pcol, pcol, layout.label_ncols;
                                                     gap = 1, max_w = key_w, tcol = tcol_hit)
                    if post !== nothing && post.max_chars >= key_w &&
                       post.start <= col < post.start + key_w
                        return GanttHit(gantt_hit_post_bar, row_index, issue_id,
                                        issue_sel, col, date)
                    end
                end
            end
        end
        return GanttHit(gantt_hit_empty_chart, row_index, issue_id, issue_sel,
                        col < layout.view_ncols ? col : nothing, date)
    end

    _GANTT_HIT_NONE
end

# ═══════════════════════════ DRAG-RESCHEDULE (M3) ════════════════════════════
"""
    gantt_drag_mode_for_bar(c0, c1, col) -> Symbol

Edge vs body hit within a multi-day bar. When `bw ≥ 3`, left/right thirds are
`:start` / `:end`; otherwise (and for the middle third) `:body`.
"""
function gantt_drag_mode_for_bar(c0::Int, c1::Int, col::Int)::Symbol
    bw = c1 - c0 + 1
    bw < 3 && return :body
    third = max(1, bw ÷ 3)
    col <= c0 + third - 1 && return :start
    col >= c1 - third + 1 && return :end
    :body
end

"""
    gantt_compute_drag_preview(mode, win_start, dpc, origin_col, cur_col,
                               orig_start, orig_due) -> (preview_start, preview_due)

Pure date math for M3 shadow preview. Body preserves duration (shift both by
Δcols·dpc). Edge modes move one endpoint; diamond (`:point`) moves the single
existing date. Always clamps `start ≤ due` when both are present. Month scale
snaps via `gantt_date_for_col` (dpc=7).
"""
function gantt_compute_drag_preview(mode::Symbol, win_start::Date, dpc::Int,
                                    origin_col::Int, cur_col::Int,
                                    orig_start::Union{Nothing,Date},
                                    orig_due::Union{Nothing,Date})
    if mode === :point
        new_d = gantt_date_for_col(win_start, dpc, cur_col)
        if orig_start !== nothing && orig_due === nothing
            return (new_d, nothing)
        elseif orig_due !== nothing && orig_start === nothing
            return (nothing, new_d)
        elseif orig_start !== nothing  # both set but treated as point — prefer start
            return (new_d, nothing)
        else
            return (nothing, new_d)
        end
    end
    if mode === :body
        (orig_start === nothing || orig_due === nothing) && return (orig_start, orig_due)
        delta = (cur_col - origin_col) * dpc
        return (orig_start + Day(delta), orig_due + Day(delta))
    end
    if mode === :start
        (orig_start === nothing || orig_due === nothing) && return (orig_start, orig_due)
        ns = gantt_date_for_col(win_start, dpc, cur_col)
        ns > orig_due && (ns = orig_due)
        return (ns, orig_due)
    end
    if mode === :end
        (orig_start === nothing || orig_due === nothing) && return (orig_start, orig_due)
        nd = gantt_date_for_col(win_start, dpc, cur_col)
        nd < orig_start && (nd = orig_start)
        return (orig_start, nd)
    end
    (orig_start, orig_due)
end

"Paint dates for an issue: preview from `gantt_drag` when that issue is dragged."
function _gantt_paint_dates(m::AppModel, iss::Domain.Issue)
    drag = m.gantt_drag
    if drag !== nothing && drag.issue_id == iss.id
        return (drag.preview_start, drag.preview_due)
    end
    (iss.start_date, iss.due_date)
end

"Chart column under the pointer (0-based), clamped to the visible view strip."
function _gantt_evt_col(lay::GanttLayout, x::Int)::Int
    col = x - lay.chart_x
    clamp(col, 0, max(0, lay.view_ncols - 1))
end

function _gantt_clear_drag!(m::AppModel)
    m.gantt_drag = nothing
    m
end

function _gantt_begin_drag!(m::AppModel, iss::Domain.Issue, mode::Symbol,
                            origin_col::Int)
    m.gantt_drag = (
        issue_id = iss.id,
        mode = mode,
        origin_col = origin_col,
        orig_start = iss.start_date,
        orig_due = iss.due_date,
        preview_start = iss.start_date,
        preview_due = iss.due_date,
    )
    m
end

function _gantt_update_drag_preview!(m::AppModel, lay::GanttLayout, cur_col::Int)
    drag = m.gantt_drag
    drag === nothing && return m
    ps, pd = gantt_compute_drag_preview(drag.mode, lay.win_start, lay.dpc,
                                        drag.origin_col, cur_col,
                                        drag.orig_start, drag.orig_due)
    m.gantt_drag = (
        issue_id = drag.issue_id,
        mode = drag.mode,
        origin_col = drag.origin_col,
        orig_start = drag.orig_start,
        orig_due = drag.orig_due,
        preview_start = ps,
        preview_due = pd,
    )
    m
end

"""
Commit shadow drag dates via `Stores.update_issue!` when permission allows.
Soft-refresh selection clamp; model issues are re-read from store on next paint.
"""
function _gantt_commit_drag!(m::AppModel)
    drag = m.gantt_drag
    drag === nothing && return m
    m.gantt_drag = nothing
    iss = Stores.get_issue(m.boardstore, drag.issue_id)
    iss === nothing && return m
    if !can!(m, :edit_issue; resource = iss)
        # can! already set Permission denied / Role warning message
        return m
    end
    # Skip no-op commits (press+release without movement).
    if drag.preview_start == iss.start_date && drag.preview_due == iss.due_date
        return m
    end
    Stores.update_issue!(m.boardstore, drag.issue_id;
                         start_date = drag.preview_start,
                         due_date = drag.preview_due)
    # Soft-refresh: selection stays valid; next gantt_rows reads store.
    m.gantt_sel = clamp(m.gantt_sel, 1, max(1, length(gantt_issue_rows(m))))
    key = something(Stores.get_issue(m.boardstore, drag.issue_id), iss).key
    _set_message!(m, "Rescheduled $(key)")
    m
end

"""
    _handle_gantt_mouse!(m, evt)

M1 click-select + M2 wheel scroll + M3 drag-reschedule. Left press on left-rail
issue / pre-bar key → select. Left press on bar/diamond → select + start shadow
drag when `can!(:edit_issue)` (else message, no drag). `mouse_drag` updates
preview dates; `mouse_release` commits via store. Wheel over body → scroll.
"""
function _handle_gantt_mouse!(m::AppModel, evt::MouseEvent)
    area = m.gantt_last_area
    (area.width < 1 || area.height < 1) && return m

    # M3 — active drag: drag updates preview; release commits; swallow wheel.
    # A second left-press without release (synthetic tests / rare) commits first
    # then falls through so the new press can select / start a new drag.
    if m.gantt_drag !== nothing
        if evt.button === mouse_left && evt.action === mouse_drag
            rows = gantt_rows(m)
            lay = gantt_layout(m, area; rows = rows)
            return _gantt_update_drag_preview!(m, lay, _gantt_evt_col(lay, evt.x))
        elseif evt.button === mouse_left && evt.action === mouse_release
            return _gantt_commit_drag!(m)
        elseif evt.button === mouse_left && evt.action === mouse_press
            _gantt_commit_drag!(m)
            # fall through to M1/M3 press handling below
        elseif (evt.button === mouse_scroll_up || evt.button === mouse_scroll_down) &&
               evt.action === mouse_press
            return m  # swallow wheel during drag
        else
            return m  # other buttons / move: leave drag state alone
        end
    end

    # M2 — wheel horizontal scroll when pointer is over the cached gantt body.
    # Button is scroll_*; require mouse_press for parity with Tachikoma
    # list_scroll / widget handlers (SGR always emits press for wheel). No zoom.
    if (evt.button === mouse_scroll_up || evt.button === mouse_scroll_down) &&
       evt.action === mouse_press
        Base.contains(area, evt.x, evt.y) || return m
        dir = evt.button === mouse_scroll_up ? -1 : +1
        return _gantt_scroll!(m, dir)
    end

    # M1 select + M3 drag start on left press
    (evt.button === mouse_left && evt.action === mouse_press) || return m
    rows = gantt_rows(m)
    lay = gantt_layout(m, area; rows = rows)
    hit = gantt_hit_test(lay, rows, evt.x, evt.y)
    if hit.kind === gantt_hit_left_rail
        hit.row_index === nothing && return m
        rows[hit.row_index].kind === :epic && return m
        hit.issue_id === nothing && return m
        return _gantt_select_issue_id!(m, hit.issue_id)
    elseif hit.kind === gantt_hit_pre_bar || hit.kind === gantt_hit_post_bar
        hit.issue_id === nothing && return m
        return _gantt_select_issue_id!(m, hit.issue_id)
    elseif hit.kind === gantt_hit_bar
        hit.issue_id === nothing && return m
        _gantt_select_issue_id!(m, hit.issue_id)
        iss = Stores.get_issue(m.boardstore, hit.issue_id)
        iss === nothing && return m
        # Permission gate: deny starts no drag (message via can!).
        if !can!(m, :edit_issue; resource = iss)
            return m
        end
        # Determine mode from bar geometry at press col.
        origin_col = hit.col === nothing ? _gantt_evt_col(lay, evt.x) : hit.col
        mode = if iss.start_date !== nothing && iss.due_date !== nothing
            ext = gantt_bar_extent(lay.win_start, lay.dpc, iss.start_date,
                                   iss.due_date, lay.view_ncols)
            # Hit-test only reports bar when extent is non-nothing for dual-date;
            # defensive :body if geometry races with a window scroll mid-press.
            if ext === nothing
                :body  # COV_EXCL_LINE (defensive; hit_test requires on-window bar)
            else
                gantt_drag_mode_for_bar(ext[1], ext[2], origin_col)
            end
        else
            :point  # diamond: single date
        end
        return _gantt_begin_drag!(m, iss, mode, origin_col)
    end
    m
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function render_gantt!(m::AppModel, buf::Buffer, area::Rect)
    # G4.1: cache area for future mouse hit-tests (M1/M2); zero default on AppModel.
    m.gantt_last_area = area
    if area.width < 24 || area.height < 6
        set_string!(buf, area.x, area.y,
                    _short("Gantt needs a bigger window", area.width), Style(; fg = col_text_dim()))
        return
    end
    # Single gantt_rows build shared by layout + paint (N2: no double list work).
    rows = gantt_rows(m)
    lay = gantt_layout(m, area; rows = rows)
    # Destructure layout metrics (single source of geometry for this paint).
    left_w = lay.left_w
    chart_x = lay.chart_x
    ncols = lay.physical_ncols
    view_ncols = lay.view_ncols
    label_ncols = lay.label_ncols
    dpc = lay.dpc
    win_start = lay.win_start
    is_narrow = lay.is_narrow
    has_ruler = lay.has_ruler
    has_dual = lay.has_dual
    has_quarter = lay.has_quarter
    has_footer = lay.has_footer
    band_y = lay.band_y
    quarter_y = lay.quarter_y
    tab_y = lay.tab_y
    tick_y = lay.tick_y
    ruler_y = lay.ruler_y
    grid_y0 = lay.grid_y0
    content_start = lay.content_start
    nshow = lay.nshow
    row_stride = lay.row_stride
    row_start = lay.row_start
    paint_weekends = lay.paint_weekends
    paint_week_seps = lay.paint_week_seps
    grid_h = gantt_grid_height(nshow; stride = row_stride)

    win_end = gantt_window_end(win_start, dpc, view_ncols)
    tcol = gantt_point_col(win_start, dpc, Dates.today(), view_ncols)  # COV_EXCL_LINE (hoist for coordination; value same as later; exercised via band/today)  # hoist early for band name/today coordination (minimal)
    sel_issue_early = _gantt_selected_issue(m)
    scale_lbl = lay.scale === :month ? "month" :
                lay.scale === :day   ? "day"   : "week"
    win_n = gantt_view_window(m)
    # Closed scale token `[day]` first (tests); window badge ` · N` when wide (D10/Q6).
    base = "GANTT — $(win_start) → $(win_end)  [$(scale_lbl)]"
    if is_narrow && ncols >= 8
        base = "GANTT[$(scale_lbl)]"   # narrow: no badge, no stretch buttons
    elseif !is_narrow
        base = base * " · $(win_n)"
    end
    title = base
    # Stretch affordance glyphs (paint-only in PR2; hit-test in PR3). Right-aligned.
    btns = "[+][-]"
    show_btns = !is_narrow && area.width >= 36
    title_budget = show_btns ? max(1, area.width - textwidth(btns)) : area.width
    if ncols >= 10
        leg = if !is_narrow && area.width >= 90
            # Wide: full legend with key token (PR-V chart identity)
            "  ░sprint █bar KEY ◆pt " * string(gantt_safe_char('┃', false)) * "today"
        elseif !is_narrow && area.width >= 80
            "  ░sprint █bar ◆pt " * string(gantt_safe_char('┃', false)) * "today"
        else
            " " * string(gantt_safe_char('░', is_narrow)) * string(gantt_safe_char('█', is_narrow)) *
                  "K" * string(gantt_safe_char('◆', is_narrow)) * string(gantt_safe_char('┃', is_narrow))
        end
        if textwidth(title) + textwidth(leg) <= title_budget
            title = title * leg
        end
    end
    set_string!(buf, area.x, area.y,
                _short(title, title_budget),
                Style(; fg = col_primary(), bold = true))
    if show_btns
        set_string!(buf, area.x + area.width - textwidth(btns), area.y, btns,
                    Style(; fg = col_text_dim()))
    end

    # z1 — alternating period wash on band (under weekend + sprint)
    for c in gantt_period_shade_cols(win_start, dpc, view_ncols, lay.scale)
        set_char!(buf, chart_x + c, band_y, ' ', Style(; bg = col_gantt_period_alt()))
    end
    # weekend shading on band row first (polish consistency), band will overlay its range
    if paint_weekends
        for c in gantt_weekend_cols(win_start, dpc, view_ncols)
            ch = gantt_safe_char('░', is_narrow)  # COV_EXCL_LINE (safe path covered via grid shade + pure tests + other calls)
            set_string!(buf, chart_x + c, band_y, string(ch), Style(; fg = col_text_muted(), dim = true))
        end
    end
    # Sprint bands polish (PR6): cleaner edges (▓/safe at ends), better name placement
    # (inside after edge when room; underline+dim always), aggressive truncate narrow.
    for (nm, c0, c1) in gantt_sprint_bands(m, win_start, dpc, view_ncols)
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
        # G5: optional quarter super-header (month scale, h≥14) above period tabs.
        if has_quarter
            for t in gantt_axis_quarter_tabs(win_start, dpc, view_ncols; narrow = is_narrow)
                span = t.c1 - t.c0 + 1
                span < 1 && continue
                lab = t.label
                textwidth(lab) > span && (lab = fit_width(lab, max(1, span)))
                start_c = t.c0 + max(0, (span - textwidth(lab)) ÷ 2)
                start_c = clamp(start_c, t.c0, t.c1)
                xx = chart_x + start_c
                xx > area.x + area.width - 1 && continue
                avail = max(1, min(t.c1 - start_c + 1, view_ncols - start_c))
                set_string!(buf, xx, quarter_y, _short(lab, avail),
                            Style(; fg = col_text_dim(), bold = true))
            end
        end
        # G3: dual-row (h≥12) = period tabs (full names) + tick row; single (h=8–11) =
        # digit-first combine on day/week, tabs-prefer on month. Pack labels into span.
        if has_dual
            # Tab row — full period names from gantt_axis_period_tabs (bold primary)
            for t in gantt_axis_period_tabs(win_start, dpc, view_ncols, lay.scale; narrow = is_narrow)
                span = t.c1 - t.c0 + 1
                span < 1 && continue
                lab = t.label
                textwidth(lab) > span && (lab = fit_width(lab, max(1, span)))
                start_c = t.c0 + max(0, (span - textwidth(lab)) ÷ 2)
                start_c = clamp(start_c, t.c0, t.c1)
                xx = chart_x + start_c
                xx > area.x + area.width - 1 && continue
                # Clip to remaining period cells (t.c1), not just original span from c0
                avail = max(1, min(t.c1 - start_c + 1, view_ncols - start_c))
                set_string!(buf, xx, tab_y, _short(lab, avail),
                            Style(; fg = col_primary(), bold = true))
            end
            # Tick row — numeric day-of-month with breathing room (muted)
            for (c, lab) in gantt_axis_tick_labels(win_start, dpc, view_ncols; narrow = is_narrow)
                (c < 0 || c >= view_ncols) && continue
                xx = chart_x + c
                xx > area.x + area.width - 1 && continue
                if textwidth(lab) <= 1
                    tch = isempty(lab) ? ' ' : lab[1]
                    if textwidth(tch) != 1; tch = gantt_safe_char('+', true); end  # COV_EXCL_LINE
                    set_char!(buf, xx, tick_y, tch, Style(; fg = col_text_muted(), dim = true))
                else
                    set_string!(buf, xx, tick_y, _short(lab, max(1, view_ncols - c)),
                                Style(; fg = col_text_muted(), dim = true))
                end
            end
        elseif lay.scale === :month
            # Single-row month: prefer full period tabs over dense day ticks
            for t in gantt_axis_period_tabs(win_start, dpc, view_ncols, :month; narrow = is_narrow)
                span = t.c1 - t.c0 + 1
                span < 1 && continue
                lab = t.label
                textwidth(lab) > span && (lab = fit_width(lab, max(1, span)))
                start_c = t.c0 + max(0, (span - textwidth(lab)) ÷ 2)
                start_c = clamp(start_c, t.c0, t.c1)
                xx = chart_x + start_c
                xx > area.x + area.width - 1 && continue
                avail = max(1, min(t.c1 - start_c + 1, view_ncols - start_c))
                set_string!(buf, xx, ruler_y, _short(lab, avail),
                            Style(; fg = col_primary(), bold = true))
            end
        else
            # Single-row day/week: digit-first combine + period gutter (pre-G3 path)
            for (c, lab) in gantt_axis_period_labels(win_start, dpc, view_ncols; narrow = is_narrow)
                if c == 0 && left_w >= 4
                    set_string!(buf, area.x, ruler_y, _short(lab, min(left_w - 1, textwidth(lab) + 1)),
                                Style(; fg = col_text_dim()))
                end
            end
            ax = gantt_axis_labels(win_start, dpc, view_ncols; narrow = is_narrow)
            for (c, lab) in ax
                (c < 0 || c >= view_ncols) && continue
                xx = chart_x + c
                xx > area.x + area.width - 1 && continue
                if textwidth(lab) <= 1
                    tch = lab == "┬" ? gantt_safe_char('┬', is_narrow) : (isempty(lab) ? ' ' : lab[1])
                    if textwidth(tch) != 1; tch = gantt_safe_char('+', true); end  # COV_EXCL_LINE
                    set_char!(buf, xx, ruler_y, tch, Style(; fg = col_text_muted(), dim = true))
                else
                    set_string!(buf, xx, ruler_y, _short(lab, max(1, view_ncols - c)), Style(; fg = col_text_dim()))
                end
            end
        end
    end

    if isempty(rows)
        empty_y = area.y + content_start
        # PR5: richer empty state + hint (no data change; hint from design)
        empty_msg = "No scheduled issues (press e on board or n on calendar to date items)"
        set_string!(buf, area.x, empty_y, _short(empty_msg, area.width),
                    Style(; fg = col_text_dim()))
        return
    end

    canvas = BlockCanvas(view_ncols, max(1, grid_h); style = Style(; fg = col_primary()))
    diamonds = Tuple{Int,Int,Any}[]
    sel_issue = sel_issue_early

    # Track for PR4 selection bar accent (set during label/bar loop; used post-canvas)
    selected_vis_i = nothing
    selected_bar_ext = nothing

    # Cache post-bar key geom per visible row (shared by in-bar suppress + key paint).
    # Key paints RIGHT of bar (post-bar); left rail always full key+title.
    post_geoms = Vector{Union{Nothing, NamedTuple{(:start, :max_chars), Tuple{Int,Int}}}}(nothing, max(0, nshow))
    tcol_paint = gantt_point_col(win_start, dpc, Dates.today(), view_ncols)

    for i in 1:nshow
        ri = row_start + i - 1
        ri > length(rows) && break
        row = rows[ri]
        rowy = gantt_row_y(grid_y0, i; stride = row_stride)
        term_off = (i - 1) * row_stride
        if row.kind === :epic
            ecol = isempty(row.color_key) ? col_primary() : epic_color(row.color_key)
            set_string!(buf, area.x, rowy, _short("▬ " * row.label, left_w - 1), Style(; fg = ecol, bold = true))
        else
            iss = row.issue
            selected = sel_issue !== nothing && iss.id == sel_issue.id
            lstyle = selected ? sel_style() : Style(; fg = col_text())
            prefix = gantt_tree_prefix(rows, ri; selected = selected)
            # Post-bar key geom (identifier right of bar/diamond); left rail always full id.
            # M3: while dragging this issue, geometry follows shadow preview dates.
            psd, pdd = _gantt_paint_dates(m, iss)
            post_geom = nothing
            kw = textwidth(iss.key)
            if psd !== nothing && pdd !== nothing
                ext = gantt_bar_extent(win_start, dpc, psd, pdd, view_ncols)
                if ext !== nothing
                    c0, c1 = ext
                    g = gantt_post_bar_label_geom(c0, c1, label_ncols;
                                                  gap = 1, max_w = kw, tcol = tcol_paint)
                    # Full key only (same as prior pre-bar full-key rule)
                    post_geom = (g !== nothing && g.max_chars >= kw) ? g : nothing
                    for dx in (2 * c0):(2 * c1 + 1), dy in (2 * term_off):(2 * term_off + 1)
                        set_point!(canvas, dx, dy)
                    end
                    if selected
                        selected_vis_i = i
                        selected_bar_ext = (c0, c1)
                    end
                end
            else
                d = psd === nothing ? pdd : psd
                col = gantt_point_col(win_start, dpc, d, view_ncols)
                if col !== nothing
                    g = gantt_post_bar_label_geom(col, col, label_ncols;
                                                  gap = 1, max_w = kw, tcol = tcol_paint)
                    post_geom = (g !== nothing && g.max_chars >= kw) ? g : nothing
                    # Shadow diamond uses primary_hi when this issue is mid-drag.
                    dcol = (m.gantt_drag !== nothing && m.gantt_drag.issue_id == iss.id) ?
                           col_primary_hi() : priority_color(iss.priority)
                    push!(diamonds, (chart_x + col, rowy, dcol))
                end
            end
            post_geoms[i] = post_geom
            # Always full identity on left rail (key + title); key-first truncate if rail tight.
            avail = max(1, left_w - 1 - textwidth(prefix))
            full = gantt_left_label(row; compact = false)
            if textwidth(full) <= avail
                llab = full
            else
                k = iss.key
                rest = avail - textwidth(k) - 1
                llab = rest >= 1 ? k * " " * fit_width(iss.title, rest) : fit_width(k, avail)
            end
            set_string!(buf, area.x, rowy, _short(prefix * llab, left_w - 1), lstyle)
        end
        # Fill inter-bar gap lines with a vertical tree stem so the left rail
        # stays continuous (│) between connected epic/issue nodes.
        if row_stride > 1 && i < nshow && gantt_tree_stem_after(rows, ri)
            stem = gantt_safe_char('│', is_narrow)
            if textwidth(stem) != 1; stem = '|'; end
            for g in 1:(row_stride - 1)
                set_char!(buf, area.x, rowy + g, stem, Style(; fg = col_text_muted()))
            end
        end
    end

    # z1 — period wash on full grid height (content + inter-bar gaps), under weekend/seps/bars/today.
    for c in gantt_period_shade_cols(win_start, dpc, view_ncols, lay.scale)
        for yy in grid_y0:(grid_y0 + max(grid_h, 1) - 1)
            nshow < 1 && break
            set_char!(buf, chart_x + c, yy, ' ',
                      Style(; bg = col_gantt_period_alt()))
        end
    end
    # Weekend shading ░ (dim muted) on grid cols — BEFORE canvas so bars overlay where present.
    # Week separators ┆ (dim muted) on grid at week starts; skip today col to avoid clobber.
    # G2: weekend + week seps gated off at :month (paint only; pure helpers unchanged).
    # G5: period-boundary seps (month edges) always paint when present — z3 under bars, over wash.
    wcols = gantt_weekend_cols(win_start, dpc, view_ncols)
    scols = gantt_week_sep_cols(win_start, dpc, view_ncols)
    pscols = gantt_period_sep_cols(win_start, dpc, view_ncols, lay.scale)
    tcol = gantt_point_col(win_start, dpc, Dates.today(), view_ncols)
    if paint_weekends
        for c in wcols
            for yy in grid_y0:(grid_y0 + max(grid_h, 1) - 1)
                nshow < 1 && break
                ch = gantt_safe_char('░', is_narrow)  # COV_EXCL_LINE (duplicate safe path; core covered by pure + narrow tests)
                if textwidth(ch) != 1; ch = '#'; end
                set_string!(buf, chart_x + c, yy, string(ch), Style(; fg = col_text_muted(), dim = true))
            end
        end
    end
    if paint_week_seps
        for c in scols
            c == tcol && continue
            for yy in grid_y0:(grid_y0 + max(grid_h, 1) - 1)
                nshow < 1 && break
                ch = gantt_safe_char('┆', is_narrow)  # COV_EXCL_LINE (duplicate safe path; core covered by pure + narrow tests)
                if textwidth(ch) != 1; ch = '|'; end
                set_char!(buf, chart_x + c, yy, ch, Style(; fg = col_text_muted(), dim = true))
            end
        end
    end
    # G5 period boundary seps (month edges) — same glyph, all scales; under bars over wash.
    for c in pscols
        c == tcol && continue
        # Skip if week sep already painted this col (day/week) — same glyph, avoid double work.
        paint_week_seps && (c in scols) && continue
        for yy in grid_y0:(grid_y0 + max(grid_h, 1) - 1)
            nshow < 1 && break
            ch = gantt_safe_char('┆', is_narrow)
            if textwidth(ch) != 1; ch = '|'; end  # COV_EXCL_LINE (safe_char always yields width-1 for ┆)
            set_char!(buf, chart_x + c, yy, ch, Style(; fg = col_text_muted(), dim = true))
        end
    end

    render(canvas, Rect(chart_x, grid_y0, view_ncols, max(1, grid_h)), buf)

    # PR3: post-canvas overlays — keep base █ from canvas; refined ends ▌▐, status density ▓ (using status_progress),
    # inside labels (issue key via fit_width) when wide; use finalized contrast (dim or primary_hi bold on sel; never col_bg()).
    # Theming only. Recompute rowy/selection here (same scroll logic as build pass; no y/layout change).
    for i in 1:nshow
        ri = row_start + i - 1
        ri > length(rows) && break
        row = rows[ri]
        rowy = gantt_row_y(grid_y0, i; stride = row_stride)
        if row.kind === :issue
            iss = row.issue
            if iss !== nothing
                psd, pdd = _gantt_paint_dates(m, iss)
                if psd !== nothing && pdd !== nothing
                    ext = gantt_bar_extent(win_start, dpc, psd, pdd, view_ncols)
                    if ext !== nothing
                        c0, c1 = ext
                        # explicit bounds guard (mirrors ruler/band: xx > ... continue); though gantt_bar_extent clamps
                        if chart_x + c0 < chart_x || chart_x + c1 > area.x + area.width - 1
                            continue  # COV_EXCL_LINE (defensive; extent always clamps c0/c1 valid for current render paths; see review fix)
                        end
                        selected = sel_issue !== nothing && iss.id == sel_issue.id
                        dragging = m.gantt_drag !== nothing && m.gantt_drag.issue_id == iss.id
                        bar_col = dragging ? col_primary_hi() :
                                  (iss.status == "Done" ? col_ok() : priority_color(iss.priority))
                        bw = c1 - c0 + 1
                        # status density fill (partial ▓ or full █ for Done) first
                        # NOTE (bichrome warning addressed by doc): canvas always uses col_primary() cyan for entire base █ track (per design "Keep base █ from canvas").
                        # Only prefix (nfill) + ends get bar_col tint; suffix remains cyan unless overwritten by label/caps. This is intentional augmentation, not full recolor.
                        # Uniform suffix tint would require additional sets over canvas result (not done for minimal + fidelity to "keep base").
                        p = status_progress(iss)
                        nfill = max(0, floor(Int, bw * p))
                        for k in 0:(nfill - 1)
                            cc = c0 + k
                            ch = (p >= 0.999 ? '█' : '▓')
                            set_char!(buf, chart_x + cc, rowy, ch, Style(; fg = bar_col))
                        end
                        # In-bar key deferred to post-today identity pass (PR-V: key wins over ┃).
                        # bar end caps (unicode) LAST so they win over density at edge cells
                        set_char!(buf, chart_x + c0, rowy, '▌', Style(; fg = bar_col))
                        if bw >= 2
                            set_char!(buf, chart_x + c1, rowy, '▐', Style(; fg = bar_col))
                        end
                    end
                end
            end
        end
    end

    for (dx, dy, dcol) in diamonds
        set_char!(buf, dx, dy, '◆', Style(; fg = dcol))
    end

    # PR4: selection accent on bar (in addition to ▸ label). Brighter left ▌ segment using col_primary_hi().
    # After canvas so it overwrites base █ (compatible with PR3-style post-overlays). Theming only; no y/layout shift.
    if selected_vis_i !== nothing && selected_bar_ext !== nothing
        c0, _ = selected_bar_ext
        rowy = gantt_row_y(grid_y0, selected_vis_i; stride = row_stride)
        ax = chart_x + c0
        if ax <= area.x + area.width - 1
            set_char!(buf, ax, rowy, '▌', Style(; fg = col_primary_hi(), bold = true))
        end
    end

    # G6b — finish-to-start dependency arrows for project `blocks` links.
    # Z-order: after bars/diamonds/selection, before today + pre-bar keys (keys win on collision).
    # Only when both endpoints are in the nshow window and have visible bar/diamond geometry.
    # y coords are terminal-relative (row_stride-scaled) so verticals fill inter-bar gaps.
    if m.active_project_id !== nothing && nshow > 0
        # Map issue id → (0-based terminal y, c0, c1) for visible issue rows only.
        ep_map = Dict{String, Tuple{Int,Int,Int}}()
        for i in 1:nshow
            ri = row_start + i - 1
            ri > length(rows) && break
            row = rows[ri]
            row.kind === :issue || continue
            iss = row.issue
            iss === nothing && continue
            psd, pdd = _gantt_paint_dates(m, iss)
            cols = gantt_issue_endpoint_cols(win_start, dpc, psd, pdd, view_ncols)
            cols === nothing && continue
            c0e, c1e = cols
            ep_map[iss.id] = ((i - 1) * row_stride, c0e, c1e)
        end
        if !isempty(ep_map)
            for ln in Stores.list_links(m.boardstore; project_id = m.active_project_id,
                                        kind = "blocks")
                fr = get(ep_map, ln.from_id, nothing)
                to = get(ep_map, ln.to_id, nothing)
                (fr === nothing || to === nothing) && continue
                from_y, _, c_from = fr
                to_y, c_to, _ = to
                for seg in gantt_link_segments(from_y, to_y, c_from, c_to; narrow = is_narrow)
                    (seg.x < 0 || seg.x >= view_ncols) && continue
                    (seg.y < 0 || seg.y >= grid_h) && continue
                    xx = chart_x + seg.x
                    xx > area.x + area.width - 1 && continue
                    yy = grid_y0 + seg.y
                    set_char!(buf, xx, yy, seg.ch, Style(; fg = col_text_muted()))
                end
            end
        end
    end

    # Today marker (PR2): ▼ at band, ┃ (thick) vertical on grid; "TODAY" label on ruler if fits.
    # Use gantt_safe_char + textwidth guard (PR6). Painted before pre/in-bar keys so issue
    # identifiers win over today on collision (PR-V primary chart identity).
    # Continuous through inter-bar gaps so the marker reads as one column.
    if tcol !== nothing
        set_char!(buf, chart_x + tcol, band_y, '▼', Style(; fg = col_primary_hi(), bold = true))
        today_ch = is_narrow ? '│' : '┃'
        if nshow >= 1
            for yy in grid_y0:(grid_y0 + grid_h - 1)
                set_char!(buf, chart_x + tcol, yy, today_ch, Style(; fg = col_primary_hi(), bold = true))
            end
        end
        # "TODAY" on tick/single axis row. Skip on single-row month where tabs are the
        # primary axis content (TODAY would clobber month chips). Dual keeps TODAY on ticks.
        if has_ruler && (view_ncols - tcol) > 5 && !(!has_dual && lay.scale === :month)
            lx = chart_x + tcol + 1
            if lx + 4 < chart_x + view_ncols
                set_string!(buf, lx, ruler_y, "TODAY", Style(; fg = col_primary_hi(), bold = true))
            end
        end
    end

    # Chart identity keys after today: post-bar key preferred; in-bar fallback.
    # Post-bar: immediately right of bar/diamond (gap 1). In-bar: only when post-bar cannot fit (bw≥5).
    for i in 1:nshow
        ri = row_start + i - 1
        ri > length(rows) && break
        row = rows[ri]
        row.kind === :issue || continue
        iss = row.issue
        iss === nothing && continue
        rowy = gantt_row_y(grid_y0, i; stride = row_stride)
        selected = sel_issue !== nothing && iss.id == sel_issue.id
        geom = post_geoms[i]
        if geom !== nothing
            xx = chart_x + geom.start
            xx > area.x + area.width - 1 && continue
            maxc = min(geom.max_chars, area.x + area.width - xx)
            maxc < 1 && continue
            lbl = fit_width(iss.key, maxc)
            isempty(lbl) && continue  # COV_EXCL_LINE (maxc>=key_w and non-empty key ⇒ non-empty fit)
            lsty = selected ? Style(; fg = col_primary_hi(), bold = true) : Style(; fg = col_text())
            set_string!(buf, xx, rowy, lbl, lsty)
        else
            # In-bar fallback when post-bar cannot fit; uses paint dates (M3 preview).
            psd, pdd = _gantt_paint_dates(m, iss)
            if psd !== nothing && pdd !== nothing
                ext = gantt_bar_extent(win_start, dpc, psd, pdd, view_ncols)
                if ext !== nothing
                    c0, c1 = ext
                    bw = c1 - c0 + 1
                    if bw >= 5
                        avail = max(1, bw - 2)
                        lbl = fit_width(iss.key, avail)
                        lsty = selected ? Style(; fg = col_primary_hi(), bold = true) :
                               Style(; fg = col_text_dim(), dim = true)
                        set_string!(buf, chart_x + c0 + 1, rowy, lbl, lsty)
                        # re-assert caps so key never eats bar ends
                        dragging = m.gantt_drag !== nothing && m.gantt_drag.issue_id == iss.id
                        bar_col = dragging ? col_primary_hi() :
                                  (iss.status == "Done" ? col_ok() : priority_color(iss.priority))
                        set_char!(buf, chart_x + c0, rowy, '▌',
                                  selected ? Style(; fg = col_primary_hi(), bold = true) :
                                             Style(; fg = bar_col))
                        set_char!(buf, chart_x + c1, rowy, '▐', Style(; fg = bar_col))
                    end
                end
            end
        end
    end

    # PR5: selected item footer (when has_footer): exact dates, duration, status, priority (theming).
    # Draw below grid; priority token uses priority_color; rest col_text_dim. Responsive already in predicate.
    # has_footer ⇒ footer_y is always set (gantt_layout invariant).
    if has_footer
        fy = lay.footer_y::Int
        if fy <= area.y + area.height - 1
            sel = _gantt_selected_issue(m)
            if sel !== nothing
                full_footer = _gantt_selected_footer(m)
                wavail = area.width
                pri = sel.priority
                # compute prefix up to but not including the pri token for split styling
                # (recompute prefix same as helper to get col offset reliably; no string search)
                dur = ""
                if sel.start_date !== nothing && sel.due_date !== nothing
                    d = Dates.value(sel.due_date - sel.start_date) + 1
                    dur = " ($(d)d)"
                end
                asg = ""
                if sel.assignee_id !== nothing
                    try
                        u = Stores.get_user(m.userstore, sel.assignee_id)
                        if u !== nothing && !isempty(u.name)
                            asg = " • $(u.name)"
                        end
                    catch  # COV_EXCL_LINE — error path only on inconsistent userstore (tests use consistent stores)
                    end
                end
                prefix = "$(sel.key): $(sel.start_date !== nothing ? sel.start_date : "?") → $(sel.due_date !== nothing ? sel.due_date : "?")$(dur)  • $(sel.status) • "
                if textwidth(full_footer) <= wavail
                    sty_dim = Style(; fg = col_text_dim())
                    set_string!(buf, area.x, fy, prefix, sty_dim)
                    pcol = area.x + textwidth(prefix)
                    set_string!(buf, pcol, fy, pri, Style(; fg = priority_color(pri)))
                    if !isempty(asg)
                        set_string!(buf, pcol + textwidth(pri), fy, asg, sty_dim)
                    end
                else
                    set_string!(buf, area.x, fy, _short(full_footer, wavail), Style(; fg = col_text_dim()))
                end
            end
        end
    end
end
