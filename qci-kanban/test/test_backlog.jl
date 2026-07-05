# Phase 3 — backlog view + sprint lifecycle (create/start/close with rollback),
# move issue ↔ sprint, board active-sprint filter. Driven only via update!.

Qb = QciKanban
lbb() = (m = Qb.AppModel(; token_path = tempname(), secret = "s"); app_login_new(m; name = "Lin T"); m)
kb!(m, x) = T.update!(m, T.KeyEvent(x))
typb!(m, s) = (for ch in collect(s); T.update!(m, T.KeyEvent(ch)); end)
goto_backlog(m) = (kb!(m, 'C'); kb!(m, 'K'))   # board→calendar→backlog (board shadows K for rank-up)

@testset "Phase 3 — Backlog view renders sprints + backlog" begin
    m = lbb()
    goto_backlog(m)
    @test m.view == :backlog
    tb = app_tb(m; w = 100, h = 30)
    @test T.find_text(tb, "Sprint 1") !== nothing          # seeded sprint
    @test T.find_text(tb, "Backlog") !== nothing
    rows = app_rows(m; w = 100, h = 30)
    @test any(occursin("future", r) for r in rows)         # sprint state badge
end

@testset "Phase 3 — Create sprint (n) in backlog" begin
    m = lbb(); goto_backlog(m)
    n0 = length(Qb.Stores.list_sprints(m.boardstore))
    kb!(m, 'n')
    @test m.modal == :new_sprint
    tb = app_tb(m; w = 100, h = 30)
    @test T.find_text(tb, "NEW SPRINT") !== nothing
    typb!(m, "Sprint 2")
    kb!(m, :tab); typb!(m, "Ship backlog view")
    kb!(m, :enter)
    @test m.modal == :none
    ss = Qb.Stores.list_sprints(m.boardstore)
    @test length(ss) == n0 + 1
    @test any(s.name == "Sprint 2" && s.goal == "Ship backlog view" for s in ss)
end

# Reposition the backlog cursor onto issue `id` by pressing j/k (cursor is a
# plain index reachable purely through navigation keys).
function backlog_cursor_to!(m, id)
    items = Qb._backlog_selectable(m)
    i = findfirst(x -> x.id == id, items)
    i === nothing && return
    while m.backlog_sel > i; T.update!(m, T.KeyEvent('k')); end
    while m.backlog_sel < i; T.update!(m, T.KeyEvent('j')); end
end

@testset "Phase 3 — Move issue backlog ↔ sprint" begin
    m = lbb(); goto_backlog(m)
    sel = Qb._backlog_selected_issue(m)
    @test sel !== nothing
    kb!(m, '>')                                    # into the target (seeded future) sprint
    @test Qb.Stores.get_issue(m.boardstore, sel.id).sprint_id !== nothing
    backlog_cursor_to!(m, sel.id)                  # re-point cursor onto the moved issue
    kb!(m, '<')                                    # back to backlog
    @test Qb.Stores.get_issue(m.boardstore, sel.id).sprint_id === nothing
end

@testset "Phase 3 — Backlog navigation j/k stays in bounds" begin
    m = lbb(); goto_backlog(m)
    n = length(Qb._backlog_selectable(m))
    @test n >= 1
    for _ in 1:(n + 3); kb!(m, 'j'); end
    @test m.backlog_sel == n
    for _ in 1:(n + 3); kb!(m, 'k'); end
    @test m.backlog_sel == 1
end

@testset "Phase 3 — Sprint lifecycle: start (single active) + close with rollback" begin
    m = lbb(); goto_backlog(m)
    # seeded Sprint 1 is future and has 2 issues (To Do + In Progress)
    @test Qb.Stores.active_sprint(m.boardstore) === nothing
    kb!(m, 'S')                                     # start the future sprint
    asp = Qb.Stores.active_sprint(m.boardstore)
    @test asp !== nothing
    @test occursin("Started", m.message)
    # starting again → still only one active
    kb!(m, 'S')
    @test occursin("already active", m.message)

    # put one of the sprint's issues to Done so it should NOT roll back
    sissues = Qb.Stores.issues_for_sprint(m.boardstore, asp.id)
    done_one = first(sissues)
    Qb.Stores.move_issue!(m.boardstore, done_one.id; status = "Done")
    incomplete = [i for i in sissues if i.id != done_one.id]

    kb!(m, 'X')                                     # request close → confirm modal
    @test m.modal == :confirm
    kb!(m, 'y')                                     # confirm close
    @test m.modal == :none
    @test Qb.Stores.get_sprint(m.boardstore, asp.id).state == :closed
    # incomplete rolled back to backlog; the Done one stays in the sprint
    for i in incomplete
        @test Qb.Stores.get_issue(m.boardstore, i.id).sprint_id === nothing
    end
    @test Qb.Stores.get_issue(m.boardstore, done_one.id).sprint_id == asp.id
end

@testset "Phase 3 — Backlog edge cases" begin
    @testset "move-to-backlog on a loose issue reports already-in-backlog" begin
        m = lbb(); goto_backlog(m)
        sel = Qb._backlog_selected_issue(m)       # first row; seeded loose backlog exists
        # ensure cursor is on a loose (no-sprint) issue
        items = Qb._backlog_selectable(m)
        loose = findfirst(i -> i.sprint_id === nothing, items)
        @test loose !== nothing
        while m.backlog_sel > loose; kb!(m, 'k'); end
        while m.backlog_sel < loose; kb!(m, 'j'); end
        kb!(m, '<')
        @test occursin("already in backlog", m.message)
    end

    @testset "start/close with no eligible sprint reports gracefully" begin
        # a fresh board with all sprints closed → nothing to start, nothing to close
        m = lbb(); goto_backlog(m)
        kb!(m, 'S')                                # start the one future sprint
        kb!(m, 'X'); kb!(m, 'y')                   # close it
        @test Qb.Stores.active_sprint(m.boardstore) === nothing
        kb!(m, 'S')
        @test occursin("No future sprint", m.message)
        kb!(m, 'X')
        @test occursin("No active sprint", m.message)
    end

    @testset "move-to-sprint with no sprint available reports and no-ops" begin
        # build a model with NO sprints by closing the seeded one, then delete-free:
        m = lbb(); goto_backlog(m)
        # close the seeded sprint so no future/active sprint remains
        kb!(m, 'S'); kb!(m, 'X'); kb!(m, 'y')
        sel = Qb._backlog_selected_issue(m)
        @test sel !== nothing
        kb!(m, '>')
        @test occursin("No sprint to move into", m.message)
    end
end

@testset "Phase 3 — Backlog card ops (v / e / d) driven from the backlog cursor" begin
    @testset "v opens card detail for the backlog-selected issue; esc closes, no list bleed" begin
        m = lbb(); goto_backlog(m)
        iss = Qb._backlog_selected_issue(m)
        @test iss !== nothing
        kb!(m, 'v')
        @test m.modal == :card_detail
        @test m.card_issue_id == iss.id
        tb = app_tb(m; w = 100, h = 30)
        @test T.find_text(tb, iss.key) !== nothing
        @test T.find_text(tb, "COMMENTS") !== nothing
        # content area is cleared under the overlay → backlog list badge gone
        @test T.find_text(tb, "future") === nothing
        kb!(m, :escape)
        @test m.modal == :none
    end

    @testset "Enter also opens detail from the backlog" begin
        m = lbb(); goto_backlog(m)
        iss = Qb._backlog_selected_issue(m)
        kb!(m, :enter)
        @test m.modal == :card_detail
        @test m.card_issue_id == iss.id
    end

    @testset "e opens the edit form loaded with the selected issue; save persists" begin
        m = lbb(); goto_backlog(m)
        iss = Qb._backlog_selected_issue(m)
        kb!(m, 'e')
        @test m.modal == :card_edit
        @test m.card_issue_id == iss.id
        @test Qb.text(m.edit_form.title_input) == iss.title
        tb = app_tb(m; w = 100, h = 30)
        @test T.find_text(tb, "EDIT CARD") !== nothing
        typb!(m, "!")                       # append to the focused title field
        kb!(m, :enter)                      # save
        @test m.modal == :none
        @test Qb.Stores.get_issue(m.boardstore, iss.id).title == iss.title * "!"
        @test any(a.kind == :updated for a in Qb.Stores.list_activity(m.boardstore, iss.id))
    end

    @testset "e then Esc cancels without mutating the issue" begin
        m = lbb(); goto_backlog(m)
        iss = Qb._backlog_selected_issue(m)
        before = iss.title
        kb!(m, 'e')
        @test m.modal == :card_edit
        typb!(m, "SCRATCH")
        kb!(m, :escape)
        @test m.modal == :none
        @test Qb.Stores.get_issue(m.boardstore, iss.id).title == before
    end

    @testset "d asks to confirm delete_one; n aborts, d+y deletes" begin
        m = lbb(); goto_backlog(m)
        iss = Qb._backlog_selected_issue(m)
        n0 = length(Qb.Stores.list_issues(m.boardstore))
        kb!(m, 'd')
        @test m.modal == :confirm
        @test m.confirm_kind == :delete_one
        @test m.confirm_target == iss.id
        tb = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb, "CONFIRM") !== nothing
        kb!(m, 'n')                         # abort
        @test m.modal == :none
        @test Qb.Stores.get_issue(m.boardstore, iss.id) !== nothing
        @test length(Qb.Stores.list_issues(m.boardstore)) == n0
        # now really delete
        iss2 = Qb._backlog_selected_issue(m)
        kb!(m, 'd'); kb!(m, 'y')
        @test m.modal == :none
        @test Qb.Stores.get_issue(m.boardstore, iss2.id) === nothing
        @test length(Qb.Stores.list_issues(m.boardstore)) == n0 - 1
    end
end

@testset "Phase 3 — Board active-sprint quick filter (p)" begin
    m = lbb()
    # start the seeded sprint from the backlog, then filter the board by it
    goto_backlog(m); kb!(m, 'S')
    asp = Qb.Stores.active_sprint(m.boardstore)
    @test asp !== nothing
    kb!(m, 'B')                                     # back to board
    kb!(m, 'p')                                     # active-sprint filter
    @test :sprint in m.active_filters
    vis = filter(i -> Qb._passes_filters(m, i), Qb.Stores.list_issues(m.boardstore))
    @test !isempty(vis)
    @test all(i -> i.sprint_id == asp.id, vis)
end
