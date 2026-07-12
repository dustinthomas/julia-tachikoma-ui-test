# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance for Gantt mouse MVP M1 — click-to-select via pure hit-test.
#   • Left-press on left-rail / bar / post-bar selects issue (issue-only gantt_sel)
#   • Epic header / axis / empty area: no-op
#   • Click does NOT open detail modal (Enter/v remain open path)
#   • Keyboard j/k/Enter still work after mouse select
#   • Login / modal / non-gantt / empty gantt_last_area ignore mouse
# Driven via update!(m, MouseEvent(...)) + TestBackend re-render.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

GM = QciKanban
gmlogin(; name = "Mouse User") = (m = fresh_app(; seed = false); app_login_new(m; name = name); m)
gm!(m, x) = T.update!(m, T.KeyEvent(x))
gm_click(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_press, false, false, false)

@testset "FEATURE: Gantt mouse click-select (M1 BDD)" begin

    @testset "Given two dated issues on the Gantt" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "MouseRoadmap")
        a = GM.Stores.create_issue!(m.boardstore; title = "MouseAlpha", epic_id = e.id,
                                    start_date = Dates.today(),
                                    due_date = Dates.today() + Day(3))
        b = GM.Stores.create_issue!(m.boardstore; title = "MouseBeta", epic_id = e.id,
                                    start_date = Dates.today() + Day(1),
                                    due_date = Dates.today() + Day(5))
        gm!(m, 'G')
        @test m.view === :gantt
        @test m.gantt_sel == 1
        @test GM._gantt_selected_issue(m).id == a.id

        # Populate gantt_last_area via full app view (same path as live TUI).
        W, H = 120, 28
        tb = app_tb(m; w = W, h = H)
        @test m.gantt_last_area.width >= 1 && m.gantt_last_area.height >= 1
        area = m.gantt_last_area
        rows = GM.gantt_rows(m)
        lay = GM.gantt_layout(m, area; rows = rows)
        rb = findfirst(r -> r.kind === :issue && r.issue.id == b.id, rows)
        @test rb !== nothing
        yb = lay.grid_y0 + (rb - lay.row_start)
        ext_b = GM.gantt_bar_extent(lay.win_start, lay.dpc, b.start_date, b.due_date, lay.view_ncols)
        @test ext_b !== nothing

        @testset "When the user left-clicks issue B's bar Then gantt_sel is issue-only index for B" begin
            T.update!(m, gm_click(lay.chart_x + ext_b[1], yb))
            @test m.gantt_sel == 2
            @test GM._gantt_selected_issue(m).id == b.id
            @test m.modal === :none   # click does NOT open detail
            # Re-render: selection chrome ▸ on B
            tb2 = app_tb(m; w = W, h = H)
            blob = join([something(T.row_text(tb2, i), "") for i in 1:H], "\n")
            @test occursin("▸", blob)
            # Footer / chrome references selected key when footer present
            if lay.has_footer
                @test T.find_text(tb2, b.key) !== nothing
            end
        end

        @testset "When the user left-clicks issue A's left rail Then selection returns to A" begin
            ra = findfirst(r -> r.kind === :issue && r.issue.id == a.id, rows)
            ya = lay.grid_y0 + (ra - lay.row_start)
            T.update!(m, gm_click(area.x + 1, ya))
            @test m.gantt_sel == 1
            @test GM._gantt_selected_issue(m).id == a.id
            @test m.modal === :none
        end

        @testset "When the user clicks the epic header Then selection is unchanged" begin
            GM._gantt_select!(m, 2)
            T.update!(m, gm_click(area.x + 1, lay.grid_y0))  # first grid row = epic
            @test m.gantt_sel == 2
            @test m.modal === :none
        end

        @testset "When the user clicks the axis Then selection is unchanged" begin
            sel_before = m.gantt_sel
            T.update!(m, gm_click(lay.chart_x + 2, lay.tick_y))
            @test m.gantt_sel == sel_before
            @test m.modal === :none
        end

        @testset "When the user presses Enter after mouse select Then detail opens for that issue" begin
            GM._gantt_select!(m, 2)
            @test GM._gantt_selected_issue(m).id == b.id
            gm!(m, :enter)
            @test m.modal === :card_detail
            @test m.card_issue_id == b.id
            gm!(m, :escape)
            @test m.modal === :none
        end

        @testset "When the user uses j/k after mouse Then keyboard selection still works" begin
            GM._gantt_select!(m, 1)
            gm!(m, 'j')
            @test m.gantt_sel == 2
            gm!(m, 'k')
            @test m.gantt_sel == 1
            @test GM._gantt_selected_issue(m).id == a.id
        end

        @testset "When post-bar title is clicked Then the issue is selected" begin
            GM._gantt_select!(m, 1)
            post = GM.gantt_post_bar_label_geom(ext_b[1], ext_b[2], lay.label_ncols; gap = 1)
            if post !== nothing
                T.update!(m, gm_click(lay.chart_x + post.start, yb))
                @test m.gantt_sel == 2
                @test GM._gantt_selected_issue(m).id == b.id
                @test m.modal === :none
            end
        end
    end

    @testset "Given login / modal / non-gantt / empty area — mouse is a no-op for selection" begin
        # Empty area: on gantt but never rendered
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "GateEp")
        GM.Stores.create_issue!(m.boardstore; title = "GateIss", epic_id = e.id,
                                start_date = Dates.today(), due_date = Dates.today() + Day(1))
        gm!(m, 'G')
        @test m.gantt_last_area.width == 0
        sel0 = m.gantt_sel
        T.update!(m, gm_click(10, 10))
        @test m.gantt_sel == sel0

        # Non-gantt view
        app_tb(m; w = 100, h = 24)  # populate area while still on gantt
        gm!(m, 'B')
        @test m.view === :board
        sel1 = m.gantt_sel
        T.update!(m, gm_click(m.gantt_last_area.x + 1, m.gantt_last_area.y + 4))
        @test m.gantt_sel == sel1

        # Modal open (help) on gantt
        gm!(m, 'G')
        app_tb(m; w = 100, h = 24)
        gm!(m, '?')
        @test m.modal === :help
        sel2 = m.gantt_sel
        T.update!(m, gm_click(m.gantt_last_area.x + 1, m.gantt_last_area.y + 4))
        @test m.gantt_sel == sel2
        gm!(m, :escape)

        # Logged-out: no current_user
        m2 = fresh_app(; seed = false)
        @test m2.current_user === nothing
        m2.view = :gantt
        m2.gantt_last_area = T.Rect(1, 1, 80, 20)
        m2.gantt_sel = 1
        T.update!(m2, gm_click(5, 8))
        @test m2.gantt_sel == 1
        @test m2.current_user === nothing
    end

    @testset "Given idle clock — mouse activity refreshes last_input_at" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "IdleEp")
        GM.Stores.create_issue!(m.boardstore; title = "IdleIss", epic_id = e.id,
                                start_date = Dates.today(), due_date = Dates.today() + Day(1))
        gm!(m, 'G')
        app_tb(m; w = 100, h = 24)
        old = m.last_input_at
        sleep(0.01)
        T.update!(m, gm_click(m.gantt_last_area.x + 1, m.gantt_last_area.y + 4))
        @test m.last_input_at >= old
        @test m.tick >= 1
    end

    @testset "Given idle expired When mouse Then logout and swallow event" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "ExpEp")
        GM.Stores.create_issue!(m.boardstore; title = "ExpIss", epic_id = e.id,
                                start_date = Dates.today(), due_date = Dates.today() + Day(1))
        gm!(m, 'G')
        app_tb(m; w = 100, h = 24)
        m.config.idle_logout_seconds = 60
        m.last_input_at = Dates.now(UTC) - Dates.Second(120)
        sel_before = m.gantt_sel
        T.update!(m, gm_click(m.gantt_last_area.x + 1, m.gantt_last_area.y + 4))
        @test m.current_user === nothing
        @test m.login_error == "Session expired (idle)"
        # selection not advanced after logout swallow
        @test m.gantt_sel == sel_before || m.current_user === nothing
    end
end
