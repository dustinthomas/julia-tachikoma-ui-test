# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — soft refresh R + ops (PR-H2):
# KeyEvent 'R' reloads projects_cache, prunes deleted selected_ids,
# closes modal when card_issue_id is gone, revalidates inactive user.
# Driven via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qm = QciKanban
_login_ops(name = "Ops Refresh") = (m = Qm.AppModel(; token_path = tempname(), secret = "s");
                                    app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))

@testset "FEATURE: soft refresh R (PR-H2 ops)" begin

    @testset "Given logged-in board When R Then message Refreshed and selection kept" begin
        m = _login_ops()
        @test m.current_user !== nothing
        n0 = length(m.projects_cache)
        u!(m, ' ')
        @test !isempty(m.selected_ids)
        sel_before = copy(m.selected_ids)
        u!(m, 'R')
        @test m.message == "Refreshed"
        @test m.current_user !== nothing
        @test length(m.projects_cache) == n0
        @test m.selected_ids == sel_before
        tb = app_tb(m; w = 100, h = 24)
        @test T.find_text(tb, "Refreshed") !== nothing
    end

    @testset "Given second project created behind the model When R Then projects_cache grows" begin
        m = _login_ops("Cache Grow")
        @test length(m.projects_cache) == 1
        Qm.Stores.create_project!(m.boardstore; key = "LINEB", name = "Line B")
        # cache still stale until soft refresh
        @test length(m.projects_cache) == 1
        u!(m, 'R')
        @test m.message == "Refreshed"
        @test length(m.projects_cache) == 2
        @test any(p -> p.key == "LINEB", m.projects_cache)
    end

    @testset "Given active project archived When R Then fallback project + selection cleared" begin
        m = _login_ops("Archive Fallback")
        old_id = m.active_project_id
        la = Qm.Stores.create_project!(m.boardstore; key = "LINEC", name = "Line C")
        # Select a card and open edit on the current (Default) project.
        issues = Qm.Stores.list_issues(m.boardstore; project_id = old_id)
        @test !isempty(issues)
        push!(m.selected_ids, issues[1].id)
        m.card_issue_id = issues[1].id
        m.edit_form = Qm._build_edit_form(m, issues[1])
        m.modal = :card_edit
        m.focus = Qm.FocusState()
        # Another seat archives the active project; cache still stale.
        Qm.Stores.archive_project!(m.boardstore, old_id)
        @test m.active_project_id == old_id
        u!(m, 'R')
        @test m.message == "Refreshed"
        @test m.active_project_id == la.id
        @test isempty(m.selected_ids)
        @test m.modal == :none
        @test m.card_issue_id === nothing
        @test any(p -> p.id == la.id, m.projects_cache)
        @test !any(p -> p.id == old_id, m.projects_cache)
    end

    @testset "Given selected id deleted When R Then selected_ids pruned" begin
        m = _login_ops("Prune Sel")
        issues = Qm.Stores.list_issues(m.boardstore; project_id = m.active_project_id)
        @test !isempty(issues)
        gone = issues[1].id
        push!(m.selected_ids, gone)
        # also add a fake id that never existed
        push!(m.selected_ids, "no-such-issue-id")
        Qm.Stores.delete_issue!(m.boardstore, gone)
        u!(m, 'R')
        @test m.message == "Refreshed"
        @test !(gone in m.selected_ids)
        @test !("no-such-issue-id" in m.selected_ids)
    end

    @testset "Given open edit on deleted issue When R Then modal closes" begin
        m = _login_ops("Modal Close")
        issues = Qm.Stores.list_issues(m.boardstore; project_id = m.active_project_id)
        @test !isempty(issues)
        id = issues[1].id
        m.card_issue_id = id
        m.edit_form = Qm._build_edit_form(m, issues[1])
        m.modal = :card_edit
        m.focus = Qm.FocusState()  # no editor focus so R is not typed into a field
        Qm.Stores.delete_issue!(m.boardstore, id)
        u!(m, 'R')
        @test m.modal == :none
        @test m.card_issue_id === nothing
        @test m.message == "Refreshed"
    end

    @testset "Given open edit on live issue When R Then modal preserved" begin
        m = _login_ops("Modal Keep")
        issues = Qm.Stores.list_issues(m.boardstore; project_id = m.active_project_id)
        @test !isempty(issues)
        id = issues[1].id
        m.card_issue_id = id
        m.edit_form = Qm._build_edit_form(m, issues[1])
        m.modal = :card_edit
        m.focus = Qm.FocusState()  # no editor focus so R reaches soft_refresh
        u!(m, 'R')
        @test m.modal == :card_edit
        @test m.card_issue_id == id
        @test m.message == "Refreshed"
    end

    @testset "Given deactivated user When R Then logout + login_error" begin
        m = _login_ops("Dead Account")
        uid = m.current_user.id
        Qm.Stores.deactivate_user!(m.userstore, uid)
        u!(m, 'R')
        @test m.current_user === nothing
        @test m.login_error == "Account no longer active"
        @test m.message == ""  # no "Refreshed" after logout
        tb = app_tb(m; w = 80, h = 20)
        @test T.find_text(tb, "Account no longer active") !== nothing ||
              T.find_text(tb, "LOGIN") !== nothing
    end

    @testset "Given not logged in When R Then no-op" begin
        m = Qm.AppModel(; token_path = tempname(), secret = "s", restore = false)
        @test m.current_user === nothing
        u!(m, 'R')
        @test m.current_user === nothing
        @test m.message != "Refreshed"
    end

    @testset "Keymap: global R is soft_refresh; lowercase r unbound on global" begin
        @test Qm.lookup_action(:global, T.KeyEvent('R')) == :soft_refresh
        @test Qm.lookup_action(:global, T.KeyEvent('r')) === nothing
        hl = Qm.help_lines([:global])
        @test any(occursin("Refresh", l) for l in hl)
    end
end
