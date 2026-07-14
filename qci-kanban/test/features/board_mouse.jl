# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance for Board mouse B1 + B2
#   • Left-press card body selects (sel_lane/col/idx; keyboard ▸ in sync)
#   • Second left-press on already-selected card body opens detail (same as v)
#   • Press different body reselects; does NOT open
#   • Bulk selected_ids stable on mouse select (K13 — Space remains bulk toggle)
#   • Login / modal / empty board_last_area / non-board ignore
#   • Gantt smoke: bar click still selects (regression after view-switch)
#   • B2: ASCII [<]/[>] press-arm release-fire; gap no-op; WIP soft; no free-hover
# Driven via update!(m, MouseEvent(...)) + TestBackend re-render.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

BM = QciKanban
bmlogin(; name = "Board Mouse User") = (m = fresh_app(; seed = false); app_login_new(m; name = name); m)
bm!(m, x) = T.update!(m, T.KeyEvent(x))
bm_click(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_press, false, false, false)
bm_drag(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_drag, false, false, false)
bm_release(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_release, false, false, false)
gantt_y(lay, row_index) = lay.grid_y0 + (row_index - lay.row_start) * lay.row_stride

@testset "FEATURE: Board mouse body click-select (B1 BDD)" begin

    @testset "Given two cards on the board" begin
        m = bmlogin()
        a = BM.Stores.create_issue!(m.boardstore; title = "BoardMouseAlpha", status = "Backlog")
        b = BM.Stores.create_issue!(m.boardstore; title = "BoardMouseBeta", status = "Backlog")
        @test m.view === :board
        W, H = 100, 30
        tb = app_tb(m; w = W, h = H)
        @test m.board_last_area.width >= 1 && m.board_last_area.height >= 1
        area = m.board_last_area
        lay = BM.board_layout(m, area)
        sa = findfirst(s -> s.issue_id == a.id, lay.slots)
        sb = findfirst(s -> s.issue_id == b.id, lay.slots)
        @test sa !== nothing && sb !== nothing
        slot_a = lay.slots[sa]
        slot_b = lay.slots[sb]
        cx(s) = s.rect.x + max(0, s.rect.width ÷ 2)
        cy(s) = s.rect.y + max(0, s.rect.height ÷ 2)

        @testset "When the user left-clicks card B body Then it is selected and modal stays closed" begin
            T.update!(m, bm_click(cx(slot_b), cy(slot_b)))
            @test BM.selected_issue(m).id == b.id
            @test m.sel_lane == slot_b.lane && m.sel_col == slot_b.col && m.sel_idx == slot_b.idx
            @test m.modal === :none
            # Re-render: selection chrome ▸ present
            tb2 = app_tb(m; w = W, h = H)
            blob = join([something(T.row_text(tb2, i), "") for i in 1:H], "\n")
            @test occursin("▸", blob)
            @test occursin(b.key, blob) || occursin("BoardMouseBeta", blob)
        end

        @testset "When the user left-clicks the same selected body again Then detail opens" begin
            # Re-layout after any prior selects (area cache still valid)
            lay2 = BM.board_layout(m, m.board_last_area)
            sb2 = findfirst(s -> s.issue_id == b.id, lay2.slots)
            @test sb2 !== nothing
            slot_b2 = lay2.slots[sb2]
            T.update!(m, bm_click(cx(slot_b2), cy(slot_b2)))
            @test m.modal === :card_detail
            @test m.card_issue_id == b.id
            @test m.board_hover === nothing
            bm!(m, :escape)
            @test m.modal === :none
            @test BM.selected_issue(m).id == b.id   # selection retained after close
        end

        @testset "When the user left-clicks a different body Then it reselects without opening" begin
            lay3 = BM.board_layout(m, m.board_last_area)
            sa3 = findfirst(s -> s.issue_id == a.id, lay3.slots)
            @test sa3 !== nothing
            slot_a3 = lay3.slots[sa3]
            T.update!(m, bm_click(cx(slot_a3), cy(slot_a3)))
            @test BM.selected_issue(m).id == a.id
            @test m.modal === :none
        end

        @testset "When bulk selected_ids is non-empty and mouse selects another card Then bulk set is unchanged (K13)" begin
            push!(m.selected_ids, a.id)
            push!(m.selected_ids, b.id)
            bulk_before = copy(m.selected_ids)
            lay4 = BM.board_layout(m, m.board_last_area)
            sb4 = findfirst(s -> s.issue_id == b.id, lay4.slots)
            @test sb4 !== nothing
            T.update!(m, bm_click(cx(lay4.slots[sb4]), cy(lay4.slots[sb4])))
            @test BM.selected_issue(m).id == b.id
            @test m.selected_ids == bulk_before
            @test m.modal === :none
        end

        @testset "When the user presses v after mouse select Then detail still opens (keyboard first-class)" begin
            BM._select_issue!(m, a.id)
            bm!(m, 'v')
            @test m.modal === :card_detail
            @test m.card_issue_id == a.id
            bm!(m, :escape)
            @test m.modal === :none
        end

        @testset "When the user clicks empty chrome Then selection is unchanged" begin
            BM._select_issue!(m, a.id)
            lay5 = BM.board_layout(m, m.board_last_area)
            T.update!(m, bm_click(m.board_last_area.x + 2, lay5.grid_area.y))
            @test BM.selected_issue(m).id == a.id
            @test m.modal === :none
        end
    end

    @testset "Given login / modal / empty area — board mouse is a no-op for selection" begin
        # Empty area: on board but never rendered
        m = bmlogin()
        BM.Stores.create_issue!(m.boardstore; title = "GateIss", status = "Backlog")
        @test m.view === :board
        @test m.board_last_area.width == 0
        sel0 = BM.selected_issue(m)
        T.update!(m, bm_click(10, 10))
        @test BM.selected_issue(m).id == sel0.id

        # Modal open (help) on board
        app_tb(m; w = 100, h = 24)
        bm!(m, '?')
        @test m.modal === :help
        sel1 = BM.selected_issue(m)
        area = m.board_last_area
        lay = BM.board_layout(m, area)
        if !isempty(lay.slots)
            s = first(lay.slots)
            T.update!(m, bm_click(s.rect.x + 1, s.rect.y + 1))
        else
            T.update!(m, bm_click(area.x + 1, area.y + 4))
        end
        @test BM.selected_issue(m).id == sel1.id
        @test m.modal === :help
        bm!(m, :escape)

        # Logged-out: no current_user
        m2 = fresh_app(; seed = false)
        @test m2.current_user === nothing
        m2.view = :board
        m2.board_last_area = T.Rect(1, 1, 80, 20)
        m2.sel_lane = 1; m2.sel_col = 1; m2.sel_idx = 1
        T.update!(m2, bm_click(5, 8))
        @test m2.current_user === nothing
        @test m2.modal === :none
    end

    @testset "Given Gantt mouse still works after board mouse lands (regression)" begin
        m = bmlogin()
        e = BM.Stores.create_epic!(m.boardstore; name = "MouseRoadmap")
        a = BM.Stores.create_issue!(m.boardstore; title = "GanttSmokeA", epic_id = e.id,
                                    start_date = Dates.today() + Day(8),
                                    due_date = Dates.today() + Day(11))
        b = BM.Stores.create_issue!(m.boardstore; title = "GanttSmokeB", epic_id = e.id,
                                    start_date = Dates.today() + Day(9),
                                    due_date = Dates.today() + Day(13))
        # Exercise board path first so dispatcher has both branches live
        app_tb(m; w = 100, h = 28)
        @test m.view === :board
        bm!(m, 'G')
        m.gantt_start = Dates.today() - Day(1)
        @test m.view === :gantt
        W, H = 120, 28
        tb = app_tb(m; w = W, h = H)
        @test m.gantt_last_area.width >= 1
        area = m.gantt_last_area
        rows = BM.gantt_rows(m)
        lay = BM.gantt_layout(m, area; rows = rows)
        rb = findfirst(r -> r.kind === :issue && r.issue.id == b.id, rows)
        @test rb !== nothing
        yb = gantt_y(lay, rb)
        ext_b = BM.gantt_bar_extent(lay.win_start, lay.dpc, b.start_date, b.due_date, lay.view_ncols)
        @test ext_b !== nothing
        T.update!(m, bm_click(lay.chart_x + ext_b[1], yb))
        @test m.gantt_sel == 2
        @test BM._gantt_selected_issue(m).id == b.id
        @test m.modal === :none
        # Board still works when switching back
        bm!(m, 'B')
        app_tb(m; w = 100, h = 28)
        @test m.view === :board
        @test m.board_last_area.width >= 1
        layb = BM.board_layout(m, m.board_last_area)
        @test !isempty(layb.slots)
        # Prefer a card that is not already under the keyboard cursor so the
        # first body press only selects (select-then-activate would open detail).
        cur = BM.selected_issue(m)
        s = something(findfirst(sl -> cur === nothing || sl.issue_id != cur.id, layb.slots), 1)
        slot = layb.slots[s]
        T.update!(m, bm_click(slot.rect.x + 1, slot.rect.y + 1))
        @test BM.selected_issue(m).id == slot.issue_id
        @test m.modal === :none
    end

    @testset "Given idle clock — mouse activity on board refreshes last_input_at" begin
        m = bmlogin()
        BM.Stores.create_issue!(m.boardstore; title = "IdleBoardIss", status = "Backlog")
        app_tb(m; w = 100, h = 24)
        old = m.last_input_at
        sleep(0.01)
        T.update!(m, bm_click(m.board_last_area.x + 1, m.board_last_area.y + 4))
        @test m.last_input_at >= old
        @test m.tick >= 1
    end
end

@testset "FEATURE: Board mouse ASCII move buttons arm/release (B2 BDD)" begin

    @testset "Given a card with move chrome When press-release on [>] Then status advances" begin
        m = bmlogin()
        iss = BM.Stores.create_issue!(m.boardstore; title = "BddMoveNext", status = "To Do")
        BM._select_issue!(m, iss.id)
        W, H = 100, 30
        tb = app_tb(m; w = W, h = H)
        lay = BM.board_layout(m, m.board_last_area)
        si = findfirst(s -> s.issue_id == iss.id && s.next_btn !== nothing, lay.slots)
        @test si !== nothing
        s = lay.slots[si]
        # Paint shows ASCII buttons (no Unicode arrows)
        blob = join([something(T.row_text(tb, i), "") for i in 1:H], "\n")
        @test occursin("[<]", blob) && occursin("[>]", blob)
        for bad in ("◀", "▶", "←", "→")
            @test !occursin(bad, blob)
        end

        T.update!(m, bm_click(s.next_btn.x, s.next_btn.y))
        @test m.board_hover !== nothing && m.board_hover.armed === true
        @test m.board_hover.kind === :move_next
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "To Do"
        # Drag updates hot (still on next)
        T.update!(m, bm_drag(s.next_btn.x, s.next_btn.y))
        @test m.board_hover.kind === :move_next
        T.update!(m, bm_release(s.next_btn.x, s.next_btn.y))
        @test m.board_hover === nothing
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "In Progress"
        @test m.modal === :none
    end

    @testset "Given armed move When release off button Then cancel; gap never opens detail" begin
        m = bmlogin()
        iss = BM.Stores.create_issue!(m.boardstore; title = "BddGapCancel", status = "In Progress")
        BM._select_issue!(m, iss.id)
        app_tb(m; w = 100, h = 30)
        lay = BM.board_layout(m, m.board_last_area)
        si = findfirst(s -> s.issue_id == iss.id && s.prev_btn !== nothing, lay.slots)
        @test si !== nothing
        s = lay.slots[si]
        # Gap on selected card: no-op (K11)
        T.update!(m, bm_click(s.gap_btn.x, s.gap_btn.y))
        @test m.modal === :none
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "In Progress"
        # Arm then release off → cancel
        T.update!(m, bm_click(s.next_btn.x, s.next_btn.y))
        @test m.board_hover !== nothing
        T.update!(m, bm_release(s.rect.x + 1, s.rect.y + 1))
        @test m.board_hover === nothing
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "In Progress"
        # Successful prev move
        T.update!(m, bm_click(s.prev_btn.x, s.prev_btn.y))
        T.update!(m, bm_release(s.prev_btn.x, s.prev_btn.y))
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "To Do"
    end

    @testset "Given bulk selection + WIP When mouse advances into over-limit Then soft warn and bulk stable" begin
        m = bmlogin()
        m.wip_limits["Review"] = 1
        occ = BM.Stores.create_issue!(m.boardstore; title = "BddWipOcc", status = "Review")
        mover = BM.Stores.create_issue!(m.boardstore; title = "BddWipMover", status = "In Progress")
        push!(m.selected_ids, occ.id)
        bulk_before = copy(m.selected_ids)
        BM._select_issue!(m, mover.id)
        app_tb(m; w = 100, h = 30)
        lay = BM.board_layout(m, m.board_last_area)
        si = findfirst(s -> s.issue_id == mover.id && s.next_btn !== nothing, lay.slots)
        @test si !== nothing
        s = lay.slots[si]
        T.update!(m, bm_click(s.next_btn.x, s.next_btn.y))
        T.update!(m, bm_release(s.next_btn.x, s.next_btn.y))
        @test BM.Stores.get_issue(m.boardstore, mover.id).status == "Review"
        @test occursin("WIP limit exceeded", m.message)
        @test m.selected_ids == bulk_before
    end

    @testset "Given keyboard first-class When < / > still move without mouse" begin
        m = bmlogin()
        iss = BM.Stores.create_issue!(m.boardstore; title = "BddKeyMove", status = "To Do")
        BM._select_issue!(m, iss.id)
        app_tb(m; w = 100, h = 24)
        bm!(m, '>')
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "In Progress"
        bm!(m, '<')
        @test BM.Stores.get_issue(m.boardstore, iss.id).status == "To Do"
        @test m.board_hover === nothing
    end
end
