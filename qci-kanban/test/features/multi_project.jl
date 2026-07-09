# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — multi-project scope (PR-M2 / design §4.2 Phase B):
# login loads Default active project; lists/board are project-scoped;
# dual active sprints across projects; P switcher clears selection.
# Driven via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qm = QciKanban
_login_mp(name = "Ops Lead") = (m = Qm.AppModel(; token_path = tempname(), secret = "s");
                                app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))

@testset "FEATURE: multi-project scope (PR-M2 BDD)" begin

    @testset "Given login When board opens Then active project is Default and shown" begin
        m = _login_mp()
        @test m.active_project_id !== nothing
        p = Qm.Stores.get_project(m.boardstore, m.active_project_id)
        @test p !== nothing && p.key == "QCI" && p.name == "Default"
        @test !isempty(m.projects_cache)
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, "PROJECT:") !== nothing
        @test T.find_text(tb, "Default") !== nothing || T.find_text(tb, "QCI") !== nothing
        # seed demo issues are in Default
        issues = Qm.Stores.list_issues(m.boardstore; project_id = m.active_project_id)
        @test !isempty(issues)
        @test all(i -> i.project_id == m.active_project_id, issues)
    end

    @testset "Given two projects When each starts a sprint Then both are active independently" begin
        m = _login_mp("Dual Sprint")
        def_id = m.active_project_id
        la = Qm.Stores.create_project!(m.boardstore; key = "LINEA", name = "Line A")
        # Explicit future sprints on each project (seed Sprint 1 may already be future).
        sa = Qm.Stores.create_sprint!(m.boardstore; name = "A-week", project_id = def_id,
                                     start_date = today(), end_date = today() + Day(7))
        sb = Qm.Stores.create_sprint!(m.boardstore; name = "B-week", project_id = la.id,
                                     start_date = today(), end_date = today() + Day(7))
        Qm.Stores.start_sprint!(m.boardstore, sa.id)
        @test Qm.Stores.active_sprint(m.boardstore; project_id = def_id).id == sa.id
        # Line A can start independently while Default is already active
        Qm.Stores.start_sprint!(m.boardstore, sb.id)
        @test Qm.Stores.active_sprint(m.boardstore; project_id = la.id).id == sb.id
        @test Qm.Stores.active_sprint(m.boardstore; project_id = def_id).id == sa.id
        # UI start on Default is blocked (already active in this project).
        # 'C' first so global 'K' (backlog) is not shadowed by board rank-up.
        u!(m, 'C'); u!(m, 'K'); u!(m, 'S')
        @test occursin("already active", m.message)
    end

    @testset "Given two projects When switching with P Then selection clears and board scopes" begin
        m = _login_mp("Switcher")
        def_id = m.active_project_id
        la = Qm.Stores.create_project!(m.boardstore; key = "SITE2", name = "Site Two")
        Qm.Stores.create_issue!(m.boardstore; title = "Only on Site Two", project_id = la.id,
                                status = "Backlog")
        # select a card on Default so we can assert selection clears
        u!(m, ' ')
        @test !isempty(m.selected_ids)

        # open switcher
        u!(m, 'P')
        @test m.modal == :project_switch
        tb = app_tb(m; w = 80, h = 24)
        @test T.find_text(tb, "SWITCH PROJECT") !== nothing
        @test T.find_text(tb, "Site Two") !== nothing
        # navigate to Site Two (projects sorted by key: QCI then SITE2)
        u!(m, 'j')
        u!(m, :enter)
        @test m.modal == :none
        @test m.active_project_id == la.id
        @test isempty(m.selected_ids)
        # board only shows Site Two issues
        grid = Qm.board_grid(m)
        titles = String[iss.title for lane in grid for col in lane.cols for iss in col]
        @test "Only on Site Two" in titles
        @test !any(occursin("Set up project board", t) for t in titles)
        # switch back to Default
        u!(m, 'P'); u!(m, 'k'); u!(m, :enter)
        @test m.active_project_id == def_id
        grid2 = Qm.board_grid(m)
        titles2 = String[iss.title for lane in grid2 for col in lane.cols for iss in col]
        @test any(occursin("Set up project board", t) for t in titles2)
        @test !("Only on Site Two" in titles2)
    end

    @testset "Given create card When saved Then issue lands in active project" begin
        m = _login_mp("Create Scope")
        la = Qm.Stores.create_project!(m.boardstore; key = "NEWP", name = "New Plant")
        Qm._set_active_project!(m, la.id)
        @test m.active_project_id == la.id
        u!(m, 'n')
        @test m.modal == :card_edit
        for ch in collect("Scoped WO"); u!(m, ch); end
        u!(m, (:ctrl, 's'))
        @test m.modal == :none
        found = filter(i -> i.title == "Scoped WO",
                       Qm.Stores.list_issues(m.boardstore; project_id = la.id))
        @test length(found) == 1
        @test found[1].project_id == la.id
        @test startswith(found[1].key, "NEWP-")
        # Default project must not have it
        def = only(filter(p -> p.key == "QCI",
                          Qm.Stores.list_projects(m.boardstore; include_archived = true)))
        @test isempty(filter(i -> i.title == "Scoped WO",
                             Qm.Stores.list_issues(m.boardstore; project_id = def.id)))
    end

    @testset "Given only Default When P pressed Then switcher opens (create via n)" begin
        m = _login_mp("One Proj")
        @test length(m.projects_cache) == 1
        u!(m, 'P')
        @test m.modal == :project_switch
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "SWITCH PROJECT") !== nothing
        @test T.find_text(tb, "Default") !== nothing || T.find_text(tb, "QCI") !== nothing
        # empty toast message branch: project label alone still renders
        u!(m, :escape)
        m.message = ""
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "PROJECT:") !== nothing
        # no-project toast branch (defensive; logout clears active project)
        m.active_project_id = nothing
        m.message = "hello"
        tb2 = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb2, "hello") !== nothing
    end

    @testset "Given all projects archived When P pressed Then forced create-project modal" begin
        m = _login_mp("Empty Proj")
        def = only(Qm.Stores.list_projects(m.boardstore))
        # archive Default → list_projects empty
        Qm.Stores.archive_project!(m.boardstore, def.id)
        Qm._load_projects!(m)
        @test isempty(m.projects_cache)
        @test m.active_project_id === nothing
        u!(m, 'P')
        @test m.modal == :project_create
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "NEW PROJECT") !== nothing
        # Esc cannot dismiss when no projects exist
        u!(m, :escape)
        @test m.modal == :project_create
        @test occursin("required", m.message)
        # Fail-closed: unset active project must not unfilter to all issues
        @test isempty(Qm.Stores.list_issues(m.boardstore; project_id = Qm._scope(m)))
        titles = String[iss.title for lane in Qm.board_grid(m) for col in lane.cols for iss in col]
        @test isempty(titles) || all(isempty, titles)
    end

    @testset "Given project switch When toast shows Then message is short not double PROJECT" begin
        m = _login_mp("Toast")
        la = Qm.Stores.create_project!(m.boardstore; key = "TOST", name = "Toast Site")
        Qm._set_active_project!(m, la.id)
        @test occursin("Switched to Toast Site", m.message)
        @test !occursin("PROJECT:", m.message)   # prefix lives on toast, not message
        tb = app_tb(m; w = 100, h = 24)
        # toast shows PROJECT: once; message is the short "Switched to …"
        rows = app_rows(m; w = 100, h = 24)
        joined = join(rows, "\n")
        # count PROJECT: occurrences in the full frame — should be 1 (prefix only)
        @test count("PROJECT:", joined) == 1
        @test occursin("Switched to", joined)
    end
end
