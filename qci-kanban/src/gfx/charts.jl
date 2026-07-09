# ═══════════════════════════════════════════════════════════════════════
# gfx/charts.jl — Phase 5 board stats strip + sprint burndown + velocity.
#
#   • Board stats strip (toggle with `t`): per-column issue counts as a
#     Sparkline + a WIP Gauge for the In Progress column. Rendered at the top
#     of the board view.
#   • Sprint burndown (backlog view footer when a window is active): pure
#     `burndown_series` + `render_burndown!` Sparkline.
#   • Velocity spark (backlog footer when no active window): pure
#     `velocity_series` over last ≤8 closed `sprint_metrics` rows + avg line.
#
# The WIP Gauge is passed `tick=m.tick` so it shimmers when animations are on;
# with animations off it renders identically (Tachikoma gates the shimmer).
# Colors go through Theming accessors only — no raw ColorRGB literals.
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates

"Rows the board stats strip occupies when shown."
const STATS_HEIGHT = 4

# ── Board stats ──────────────────────────────────────────────────────────────
"""
    column_counts(m) -> Vector{Pair{String,Int}}

Pure projection: issue count per status column, in board order.
"""
column_counts(m::AppModel)::Vector{Pair{String,Int}} =
    [st => length(Stores.list_issues(m.boardstore; status = st, project_id = _scope(m)))
     for st in BOARD_STATUSES]

"""
    render_board_stats!(m, buf, area) -> Int

Render the per-column counts sparkline + WIP gauge. Returns rows consumed
(`0` when the area is too small to draw anything).
"""
function render_board_stats!(m::AppModel, buf::Buffer, area::Rect)
    (area.width < 12 || area.height < 3) && return 0
    counts = column_counts(m)
    total = sum(last, counts; init = 0)
    set_string!(buf, area.x, area.y, _short("STATS  $(total) issues  " *
                join(["$(first(c))=$(last(c))" for c in counts], " "), area.width),
                Style(; fg = col_primary(), bold = true))

    sp = Sparkline(Float64[last(c) for c in counts]; style = Style(; fg = col_primary_hi()))
    render(sp, Rect(area.x, area.y + 1, area.width, 1), buf)

    ip = length(Stores.list_issues(m.boardstore; status = "In Progress", project_id = _scope(m)))
    lim = _wip_limit(m, "In Progress")
    ratio = lim > 0 ? ip / lim : (ip > 0 ? 1.0 : 0.0)
    over = lim > 0 && ip > lim
    g = Gauge(ratio; label = "WIP In Progress $(ip)/$(lim > 0 ? lim : "∞")",
              filled_style = Style(; fg = over ? col_err() : col_primary()),
              tick = m.tick)
    render(g, Rect(area.x, area.y + 2, area.width, 1), buf)
    STATS_HEIGHT
end

# ── Sprint burndown ──────────────────────────────────────────────────────────
"""
    burndown_series(issues, start_date, end_date; today=today(), unit=:count)
        -> (; days, ideal, remaining, total)

Pure burndown model over the sprint window.

- `unit = :count` (default): one unit per issue — `total = length(issues)`,
  `remaining[k]` = issues not yet Done as of `days[k]`.
- `unit = :points`: story-point / est-hour units — `total = sum_units(issues)`,
  `remaining[k]` = sum of `story_points` (missing → 0) over issues that are
  **not** (`status == "Done"` AND `Date(updated) ≤ days[k]`).

An issue burns down on its `updated` date when status is Done. `ideal` is the
linear line from `total` → 0 across the window. A single-day window is widened
to two points so the ideal line is well defined.
"""
function burndown_series(issues, start_date::Date, end_date::Date;
                         today::Date = Dates.today(), unit::Symbol = :count)
    n = max(2, Dates.value(end_date - start_date) + 1)
    days = [start_date + Day(k) for k in 0:(n - 1)]
    total = unit === :points ? Domain.sum_units(issues) : length(issues)
    ideal = Float64[total * (1.0 - k / (n - 1)) for k in 0:(n - 1)]
    remaining = Float64[]
    for d in days
        if unit === :points
            rem = sum(issues; init = 0) do i
                burned = i.status == "Done" && Date(i.updated) <= d
                burned ? 0 : something(i.story_points, 0)
            end
            push!(remaining, Float64(rem))
        else
            done = count(i -> i.status == "Done" && Date(i.updated) <= d, issues)
            push!(remaining, Float64(max(0, total - done)))
        end
    end
    (; days = days, ideal = ideal, remaining = remaining, total = total)
end

"Active sprint with dates, else the first sprint with both dates, else nothing."
function _burndown_sprint(m::AppModel)
    asp = Stores.active_sprint(m.boardstore; project_id = _scope(m))
    if asp !== nothing && asp.start_date !== nothing && asp.end_date !== nothing
        return asp
    end
    for s in Stores.list_sprints(m.boardstore; project_id = _scope(m))
        s.start_date !== nothing && s.end_date !== nothing && return s
    end
    nothing
end

"Remaining-units value for the day nearest `today` within the window."
function _remaining_now(series, today::Date = Dates.today())
    isempty(series.remaining) && return 0
    idx = clamp(Dates.value(today - series.days[1]) + 1, 1, length(series.remaining))
    Int(series.remaining[idx])
end

"""
    render_burndown!(m, buf, area) -> Int

Render the active/first-dated sprint's burndown into `area`. Units follow
`m.config.velocity_unit` (`:count` | `:points`) so burndown and velocity share
one knob. Returns rows used (`0` when no dated sprint exists or area too small).
"""
function render_burndown!(m::AppModel, buf::Buffer, area::Rect)
    (area.width < 12 || area.height < 2) && return 0
    s = _burndown_sprint(m)
    s === nothing && return 0
    iss = Stores.issues_for_sprint(m.boardstore, s.id)
    unit = m.config.velocity_unit
    series = burndown_series(iss, s.start_date, s.end_date; unit = unit)
    now = _remaining_now(series)
    unit_tag = unit === :count ? "issues" : "pts"
    hdr = "BURNDOWN — $(s.name): $(now)/$(series.total) $(unit_tag) remaining"
    set_string!(buf, area.x, area.y, _short(hdr, area.width), Style(; fg = col_primary(), bold = true))
    sp = Sparkline(series.remaining; style = Style(; fg = col_primary_hi()),
                   max_val = max(1.0, Float64(series.total)))
    render(sp, Rect(area.x, area.y + 1, area.width, max(1, area.height - 1)), buf)
    area.height
end

# ── Velocity (closed-window throughput) ────────────────────────────────────
"""
    velocity_series(metrics; unit=:points) -> Vector{Float64}

Pure chronological series from `SprintMetrics` rows. When `unit == :points`
uses `completed_units`; when `unit == :count` uses `completed_count`. Does
**not** filter by `unit_kind` — both numbers are always on the row.
"""
function velocity_series(metrics; unit::Symbol = :points)::Vector{Float64}
    unit === :count ?
        Float64[Float64(m.completed_count) for m in metrics] :
        Float64[Float64(m.completed_units) for m in metrics]
end

"Active dated sprint only (no fallback to future/closed) for footer choice."
function _active_dated_sprint(m::AppModel)
    asp = Stores.active_sprint(m.boardstore; project_id = _scope(m))
    (asp !== nothing && asp.start_date !== nothing && asp.end_date !== nothing) ?
        asp : nothing
end

"""
    render_velocity!(m, buf, area) -> Int

Render last ≤8 closed-window velocity spark + avg for the active project.
Returns rows used (`0` when the area is too small).
"""
function render_velocity!(m::AppModel, buf::Buffer, area::Rect)
    (area.width < 12 || area.height < 2) && return 0
    metrics = Stores.list_sprint_metrics(m.boardstore; project_id = _scope(m), limit = 8)
    unit = m.config.velocity_unit
    series = velocity_series(metrics; unit = unit)
    if isempty(series)
        set_string!(buf, area.x, area.y,
                    _short("VELOCITY — no closed windows yet", area.width),
                    Style(; fg = col_text_dim()))
        return area.height
    end
    avg = sum(series) / length(series)
    avg_i = round(Int, avg)
    unit_tag = unit === :count ? "issues" : "pts"
    hdr = "VEL avg=$(avg_i) $(unit_tag) (n=$(length(series)))"
    set_string!(buf, area.x, area.y, _short(hdr, area.width),
                Style(; fg = col_primary(), bold = true))
    mx = max(1.0, maximum(series))
    sp = Sparkline(series; style = Style(; fg = col_primary_hi()), max_val = mx)
    render(sp, Rect(area.x, area.y + 1, area.width, max(1, area.height - 1)), buf)
    area.height
end

"""
    render_backlog_footer!(m, buf, area) -> Int

Backlog bottom strip: active dated sprint → burndown; else velocity spark of
recent closed windows for the active project.
"""
function render_backlog_footer!(m::AppModel, buf::Buffer, area::Rect)
    if _active_dated_sprint(m) !== nothing
        return render_burndown!(m, buf, area)
    end
    render_velocity!(m, buf, area)
end
