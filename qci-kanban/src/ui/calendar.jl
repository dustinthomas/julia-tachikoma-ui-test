# ═══════════════════════════════════════════════════════════════════════
# ui/calendar.jl — Phase 4 month calendar view.
#
# Renders a month grid via Tachikoma's `Calendar` widget with due-date marks
# for issues due that month, month navigation (h/l), day selection (j/k), a
# selected-day drill-down panel listing exactly that day's issues, `n` to
# create an issue pre-filled with the selected date as due_date, and Enter to
# open the card detail modal for the first issue on the selected day.
#
# Derived state is PURE (`_cal_month_issues`, `_cal_day_issues`, `cal_day_cell`)
# so navigation and rendering can never disagree. No raw ColorRGB literals —
# color goes through Theming accessors (test-enforced).
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates

# ── Initialisation on entering the view ─────────────────────────────────────
"Reset the calendar to today's month with today selected (called on view switch)."
function _cal_init!(m::AppModel)
    d = Dates.today()
    m.cal_year = Dates.year(d)
    m.cal_month = Dates.month(d)
    m.cal_sel_day = Dates.day(d)
    m
end

_cal_title(m::AppModel) = "$(Dates.monthname(m.cal_month)) $(m.cal_year)"
_cal_days_in_month(m::AppModel) = Dates.daysinmonth(Date(m.cal_year, m.cal_month, 1))

# ── Navigation ──────────────────────────────────────────────────────────────
"Shift the displayed month by `delta` (±1), rolling the year over at the edges."
function _cal_month!(m::AppModel, delta::Int)
    y = m.cal_year
    mo = m.cal_month + delta
    while mo > 12
        mo -= 12; y += 1
    end
    while mo < 1
        mo += 12; y -= 1
    end
    m.cal_year = y
    m.cal_month = mo
    m.cal_sel_day = clamp(m.cal_sel_day, 1, Dates.daysinmonth(Date(y, mo, 1)))
    m.message = _cal_title(m)
    m
end

"Move the day selection by `delta`, clamped to the current month's length."
function _cal_day!(m::AppModel, delta::Int)
    m.cal_sel_day = clamp(m.cal_sel_day + delta, 1, _cal_days_in_month(m))
    m
end

# ── Derived issue sets (pure over the store + displayed month) ──────────────
"Issues whose due_date falls in the displayed month."
function _cal_month_issues(m::AppModel)::Vector{Domain.Issue}
    [i for i in Stores.list_issues(m.boardstore; project_id = _scope(m))
     if i.due_date !== nothing &&
        Dates.year(i.due_date) == m.cal_year && Dates.month(i.due_date) == m.cal_month]
end

"Set of days (1-based) in the displayed month that have at least one due issue."
_cal_marked_days(m::AppModel)::Set{Int} =
    Set{Int}(Dates.day(i.due_date) for i in _cal_month_issues(m))

"Issues due on exactly `day` of the displayed month, in store order."
_cal_day_issues(m::AppModel, day::Int)::Vector{Domain.Issue} =
    [i for i in _cal_month_issues(m) if Dates.day(i.due_date) == day]

"The first issue due on the currently selected day, or nothing."
function _cal_selected_issue(m::AppModel)
    v = _cal_day_issues(m, m.cal_sel_day)
    isempty(v) ? nothing : first(v)
end

# ── Actions ──────────────────────────────────────────────────────────────────
"Open the create-card modal pre-filled with the selected day as the due date."
function _cal_new!(m::AppModel)
    d = Date(m.cal_year, m.cal_month, clamp(m.cal_sel_day, 1, _cal_days_in_month(m)))
    _open_card_edit!(m; create = true, due_prefill = d)
end

"Open the card-detail modal for the first issue on the selected day."
_cal_open_detail!(m::AppModel) = _open_detail_issue!(m, _cal_selected_issue(m))

"Open the card-edit modal for the first issue on the selected day."
_cal_open_edit!(m::AppModel) = _open_edit_issue!(m, _cal_selected_issue(m))

# ── Layout helper (pure): where a given day's number is drawn ───────────────
"""
    cal_day_cell(year, month, day, origin_x, grid_y0) -> (x, y)

Buffer cell of the `day`-number in the `Calendar` grid, matching the widget's
layout: Monday-first, 3 columns per weekday, one row per week. `origin_x` is
the grid's left edge; `grid_y0` is the first grid row (two rows below the
month header + weekday header).
"""
function cal_day_cell(year::Int, month::Int, day::Int, origin_x::Int, grid_y0::Int)
    first_dow = Dates.dayofweek(Date(year, month, 1))   # Mon=1 … Sun=7
    linear = (first_dow - 1) + (day - 1)
    row = linear ÷ 7
    col = linear % 7
    (origin_x + col * 3, grid_y0 + row)
end

# ═══════════════════════════ RENDER ═════════════════════════════════════════
function render_calendar!(m::AppModel, buf::Buffer, area::Rect)
    if area.width < 22 || area.height < 8
        set_string!(buf, area.x, area.y,
                    _short("Calendar needs a bigger window", area.width),
                    Style(; fg = col_text_dim()))
        return
    end
    dim = _cal_days_in_month(m)
    sd = clamp(m.cal_sel_day, 1, dim)
    header = "CALENDAR — $(Dates.monthname(m.cal_month)) $(sd), $(m.cal_year)"
    set_string!(buf, area.x, area.y, _short(header, area.width),
                Style(; fg = col_primary(), bold = true))

    calw = 22
    calrect = Rect(area.x, area.y + 1, calw, area.height - 1)
    marked = _cal_marked_days(m)
    td = Dates.today()
    today_day = (Dates.year(td) == m.cal_year && Dates.month(td) == m.cal_month) ? Dates.day(td) : 0
    cal = Calendar(m.cal_year, m.cal_month; today = today_day, marked = marked,
                   header_style = Style(; fg = col_primary(), bold = true),
                   day_style    = Style(; fg = col_text()),
                   today_style  = Style(; fg = col_primary_hi(), bold = true),
                   marked_style = Style(; fg = col_warn()),
                   dim_style    = Style(; fg = col_text_dim()))
    render(cal, calrect, buf)

    # Selection overlay — the widget has no selection concept, so paint the
    # selected day-number in the QCI selection style on top of the grid.
    cx, cy = cal_day_cell(m.cal_year, m.cal_month, sd, calrect.x, calrect.y + 2)
    if cy <= area.y + area.height - 1
        set_string!(buf, cx, cy, lpad(string(sd), 2), sel_style())
    end

    # Drill-down panel to the right of the grid when there is room.
    panel_x = area.x + calw + 2
    if panel_x < area.x + area.width - 6
        _cal_render_panel!(m, buf,
                           Rect(panel_x, area.y + 1, area.x + area.width - panel_x, area.height - 1), sd)
    end
end

# The caller only invokes this when the right-of-grid gap is wider than the
# panel margin, so `r` is always large enough to draw into — no size guard.
function _cal_render_panel!(m::AppModel, buf::Buffer, r::Rect, day::Int)
    issues = _cal_day_issues(m, day)
    set_string!(buf, r.x, r.y, _short("DUE $(Dates.monthname(m.cal_month)) $(day)", r.width),
                Style(; fg = col_primary(), bold = true))
    y = r.y + 1
    if isempty(issues)
        set_string!(buf, r.x, y, _short("No issues due", r.width), Style(; fg = col_text_dim()))
        return
    end
    for iss in issues
        y > r.y + r.height - 1 && break
        set_string!(buf, r.x, y, _short(iss.key, r.width), Style(; fg = priority_color(iss.priority)))
        tx = r.x + length(iss.key) + 1
        set_string!(buf, tx, y, _short(iss.title, r.x + r.width - tx), Style(; fg = col_text()))
        y += 1
    end
end
