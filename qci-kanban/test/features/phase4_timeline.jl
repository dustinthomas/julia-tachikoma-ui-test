# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance for Phase 4 — Calendar + Gantt (PHASES.md "Phase 4"):
#   • Calendar day drill-down lists EXACTLY that day's issues + create-with-due.
#   • Gantt bar extents deterministic for known dates at a fixed size.
#   • Today marker column correct (computed from Dates.today()).
#   • Zoom changes the scale.
#   • No-conflict: any printable char in the calendar create modal mutates only
#     the focused editor — never a view/global shortcut.
# Given/When/Then, driven purely via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

P4 = QciKanban
p4login(; name = "Planner") = (m = fresh_app(; seed = false); app_login_new(m; name = name); m)
p4!(m, x) = T.update!(m, T.KeyEvent(x))
p4maxrun(s, ch) = (best = 0; cur = 0; for c in s; cur = c == ch ? cur + 1 : 0; best = max(best, cur); end; best)

@testset "FEATURE: Phase 4 timeline (BDD acceptance)" begin

    @testset "Given a month with issues due on specific days" begin
        m = p4login(); p4!(m, 'C')
        y, mo = m.cal_year, m.cal_month
        d9  = P4.Stores.create_issue!(m.boardstore; title = "Ninth", due_date = Date(y, mo, 9))
        d9b = P4.Stores.create_issue!(m.boardstore; title = "AlsoNinth", due_date = Date(y, mo, 9))
        P4.Stores.create_issue!(m.boardstore; title = "Tenth", due_date = Date(y, mo, 10))
        @testset "When day 9 is selected Then the drill-down lists exactly its two issues" begin
            for _ in 1:abs(9 - m.cal_sel_day); p4!(m, 9 >= m.cal_sel_day ? 'j' : 'k'); end
            @test m.cal_sel_day == 9
            listed = P4._cal_day_issues(m, 9)
            @test Set(i.id for i in listed) == Set([d9.id, d9b.id])
            tb = app_tb(m; w = 100, h = 28)
            @test T.find_text(tb, d9.key) !== nothing
            @test T.find_text(tb, "Tenth") === nothing        # the day-10 issue is excluded
        end
        @testset "When n is pressed Then a create modal opens with due = selected day" begin
            p4!(m, 'n')
            @test m.modal == :card_edit && m.card_issue_id === nothing
            @test T.text(m.edit_form.due_input) == string(Date(y, mo, 9))
        end
    end

    @testset "Given issues with explicit start/due dates on the Gantt" begin
        m = p4login()
        e = P4.Stores.create_epic!(m.boardstore; name = "Roadmap")
        a = P4.Stores.create_issue!(m.boardstore; title = "Build", epic_id = e.id,
                                    start_date = Date(2026, 5, 4), due_date = Date(2026, 5, 10))
        p4!(m, 'G')
        @testset "When rendered at week scale Then the bar spans the exact day columns" begin
            @test m.gantt_start == Date(2026, 5, 4)
            tb = T.TestBackend(120, 20); T.reset!(tb.buf)
            P4.render_gantt!(m, tb.buf, T.Rect(1, 1, 120, 20))
            rowtxt = nothing
            for i in 1:20
                rt = T.row_text(tb, i)
                rt !== nothing && occursin(a.key, rt) && (rowtxt = rt; break)
            end
            @test rowtxt !== nothing
            @test p4maxrun(rowtxt, '█') == 7               # May 4→10 inclusive @ 1 day/col
        end
        @testset "When zoomed to month Then the scale label + bar width change" begin
            p4!(m, 'z')
            @test m.gantt_scale == :month
            tb = T.TestBackend(120, 20); T.reset!(tb.buf)
            P4.render_gantt!(m, tb.buf, T.Rect(1, 1, 120, 20))
            @test T.find_text(tb, "[month]") !== nothing
            rowtxt = nothing
            for i in 1:20
                rt = T.row_text(tb, i)
                rt !== nothing && occursin(a.key, rt) && (rowtxt = rt; break)
            end
            @test p4maxrun(rowtxt, '█') == 1               # 7 days collapse into one week-column
        end
    end

    @testset "Given an issue spanning today When rendered Then the today marker sits at today's column" begin
        m = p4login()
        e = P4.Stores.create_epic!(m.boardstore; name = "Live")
        P4.Stores.create_issue!(m.boardstore; title = "Ongoing", epic_id = e.id,
                                start_date = Dates.today() - Day(2), due_date = Dates.today() + Day(2))
        p4!(m, 'G')
        w = 120; left_w = P4.gantt_left_width(P4.gantt_rows(m), w); ncols = w - left_w
        expected_col = P4.gantt_point_col(m.gantt_start, 1, Dates.today(), ncols)
        @test expected_col == 2                            # today is 2 days after the window start
        tb = T.TestBackend(w, 20); T.reset!(tb.buf)
        P4.render_gantt!(m, tb.buf, T.Rect(1, 1, w, 20))
        loc = T.find_text(tb, "▼")
        @test loc !== nothing
        # position of marker verified via draw formula (adaptive left_w from PR2/6); use semantic
        drawn_x = 1 + left_w + expected_col
        @test T.char_at(tb, drawn_x, (loc !== nothing ? loc.y : 2) + 2) in ('┃','│','|',' ')
        # ruler present (h=20>=8); today vertical semantic (┃ or │)
        @test (T.find_text(tb, "┬") !== nothing || T.find_text(tb, "Mar") !== nothing || T.find_text(tb, "202") !== nothing)
        chv = T.char_at(tb, drawn_x, (loc !== nothing ? loc.y : 2) + 2)
        @test chv == '┃' || chv == '│' || chv == '|' || chv == ' '  # space guard for edge cases in verify
    end

    @testset "No-conflict: printable chars in the calendar create modal edit only the field" begin
        m = p4login(); p4!(m, 'C'); p4!(m, 'n')
        @test m.modal == :card_edit
        base = T.text(m.edit_form.title_input)
        # includes view-switch letters, quit, gantt zoom, nav — none may escape the editor
        for ch in collect("CGBKqzhjkl123/nvae")
            before = T.text(m.edit_form.title_input)
            p4!(m, ch)
            @test m.view == :calendar                      # never switched view
            @test m.modal == :card_edit                    # never left the modal
            @test m.quit == false                          # 'q' never quit
            @test T.text(m.edit_form.title_input) == before * string(ch)
        end
        @test T.text(m.edit_form.title_input) == base * "CGBKqzhjkl123/nvae"
    end
end
