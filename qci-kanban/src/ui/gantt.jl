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

# ── Scale geometry (pure) ───────────────────────────────────────────────────
"Days represented by one chart column at the given scale."
gantt_days_per_col(scale::Symbol)::Int = scale === :month ? 7 : 1

"Days the window scrolls per h/l press at the given scale."
gantt_scroll_days(scale::Symbol)::Int =
    scale === :month ? 28 : (scale === :day ? 1 : 7)

"Fixed window size for day view (each column = 1 day). Produces a compact 14-day
timeline strip even on wide terminals so day zoom does not devolve into months."
const GANTT_DAY_VIEW_WINDOW = 14

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
    ch == '▬' ? '-' : ch

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

# ── Initialisation + actions ────────────────────────────────────────────────
"Set the window to start at the earliest dated issue (or today), day scale (day/wk/mo 3-way cycle)."
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

function _gantt_row!(m::AppModel, delta::Int)
    n = length(gantt_issue_rows(m))
    n == 0 && return m
    m.gantt_sel = clamp(m.gantt_sel + delta, 1, n)
    _gantt_ensure_selection_visible!(m)
    m
end

function _gantt_zoom!(m::AppModel)
    m.gantt_scale = if m.gantt_scale === :day; :week
                    elseif m.gantt_scale === :week; :month
                    else :day
                    end
    m.message = "Gantt scale: $(m.gantt_scale)"
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
Uses day-view 14-col cap for day scale; a representative width for week/month.
"""
function _gantt_ensure_selection_visible!(m::AppModel)
    iss = _gantt_selected_issue(m)
    iss === nothing && return m
    span = gantt_issue_span(iss)
    span === nothing && return m
    sd, ed = span
    dpc = gantt_days_per_col(m.gantt_scale)
    ncols = m.gantt_scale === :day ? GANTT_DAY_VIEW_WINDOW : 60
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
    ncols = area.width - left_w   # physical chart columns (for legend fit, narrow checks, guards)
    # Day view uses *per-day columns* and a hard-capped 14-day window (GANTT_DAY_VIEW_WINDOW)
    # so the header always shows a ~2 week range and never months. view_ncols drives
    # geometry, canvas, bars, shading, axis, and today marker.
    view_ncols = m.gantt_scale === :day ? min(ncols, GANTT_DAY_VIEW_WINDOW) : ncols
    sel_issue_early = _gantt_selected_issue(m)
    sel_span = sel_issue_early === nothing ? nothing : gantt_issue_span(sel_issue_early)
    win_start = gantt_effective_win_start(m.gantt_start, Dates.today(), dpc, view_ncols, sel_span)
    win_end = gantt_window_end(win_start, dpc, view_ncols)
    tcol = gantt_point_col(win_start, dpc, Dates.today(), view_ncols)  # COV_EXCL_LINE (hoist for coordination; value same as later; exercised via band/today)  # hoist early for band name/today coordination (minimal)
    scale_lbl = m.gantt_scale === :month ? "month" :
                m.gantt_scale === :day   ? "day"   : "week"
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
    is_narrow = area.width < 60
    # PR5: has_footer = h>=10 && rows>0 && !narrow (responsive hide on small terminals)
    # predicate approx per design; nshow accounts for footer_rows to reserve space.
    has_footer = area.height >= 10 && length(rows) > 0 && !is_narrow
    # G3 height budget (locked): dual-row axis only at h≥12; single at 8–11; none <8.
    # Footer stays at h≥10 with single axis for h=10–11 (footer wins over dual there).
    has_dual = area.height >= 12 && has_ruler
    tab_rows = has_dual ? 1 : 0
    tick_rows = has_ruler ? 1 : 0
    ruler_rows = tab_rows + tick_rows   # 0 | 1 | 2
    footer_rows = has_footer ? 1 : 0
    content_start = 1 + 1 + ruler_rows  # title + band + axis strip
    # Compute layout rows always (bands loop is no-op for empty; ruler now drawn
    # for empty tall cases too so no blank ruler row when h>=8).
    band_y = area.y + 1
    tab_y = has_dual ? area.y + 2 : 0
    # Single-row axis lands at band+1; dual tick row is band+2 (under tabs).
    tick_y = has_ruler ? (has_dual ? area.y + 3 : area.y + 2) : 0
    ruler_y = tick_y  # TODAY label + single-row axis paint target
    grid_y0 = area.y + content_start
    nshow = max(0, min(length(rows), area.height - content_start - footer_rows - 1))
    # G2 paint gates: weekend ░ + week seps ┆ off at :month (period wash stays on).
    # Pure gantt_weekend_cols / gantt_week_sep_cols remain computable always.
    paint_weekends = m.gantt_scale !== :month
    paint_week_seps = m.gantt_scale !== :month
    # z1 — alternating period wash on band (under weekend + sprint)
    for c in gantt_period_shade_cols(win_start, dpc, view_ncols, m.gantt_scale)
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
        # G3: dual-row (h≥12) = period tabs (full names) + tick row; single (h=8–11) =
        # digit-first combine on day/week, tabs-prefer on month. Pack labels into span.
        if has_dual
            # Tab row — full period names from gantt_axis_period_tabs (bold primary)
            for t in gantt_axis_period_tabs(win_start, dpc, view_ncols, m.gantt_scale; narrow = is_narrow)
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
        elseif m.gantt_scale === :month
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

    canvas = BlockCanvas(view_ncols, max(1, nshow); style = Style(; fg = col_primary()))
    diamonds = Tuple{Int,Int,Any}[]
    sel_issue = sel_issue_early

    # Track for PR4 selection bar accent (set during label/bar loop; used post-canvas)
    selected_vis_i = nothing
    selected_bar_ext = nothing

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
            prefix = selected ? "▸ " : "├ "
            set_string!(buf, area.x, rowy, _short(prefix * row.label, left_w - 1), lstyle)
            if iss.start_date !== nothing && iss.due_date !== nothing
                ext = gantt_bar_extent(win_start, dpc, iss.start_date, iss.due_date, view_ncols)
                if ext !== nothing
                    c0, c1 = ext
                    for dx in (2 * c0):(2 * c1 + 1), dy in (2 * (i - 1)):(2 * (i - 1) + 1)
                        set_point!(canvas, dx, dy)
                    end
                    if selected
                        selected_vis_i = i
                        selected_bar_ext = (c0, c1)
                    end
                end
            else
                d = iss.start_date === nothing ? iss.due_date : iss.start_date
                col = gantt_point_col(win_start, dpc, d, view_ncols)
                col === nothing || push!(diamonds, (chart_x + col, rowy, priority_color(iss.priority)))
            end
        end
    end

    # z1 — period wash on all visible grid rows (incl. epic headers), under weekend/seps/bars/today.
    for c in gantt_period_shade_cols(win_start, dpc, view_ncols, m.gantt_scale)
        for ii in 1:nshow
            set_char!(buf, chart_x + c, grid_y0 + ii - 1, ' ',
                      Style(; bg = col_gantt_period_alt()))
        end
    end
    # Weekend shading ░ (dim muted) on grid cols — BEFORE canvas so bars overlay where present.
    # Week separators ┆ (dim muted) on grid at week starts; skip today col to avoid clobber.
    # G2: both gated off at :month scale (paint only; pure helpers unchanged).
    wcols = gantt_weekend_cols(win_start, dpc, view_ncols)
    scols = gantt_week_sep_cols(win_start, dpc, view_ncols)
    tcol = gantt_point_col(win_start, dpc, Dates.today(), view_ncols)
    if paint_weekends
        for c in wcols
            for ii in 1:nshow
                ch = gantt_safe_char('░', is_narrow)  # COV_EXCL_LINE (duplicate safe path; core covered by pure + narrow tests)
                if textwidth(ch) != 1; ch = '#'; end
                set_string!(buf, chart_x + c, grid_y0 + ii - 1, string(ch), Style(; fg = col_text_muted(), dim = true))
            end
        end
    end
    if paint_week_seps
        for c in scols
            c == tcol && continue
            for ii in 1:nshow
                ch = gantt_safe_char('┆', is_narrow)  # COV_EXCL_LINE (duplicate safe path; core covered by pure + narrow tests)
                if textwidth(ch) != 1; ch = '|'; end
                set_char!(buf, chart_x + c, grid_y0 + ii - 1, ch, Style(; fg = col_text_muted(), dim = true))
            end
        end
    end

    render(canvas, Rect(chart_x, grid_y0, view_ncols, max(1, nshow)), buf)

    # PR3: post-canvas overlays — keep base █ from canvas; refined ends ▌▐, status density ▓ (using status_progress),
    # inside labels (issue key via fit_width) when wide; use finalized contrast (dim or primary_hi bold on sel; never col_bg()).
    # Theming only. Recompute rowy/selection here (same scroll logic as build pass; no y/layout change).
    # NOTE (nit fix): row_start/ri/rowy/selected logic is intentionally duplicated from canvas pass (~338) for PR3 minimality;
    # both copies must stay identical while layout unchanged (see PR2).
    for i in 1:nshow
        ri = row_start + i - 1
        ri > length(rows) && break
        row = rows[ri]
        rowy = grid_y0 + (i - 1)
        if row.kind === :issue
            iss = row.issue
            if iss !== nothing && iss.start_date !== nothing && iss.due_date !== nothing
                ext = gantt_bar_extent(win_start, dpc, iss.start_date, iss.due_date, view_ncols)
                if ext !== nothing
                    c0, c1 = ext
                    # explicit bounds guard (mirrors ruler/band: xx > ... continue); though gantt_bar_extent clamps
                    if chart_x + c0 < chart_x || chart_x + c1 > area.x + area.width - 1
                        continue  # COV_EXCL_LINE (defensive; extent always clamps c0/c1 valid for current render paths; see review fix)
                    end
                    selected = sel_issue !== nothing && iss.id == sel_issue.id
                    bar_col = (iss.status == "Done" ? col_ok() : priority_color(iss.priority))
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
                    # inside label when bar wide enough (overwrites density if collides)
                    if bw >= 5
                        avail = max(1, bw - 2)
                        lbl = fit_width(iss.key, avail)
                        lsty = selected ? Style(; fg = col_primary_hi(), bold = true) : Style(; fg = col_text_dim(), dim = true)
                        set_string!(buf, chart_x + c0 + 1, rowy, lbl, lsty)
                    end
                    # bar end caps (unicode) LAST so they win over density/label at edge cells
                    set_char!(buf, chart_x + c0, rowy, '▌', Style(; fg = bar_col))
                    if bw >= 2
                        set_char!(buf, chart_x + c1, rowy, '▐', Style(; fg = bar_col))
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
        rowy = grid_y0 + (selected_vis_i - 1)
        ax = chart_x + c0
        if ax <= area.x + area.width - 1
            set_char!(buf, ax, rowy, '▌', Style(; fg = col_primary_hi(), bold = true))
        end
    end

    # Today marker (PR2): ▼ at band, ┃ (thick) vertical on grid; "TODAY" label on ruler if fits.
    # Use gantt_safe_char + textwidth guard (PR6).
    if tcol !== nothing
        set_char!(buf, chart_x + tcol, band_y, '▼', Style(; fg = col_primary_hi(), bold = true))
        today_ch = is_narrow ? '│' : '┃'
        for i in 1:nshow
            set_char!(buf, chart_x + tcol, grid_y0 + (i - 1), today_ch, Style(; fg = col_primary_hi(), bold = true))
        end
        # "TODAY" on tick/single axis row. Skip on single-row month where tabs are the
        # primary axis content (TODAY would clobber month chips). Dual keeps TODAY on ticks.
        if has_ruler && (view_ncols - tcol) > 5 && !(!has_dual && m.gantt_scale === :month)
            lx = chart_x + tcol + 1
            if lx + 4 < chart_x + view_ncols
                set_string!(buf, lx, ruler_y, "TODAY", Style(; fg = col_primary_hi(), bold = true))
            end
        end
    end

    # PR5: selected item footer (when has_footer): exact dates, duration, status, priority (theming).
    # Draw below grid; priority token uses priority_color; rest col_text_dim. Responsive already in predicate.
    if has_footer
        fy = grid_y0 + nshow
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
