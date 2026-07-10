# ═══════════════════════════════════════════════════════════════════════
# BDD: PR-H1 roles (can/can!) + lazy idle logout.
# Drive via update!(m, KeyEvent) + TestBackend. inject last_input_at (no sleep).
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

const Qri = QciKanban
const Dri = QciKanban.Domain
const Sri = QciKanban.Stores

@testset "FEATURE: roles + lazy idle logout (PR-H1 BDD)" begin

    @testset "Given first empty-store create When account is made Then role is admin" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("admin@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("Admin One"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("pw12"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user !== nothing
        @test m.current_user.role == "admin"
        @test m.last_input_at isa DateTime
    end

    @testset "Given viewer with enforce_roles=false When delete Then warn + allow" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
        app_login_new(m; name = "View User")
        # demote to viewer after login (store still has admin; session role is what can! uses)
        m.current_user = Dri.User(; id = m.current_user.id, email = m.current_user.email,
                                  name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = false
        @test Dri.can(m.current_user, :delete_issue) === false
        @test Qri.can!(m, :delete_issue) === true
        @test occursin("Role warning", m.message)
        @test occursin("viewer", m.message)
        # warn toast preserved across success message helper
        Qri._set_message!(m, "Deleted issue")
        @test occursin("Role warning", m.message)
        @test occursin("Deleted issue", m.message)
    end

    @testset "Given viewer with enforce_roles=true When delete Then hard deny" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s", seed = true)
        app_login_new(m; name = "View Hard")
        iss = Qri.selected_issue(m)
        @test iss !== nothing  # seeded board has a selection
        n_before = length(Sri.list_issues(m.boardstore; project_id = Qri._scope(m)))
        m.current_user = Dri.User(; id = m.current_user.id, email = m.current_user.email,
                                  name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = true
        m.message = ""
        T.update!(m, T.KeyEvent('d'))
        @test m.modal !== :confirm
        @test m.confirm_kind === :none
        @test occursin("Permission denied", m.message)
        @test length(Sri.list_issues(m.boardstore; project_id = Qri._scope(m))) == n_before
        tb = T.TestBackend(80, 20); T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1, 1, 80, 20), T.GraphicsRegion[], T.PixelSnapshot[]))
        @test T.find_text(tb, "Permission denied") !== nothing || occursin("Permission denied", m.message)
        @test T.find_text(tb, "CONFIRM") === nothing && T.find_text(tb, "Delete") === nothing ||
              m.modal !== :confirm
    end

    @testset "Given technician When edit unassigned Then matrix denies; KeyEvent hard deny" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s", seed = true)
        app_login_new(m; name = "Tech User")
        tech = Dri.User(; id = m.current_user.id, email = m.current_user.email,
                        name = m.current_user.name, role = "technician")
        m.current_user = tech
        other = Dri.Issue(; id = "ix", key = "QCI-99", title = "Unowned", assignee_id = "someone-else")
        mine = Dri.Issue(; id = "iy", key = "QCI-100", title = "Mine", assignee_id = tech.id)
        @test Dri.can(tech, :edit_issue; resource = other) === false
        @test Dri.can(tech, :edit_issue; resource = mine) === true
        @test Dri.can(tech, :create_issue) === true
        m.config.enforce_roles = false
        @test Qri.can!(m, :edit_issue; resource = other) === true
        @test occursin("Role warning", m.message)
        m.config.enforce_roles = true
        m.message = ""
        @test Qri.can!(m, :edit_issue; resource = other) === false
        @test occursin("Permission denied", m.message)
        # End-to-end: unassigned selected card + 'e' stays closed under hard enforce
        iss = Qri.selected_issue(m)
        @test iss !== nothing
        Sri.update_issue!(m.boardstore, iss.id; assignee_id = "not-the-tech")
        m.message = ""
        m.modal = :none
        T.update!(m, T.KeyEvent('e'))
        @test m.modal !== :card_edit
        @test m.edit_form === nothing
        @test occursin("Permission denied", m.message)
        tb = T.TestBackend(80, 20); T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1, 1, 80, 20), T.GraphicsRegion[], T.PixelSnapshot[]))
        @test T.find_text(tb, "EDIT CARD") === nothing
        @test T.find_text(tb, "NEW CARD") === nothing
    end

    @testset "Given unauthenticated When can! Then false without crash" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
        @test m.current_user === nothing
        m.config.enforce_roles = false
        @test Qri.can!(m, :delete_issue) === false
        m.config.enforce_roles = true
        @test Qri.can!(m, :delete_issue) === false
        @test occursin("Permission denied", m.message)
    end

    @testset "Given idle_logout_seconds=60 and last_input_at 120s ago When key Then idle logout" begin
        tok = tempname()
        m = Qri.AppModel(; token_path = tok, secret = "s")
        app_login_new(m; name = "Idle User")
        @test m.current_user !== nothing
        uid = m.current_user.id
        tv_before = Sri.get_token_version(m.userstore, uid)
        @test isfile(tok)
        # leave dirty modal state to prove logout hygiene
        m.modal = :confirm
        m.confirm_kind = :delete_one
        m.confirm_target = "x"
        # snapshot board selection so we can assert no nav side effect
        sel_before = (m.sel_col, m.sel_idx, m.sel_lane)
        m.config.idle_logout_seconds = 60
        m.last_input_at = Dates.now(UTC) - Dates.Second(120)
        T.update!(m, T.KeyEvent('j'))
        @test m.current_user === nothing
        @test m.login_error == "Session expired (idle)"
        @test (m.sel_col, m.sel_idx, m.sel_lane) == sel_before
        @test !isfile(tok)
        @test Sri.get_token_version(m.userstore, uid) == tv_before + 1
        @test m.modal === :none
        @test m.confirm_kind === :none
        @test m.confirm_target === nothing
        @test m.edit_form === nothing
        tb = T.TestBackend(80, 20); T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1, 1, 80, 20), T.GraphicsRegion[], T.PixelSnapshot[]))
        @test T.find_text(tb, "Session expired (idle)") !== nothing
        @test T.find_text(tb, "SIGN IN") !== nothing || T.find_text(tb, "Email") !== nothing ||
              T.find_text(tb, "email") !== nothing || T.find_text(tb, "PASSWORD") !== nothing ||
              T.find_text(tb, "Password") !== nothing
        rows = join(app_rows(m), "\n")
        @test occursin("Session expired", rows) || m.login_error == "Session expired (idle)"
    end

    @testset "Given idle_logout_seconds=0 When last_input_at very old Then still logged in" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
        app_login_new(m; name = "No Idle")
        m.config.idle_logout_seconds = 0
        m.last_input_at = Dates.now(UTC) - Dates.Day(30)
        T.update!(m, T.KeyEvent('j'))
        @test m.current_user !== nothing
        @test m.login_error == ""
    end

    @testset "Given idle on but not expired When key Then last_input_at advances" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
        app_login_new(m; name = "Active User")
        m.config.idle_logout_seconds = 900
        old = Dates.now(UTC) - Dates.Second(10)
        m.last_input_at = old
        T.update!(m, T.KeyEvent('j'))
        @test m.current_user !== nothing
        @test m.last_input_at > old
    end
end
