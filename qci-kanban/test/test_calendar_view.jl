# Phase 4 — Calendar view: month grid (Tachikoma Calendar widget), due-date
# marks, month nav (h/l), day selection (j/k), selected-day drill-down listing
# exactly that day's issues, `n` create-with-due-date, Enter → card detail.
# Driven via update!(m, KeyEvent(...)) + TestBackend; pure derived state tested
# directly. Depends on fresh_app / app_login_new / app_tb / app_rows.

using Dates
C4 = QciKanban
k4!(m, x) = T.update!(m, T.KeyEvent(x))
cal_login() = (m = fresh_app(; seed = false); app_login_new(m; name = "Cal User"); m)
cal_goto_day!(m, d) = (steps = d - m.cal_sel_day;
                       for _ in 1:abs(steps); k4!(m, steps >= 0 ? 'j' : 'k'); end; m)

@testset "Phase 4 — Calendar view" begin

    @testset "C enters calendar; month grid + weekday header render" begin
        m = cal_login()
        k4!(m, 'C')
        @test m.view == :calendar
        @test m.cal_year == Dates.year(Dates.today())
        @test m.cal_month == Dates.month(Dates.today())
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, "CALENDAR") !== nothing
        @test T.find_text(tb, Dates.monthname(m.cal_month)) !== nothing
        @test T.find_text(tb, "Mo") !== nothing        # Monday-first weekday header
        @test T.find_text(tb, "Su") !== nothing
    end

    @testset "due-date marks + day drill-down lists EXACTLY that day's issues" begin
        m = cal_login()
        k4!(m, 'C')
        y, mo = m.cal_year, m.cal_month
        i15 = C4.Stores.create_issue!(m.boardstore; title = "Due Fifteenth", priority = "High",
                                      due_date = Date(y, mo, 15))
        i16 = C4.Stores.create_issue!(m.boardstore; title = "SixteenthOnly", priority = "Low",
                                      due_date = Date(y, mo, 16))
        # pure day-issue projection is exact
        d15 = C4._cal_day_issues(m, 15)
        @test length(d15) == 1 && d15[1].id == i15.id
        @test 15 in C4._cal_marked_days(m) && 16 in C4._cal_marked_days(m)
        # drill-down render for day 15 shows i15, not i16
        cal_goto_day!(m, 15)
        @test m.cal_sel_day == 15
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, "DUE $(Dates.monthname(mo)) 15") !== nothing
        @test T.find_text(tb, i15.key) !== nothing
        @test T.find_text(tb, "SixteenthOnly") === nothing      # no bleed of other day
    end

    @testset "day with no due issues shows 'No issues due'" begin
        m = cal_login()
        k4!(m, 'C')
        cal_goto_day!(m, 12)                # nothing seeded → empty
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, "No issues due") !== nothing
    end

    @testset "Enter opens the card detail modal for the selected day's issue" begin
        m = cal_login()
        k4!(m, 'C')
        y, mo = m.cal_year, m.cal_month
        iss = C4.Stores.create_issue!(m.boardstore; title = "Enter Target", due_date = Date(y, mo, 10))
        cal_goto_day!(m, 10)
        k4!(m, :enter)
        @test m.modal == :card_detail
        @test m.card_issue_id == iss.id
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, iss.key) !== nothing
        # no bleed of the calendar grid under the modal
        @test T.find_text(tb, "No issues due") === nothing
    end

    @testset "Enter on an empty day is inert (no modal)" begin
        m = cal_login()
        k4!(m, 'C')
        cal_goto_day!(m, 8)                 # no issues
        k4!(m, :enter)
        @test m.modal == :none
    end

    @testset "n creates a card pre-filled with the selected date as due_date" begin
        m = cal_login()
        k4!(m, 'C')
        y, mo = m.cal_year, m.cal_month
        cal_goto_day!(m, 20)
        k4!(m, 'n')
        @test m.modal == :card_edit
        @test m.card_issue_id === nothing                         # create mode
        @test T.text(m.edit_form.due_input) == string(Date(y, mo, 20))
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, "NEW CARD") !== nothing
    end

    @testset "month navigation h/l changes the displayed month" begin
        m = cal_login()
        k4!(m, 'C')
        mo0 = m.cal_month
        k4!(m, 'l')
        @test m.cal_month != mo0 || m.cal_year != Dates.year(Dates.today())
        k4!(m, 'h')                          # back
        @test m.cal_month == mo0
        # arrow keys mirror h/l
        k4!(m, :right); @test m.cal_month != mo0 || m.cal_year != Dates.year(Dates.today())
        k4!(m, :left);  @test m.cal_month == mo0
    end

    @testset "month rollover across year boundaries (both directions)" begin
        m = cal_login(); k4!(m, 'C')
        m.cal_year = 2026; m.cal_month = 12; m.cal_sel_day = 31
        C4._cal_month!(m, +1)
        @test m.cal_year == 2027 && m.cal_month == 1
        m.cal_year = 2026; m.cal_month = 1; m.cal_sel_day = 15
        C4._cal_month!(m, -1)
        @test m.cal_year == 2025 && m.cal_month == 12
        # day clamps into a shorter month (Jan 31 → Feb 28/29)
        m.cal_year = 2026; m.cal_month = 1; m.cal_sel_day = 31
        C4._cal_month!(m, +1)
        @test m.cal_month == 2 && m.cal_sel_day <= 28
    end

    @testset "day selection j/k clamps to the month's length" begin
        m = cal_login(); k4!(m, 'C')
        dim = Dates.daysinmonth(Date(m.cal_year, m.cal_month, 1))
        for _ in 1:60; k4!(m, 'j'); end
        @test m.cal_sel_day == dim
        for _ in 1:60; k4!(m, 'k'); end
        @test m.cal_sel_day == 1
        # arrow keys mirror
        k4!(m, :down); @test m.cal_sel_day == 2
        k4!(m, :up);   @test m.cal_sel_day == 1
    end

    @testset "cal_day_cell maps day → (x,y) matching the widget grid layout" begin
        # 2026-06-01 is a Monday (first_dow == 1)
        @test Dates.dayofweek(Date(2026, 6, 1)) == 1
        @test C4.cal_day_cell(2026, 6, 1, 10, 100) == (10, 100)       # col 0, row 0
        @test C4.cal_day_cell(2026, 6, 7, 10, 100) == (10 + 6 * 3, 100)  # Sunday, row 0
        @test C4.cal_day_cell(2026, 6, 8, 10, 100) == (10, 101)       # next Monday, row 1
    end

    @testset "small-terminal guard + panel-suppressed narrow render" begin
        m = cal_login(); k4!(m, 'C')
        # direct calendar render at a tiny rect hits the calendar guard line
        tb = T.TestBackend(24, 6); T.reset!(tb.buf)
        C4.render_calendar!(m, tb.buf, T.Rect(1, 1, 20, 5))
        @test T.find_text(tb, "Calendar needs") !== nothing
        # narrow (grid but no drill-down panel): width 30 suppresses the panel
        tb2 = T.TestBackend(40, 12); T.reset!(tb2.buf)
        C4.render_calendar!(m, tb2.buf, T.Rect(1, 1, 30, 10))
        @test T.find_text(tb2, Dates.monthname(m.cal_month)) !== nothing
        @test T.find_text(tb2, "DUE") === nothing
    end

    @testset "selection overlay skipped when the selected day falls below the view" begin
        m = cal_login(); k4!(m, 'C')
        # find a month whose day 31 sits on the 6th grid row (linear >= 35)
        yy, mm = 2026, 1
        for mo in 1:12
            d1 = Date(2026, mo, 1)
            if Dates.daysinmonth(d1) == 31 && (Dates.dayofweek(d1) - 1) + 30 >= 35
                yy, mm = 2026, mo; break
            end
        end
        m.cal_year = yy; m.cal_month = mm; m.cal_sel_day = 31
        tb = T.TestBackend(60, 8); T.reset!(tb.buf)
        C4.render_calendar!(m, tb.buf, T.Rect(1, 1, 40, 8))   # height 8 → row-5 day is off-view
        @test T.find_text(tb, Dates.monthname(mm)) !== nothing   # renders without error
    end
end
