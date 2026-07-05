# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance for Phase 3 — Jira board (PHASES.md "Phase 3" acceptance):
# swimlane-by-epic grid correctness, bulk move of 3 cards + activity rows,
# WIP warn, sprint lifecycle incl. rollback. Given/When/Then, driven purely
# via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test

Q3f = QciKanban
_login(name = "Dev One") = (m = Q3f.AppModel(; token_path = tempname(), secret = "s");
                            app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, T.KeyEvent(x))

@testset "FEATURE: Phase 3 Jira board (BDD acceptance)" begin

    @testset "Given swimlane-by-epic with issues across epics and statuses" begin
        m = _login()
        u!(m, 's'); u!(m, 's')                     # → epic swimlanes
        @testset "When the grid is built Then each epic band has cards in the right status cells" begin
            @test m.swimlane_by == :epic
            g = Q3f.board_grid(m)
            @test length(g) >= 2
            for lane in g, (ci, cell) in enumerate(lane.cols), iss in cell
                @test iss.status == Q3f.BOARD_STATUSES[ci]
                k, nm = Q3f._lane_of(m, iss)
                @test nm == lane.name              # card belongs to its lane
            end
        end
        @testset "When a card moves Then only that card's cell changes" begin
            iss = Q3f.selected_issue(m)
            @test iss !== nothing
            others = Dict(i.id => i.status for i in Q3f.Stores.list_issues(m.boardstore) if i.id != iss.id)
            u!(m, '>')
            for (id, st) in others
                @test Q3f.Stores.get_issue(m.boardstore, id).status == st
            end
            @test Q3f.Stores.get_issue(m.boardstore, iss.id).status != iss.status
        end
    end

    @testset "Given three selected cards When bulk-moved Then all land in target + activity logged" begin
        m = _login()
        # select three Backlog/To-Do cards by walking the grid
        u!(m, ' ')                                 # QCI-100 (Backlog)
        u!(m, 'j'); u!(m, ' ')                     # QCI-101 (Backlog)
        u!(m, 'l'); u!(m, ' ')                     # a To Do card
        @test length(m.selected_ids) == 3
        ids = collect(m.selected_ids)
        u!(m, 'l')                                 # cursor → In Progress column (col 3)
        @test m.sel_col == 3
        u!(m, 'M')                                 # bulk move
        for id in ids
            @test Q3f.Stores.get_issue(m.boardstore, id).status == "In Progress"
            @test any(a.kind == :status_changed for a in Q3f.Stores.list_activity(m.boardstore, id))
        end
    end

    @testset "Given a column at its WIP limit When a card moves in Then it warns (move allowed)" begin
        m = _login()
        # Review WIP limit is 2; seed has 1. Add one more to reach the limit.
        Q3f.Stores.create_issue!(m.boardstore; title = "review filler", status = "Review")
        iss = Q3f.selected_issue(m)                # a Backlog card
        for _ in 1:3; u!(m, '>'); end              # Backlog → … → Review (now 3 > 2)
        @test Q3f.Stores.get_issue(m.boardstore, iss.id).status == "Review"
        @test occursin("WIP limit exceeded", m.message)
        tb = app_tb(m; w = 110, h = 30)
        loc = T.find_text(tb, "Review 3/2")
        @test loc !== nothing
        @test T.style_at(tb, loc.x, loc.y).fg == Q3f.Theming.col_err()
    end

    @testset "Given a sprint When started and closed Then incomplete issues roll back to backlog" begin
        m = _login()
        u!(m, 'C'); u!(m, 'K')                     # → backlog view
        @test m.view == :backlog
        u!(m, 'S')                                 # start seeded future sprint
        asp = Q3f.Stores.active_sprint(m.boardstore)
        @test asp !== nothing
        sissues = Q3f.Stores.issues_for_sprint(m.boardstore, asp.id)
        @test !isempty(sissues)
        # mark one Done; it should stay, the rest roll back
        done1 = first(sissues)
        Q3f.Stores.move_issue!(m.boardstore, done1.id; status = "Done")
        rest = [i for i in sissues if i.id != done1.id]
        u!(m, 'X'); u!(m, 'y')                     # close via confirm
        @test Q3f.Stores.get_sprint(m.boardstore, asp.id).state == :closed
        @test Q3f.Stores.get_issue(m.boardstore, done1.id).sprint_id == asp.id
        for i in rest
            @test Q3f.Stores.get_issue(m.boardstore, i.id).sprint_id === nothing
        end
    end

    @testset "Given a notifier When a card is assigned Then an outbox row is enqueued" begin
        # Wire the OutboxNotifier into the app; assign-to-me must enqueue a row.
        m = Q3f.AppModel(; token_path = tempname(), secret = "s", seed = true)
        # replace the notifier with an OutboxNotifier over the same board store
        m.notifier = Q3f.Notify.OutboxNotifier(m.boardstore)
        app_login_new(m; name = "Notify Me")
        @test isempty(Q3f.Stores.pending_outbox(m.boardstore))
        u!(m, 'a')                                 # assign selected to me
        pend = Q3f.Stores.pending_outbox(m.boardstore)
        @test !isempty(pend)
        @test any(row["event_kind"] == "assigned" for row in pend)
    end
end
