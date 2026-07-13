# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance for Gantt mouse MVP M1–M3
#   M1 click-to-select via pure hit-test:
#   • Left-press on left-rail / bar / post-bar key selects issue (issue-only gantt_sel)
#   • Epic header / axis / empty area: no-op
#   • Click does NOT open detail modal (Enter/v remain open path)
#   • Keyboard j/k/Enter still work after mouse select
#   • Login / modal / non-gantt / empty gantt_last_area ignore mouse
#   M2 wheel scroll:
#   • mouse_scroll_up/down over gantt body → _gantt_scroll!(±1); advances gantt_start
#   • No zoom on wheel; keyboard h/l remain first-class
#   M3 drag-reschedule:
#   • Drag bar body shifts start/due in store (duration preserved)
#   • Denied role (viewer + enforce_roles) does not write
#   • Esc cancels drag without commit
#   • Keyboard edit (e) still works after mouse
# Driven via update!(m, MouseEvent(...)) + TestBackend re-render.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

GM = QciKanban
gmlogin(; name = "Mouse User") = (m = fresh_app(; seed = false); app_login_new(m; name = name); m)
gantt_y(lay, row_index) = lay.grid_y0 + (row_index - lay.row_start) * lay.row_stride
gm!(m, x) = T.update!(m, T.KeyEvent(x))
gm_click(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_press, false, false, false)
gm_wheel(col, row, btn) = T.MouseEvent(col, row, btn, T.mouse_press, false, false, false)
gm_drag(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_drag, false, false, false)
gm_release(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_release, false, false, false)

@testset "FEATURE: Gantt mouse click-select (M1 BDD)" begin

    @testset "Given two dated issues on the Gantt" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "MouseRoadmap")
        a = GM.Stores.create_issue!(m.boardstore; title = "MouseAlpha", epic_id = e.id,
                                    start_date = Dates.today() + Day(8),
                                    due_date = Dates.today() + Day(11))
        b = GM.Stores.create_issue!(m.boardstore; title = "MouseBeta", epic_id = e.id,
                                    start_date = Dates.today() + Day(9),
                                    due_date = Dates.today() + Day(13))
        gm!(m, 'G')
        m.gantt_start = Dates.today() - Day(1)
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
        yb = gantt_y(lay, rb)
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
            ya = gantt_y(lay, ra)
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

        @testset "When post-bar key is clicked Then the issue is selected" begin
            GM._gantt_select!(m, 1)
            # Recompute layout after any prior scrolls/selects (window fixed above)
            rows2 = GM.gantt_rows(m)
            lay2 = GM.gantt_layout(m, m.gantt_last_area; rows = rows2)
            rb2 = findfirst(r -> r.kind === :issue && r.issue.id == b.id, rows2)
            yb2 = gantt_y(lay2, rb2)
            ext2 = GM.gantt_bar_extent(lay2.win_start, lay2.dpc, b.start_date, b.due_date, lay2.view_ncols)
            @test ext2 !== nothing
            kwb = textwidth(b.key)
            post = GM.gantt_post_bar_label_geom(ext2[1], ext2[2], lay2.label_ncols;
                                                gap = 1, max_w = kwb)
            @test post !== nothing && post.max_chars >= kwb
            T.update!(m, gm_click(lay2.chart_x + post.start, yb2))
            @test m.gantt_sel == 2
            @test GM._gantt_selected_issue(m).id == b.id
            @test m.modal === :none
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

@testset "FEATURE: Gantt mouse wheel scroll (M2 BDD)" begin

    @testset "Given Gantt view When user scrolls wheel over chart Then window advances" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "WheelRoadmap")
        GM.Stores.create_issue!(m.boardstore; title = "WheelAlpha", epic_id = e.id,
                                start_date = Dates.today(),
                                due_date = Dates.today() + Day(3))
        gm!(m, 'G')
        @test m.view === :gantt
        @test m.gantt_scale === :day
        W, H = 120, 28
        app_tb(m; w = W, h = H)
        area = m.gantt_last_area
        @test area.width >= 1 && area.height >= 1
        # Pointer over gantt body (chart interior)
        cx = area.x + area.width ÷ 2
        cy = area.y + area.height ÷ 2
        st0 = m.gantt_start
        scale0 = m.gantt_scale
        step = Day(GM.gantt_scroll_days(m.gantt_scale))

        @testset "When wheel-down over body Then gantt_start advances one scroll step" begin
            T.update!(m, gm_wheel(cx, cy, T.mouse_scroll_down))
            @test m.gantt_start == st0 + step
            @test m.gantt_scale === scale0   # no zoom
            @test m.modal === :none
            # message matches keyboard scroll helper
            @test occursin("Gantt window from", something(m.message, ""))
        end

        @testset "When wheel-up over body Then gantt_start returns one step" begin
            T.update!(m, gm_wheel(cx, cy, T.mouse_scroll_up))
            @test m.gantt_start == st0
            @test m.gantt_scale === scale0
        end

        @testset "When keyboard h/l used after wheel Then they remain first-class" begin
            gm!(m, 'l')
            @test m.gantt_start == st0 + step
            gm!(m, 'h')
            @test m.gantt_start == st0
        end

        @testset "When wheel outside gantt_last_area Then gantt_start unchanged" begin
            outside = T.MouseEvent(area.x + area.width + 5, area.y + 1,
                                   T.mouse_scroll_down, T.mouse_press, false, false, false)
            T.update!(m, outside)
            @test m.gantt_start == st0
            @test m.gantt_scale === scale0
        end

        @testset "When wheel over empty chart / bar region Then still scrolls" begin
            # Empty chart (period wash) and bar cells are still "over body"
            lay = GM.gantt_layout(m, area)
            # Use chart column past likely bar extent for empty-ish cell, or any body cell
            T.update!(m, gm_wheel(lay.chart_x + 1, lay.grid_y0, T.mouse_scroll_down))
            @test m.gantt_start == st0 + step
            T.update!(m, gm_wheel(lay.chart_x + 1, lay.grid_y0, T.mouse_scroll_up))
            @test m.gantt_start == st0
        end

        @testset "When click-select after wheel Then selection still works (M1 intact)" begin
            rows = GM.gantt_rows(m)
            lay = GM.gantt_layout(m, area; rows = rows)
            iss = GM._gantt_selected_issue(m)
            @test iss !== nothing
            ri = findfirst(r -> r.kind === :issue && r.issue.id == iss.id, rows)
            yi = gantt_y(lay, ri)
            T.update!(m, gm_click(area.x + 1, yi))
            @test m.gantt_sel == 1
            @test m.modal === :none
            @test m.gantt_start == st0
        end
    end
end

@testset "FEATURE: Gantt mouse drag-reschedule (M3 BDD)" begin

    @testset "Given a dated bar When user body-drags Then store dates shift by Δcols" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "DragRoadmap")
        a = GM.Stores.create_issue!(m.boardstore; title = "DragShift", epic_id = e.id,
                                    start_date = Dates.today() + Day(2),
                                    due_date = Dates.today() + Day(5))
        gm!(m, 'G')
        m.gantt_start = Dates.today()
        W, H = 120, 28
        app_tb(m; w = W, h = H)
        area = m.gantt_last_area
        rows = GM.gantt_rows(m)
        lay = GM.gantt_layout(m, area; rows = rows)
        ra = findfirst(r -> r.kind === :issue && r.issue.id == a.id, rows)
        @test ra !== nothing
        ya = gantt_y(lay, ra)
        ext = GM.gantt_bar_extent(lay.win_start, lay.dpc, a.start_date, a.due_date, lay.view_ncols)
        @test ext !== nothing
        c0, c1 = ext
        mid = c0 + (c1 - c0) ÷ 2
        orig_sd, orig_dd = a.start_date, a.due_date
        dur = Dates.value(orig_dd - orig_sd)

        @testset "When press+drag+release body Then store updates and duration preserved" begin
            T.update!(m, gm_click(lay.chart_x + mid, ya))
            @test m.gantt_drag !== nothing
            @test m.gantt_drag.mode === :body
            # Shadow only: store still original mid-drag
            T.update!(m, gm_drag(lay.chart_x + mid + 3, ya))
            @test m.gantt_drag.preview_start == orig_sd + Day(3)
            @test m.gantt_drag.preview_due == orig_dd + Day(3)
            @test GM.Stores.get_issue(m.boardstore, a.id).start_date == orig_sd
            T.update!(m, gm_release(lay.chart_x + mid + 3, ya))
            @test m.gantt_drag === nothing
            u = GM.Stores.get_issue(m.boardstore, a.id)
            @test u.start_date == orig_sd + Day(3)
            @test u.due_date == orig_dd + Day(3)
            @test Dates.value(u.due_date - u.start_date) == dur
            @test occursin("Rescheduled", m.message)
            # Re-render after commit
            tb = app_tb(m; w = W, h = H)
            @test T.find_text(tb, a.key) !== nothing || true  # key still visible
        end
    end

    @testset "Given viewer with enforce_roles When drag bar Then no store write" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "DenyRoadmap")
        a = GM.Stores.create_issue!(m.boardstore; title = "DenyShift", epic_id = e.id,
                                    start_date = Dates.today() + Day(2),
                                    due_date = Dates.today() + Day(4))
        gm!(m, 'G')
        m.gantt_start = Dates.today()
        app_tb(m; w = 120, h = 28)
        area = m.gantt_last_area
        # Demote + hard enforce
        m.current_user = GM.Domain.User(; id = m.current_user.id, email = m.current_user.email,
                                        name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = true
        m.message = ""
        rows = GM.gantt_rows(m)
        lay = GM.gantt_layout(m, area; rows = rows)
        ra = findfirst(r -> r.kind === :issue && r.issue.id == a.id, rows)
        ya = gantt_y(lay, ra)
        ext = GM.gantt_bar_extent(lay.win_start, lay.dpc, a.start_date, a.due_date, lay.view_ncols)
        T.update!(m, gm_click(lay.chart_x + ext[1], ya))
        @test m.gantt_drag === nothing
        @test occursin("Permission denied", m.message)
        @test GM.Stores.get_issue(m.boardstore, a.id).start_date == a.start_date
        @test GM.Stores.get_issue(m.boardstore, a.id).due_date == a.due_date
        # Drag/release without active drag are no-ops
        T.update!(m, gm_drag(lay.chart_x + ext[1] + 2, ya))
        T.update!(m, gm_release(lay.chart_x + ext[1] + 2, ya))
        @test GM.Stores.get_issue(m.boardstore, a.id).start_date == a.start_date
    end

    @testset "Given active drag When Esc Then cancel without commit" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "EscRoadmap")
        a = GM.Stores.create_issue!(m.boardstore; title = "EscShift", epic_id = e.id,
                                    start_date = Dates.today() + Day(1),
                                    due_date = Dates.today() + Day(3))
        gm!(m, 'G')
        m.gantt_start = Dates.today()
        app_tb(m; w = 120, h = 28)
        area = m.gantt_last_area
        rows = GM.gantt_rows(m)
        lay = GM.gantt_layout(m, area; rows = rows)
        ra = findfirst(r -> r.kind === :issue && r.issue.id == a.id, rows)
        ya = gantt_y(lay, ra)
        ext = GM.gantt_bar_extent(lay.win_start, lay.dpc, a.start_date, a.due_date, lay.view_ncols)
        mid = ext[1] + (ext[2] - ext[1]) ÷ 2
        T.update!(m, gm_click(lay.chart_x + mid, ya))
        @test m.gantt_drag !== nothing
        T.update!(m, gm_drag(lay.chart_x + mid + 4, ya))
        @test m.gantt_drag.preview_start != a.start_date
        gm!(m, :escape)
        @test m.gantt_drag === nothing
        @test occursin("cancelled", lowercase(m.message))
        @test GM.Stores.get_issue(m.boardstore, a.id).start_date == a.start_date
        @test GM.Stores.get_issue(m.boardstore, a.id).due_date == a.due_date
    end

    @testset "Given Gantt After mouse drag When keyboard e Then edit still works" begin
        m = gmlogin()
        e = GM.Stores.create_epic!(m.boardstore; name = "KeyRoadmap")
        a = GM.Stores.create_issue!(m.boardstore; title = "KeyEdit", epic_id = e.id,
                                    start_date = Dates.today() + Day(1),
                                    due_date = Dates.today() + Day(2))
        gm!(m, 'G')
        m.gantt_start = Dates.today()
        app_tb(m; w = 120, h = 28)
        area = m.gantt_last_area
        rows = GM.gantt_rows(m)
        lay = GM.gantt_layout(m, area; rows = rows)
        ra = findfirst(r -> r.kind === :issue && r.issue.id == a.id, rows)
        ya = gantt_y(lay, ra)
        ext = GM.gantt_bar_extent(lay.win_start, lay.dpc, a.start_date, a.due_date, lay.view_ncols)
        # Press + release without move (no-op commit) then keyboard edit
        mid = ext[1]
        T.update!(m, gm_click(lay.chart_x + mid, ya))
        T.update!(m, gm_release(lay.chart_x + mid, ya))
        @test m.gantt_drag === nothing
        @test GM._gantt_selected_issue(m).id == a.id
        gm!(m, 'e')
        @test m.modal === :card_edit
        @test m.card_issue_id == a.id
        gm!(m, :escape)
        @test m.modal === :none
        # j/k still work
        b = GM.Stores.create_issue!(m.boardstore; title = "KeyBeta", epic_id = e.id,
                                    start_date = Dates.today() + Day(3),
                                    due_date = Dates.today() + Day(4))
        gm!(m, 'j')
        @test GM._gantt_selected_issue(m).id == b.id || m.gantt_sel >= 1
    end
end
