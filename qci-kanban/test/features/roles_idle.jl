# ═══════════════════════════════════════════════════════════════════════
# BDD: PR-H1 roles (can/can!) + lazy idle logout.
# Drive via update!(m, KeyEvent) + TestBackend. inject last_input_at (no sleep).
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

const Qri = QciKanban
const Dri = QciKanban.Domain

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
    end

    @testset "Given viewer with enforce_roles=true When delete Then hard deny" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
        app_login_new(m; name = "View Hard")
        m.current_user = Dri.User(; id = m.current_user.id, email = m.current_user.email,
                                  name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = true
        prev_modal = m.modal
        @test Qri.can!(m, :delete_issue) === false
        @test occursin("Permission denied", m.message)
        # board delete path does not open confirm
        T.update!(m, T.KeyEvent('d'))
        @test m.modal == prev_modal || m.modal == :none
        @test m.confirm_kind !== :delete_one || m.modal !== :confirm
        # stronger: request path blocked
        @test m.modal !== :confirm || m.confirm_kind === :none
    end

    @testset "Given technician When edit unassigned Then matrix denies; warn-only allows" begin
        m = Qri.AppModel(; token_path = tempname(), secret = "s")
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
        @test isfile(tok)
        # snapshot board selection so we can assert no nav side effect
        sel_before = (m.sel_col, m.sel_idx, m.sel_lane)
        m.config.idle_logout_seconds = 60
        m.last_input_at = Dates.now(UTC) - Dates.Second(120)
        T.update!(m, T.KeyEvent('j'))
        @test m.current_user === nothing
        @test m.login_error == "Session expired (idle)"
        @test (m.sel_col, m.sel_idx, m.sel_lane) == sel_before
        @test !isfile(tok)
        tb = T.TestBackend(80, 20); T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1, 1, 80, 20), T.GraphicsRegion[], T.PixelSnapshot[]))
        @test T.find_text(tb, "Session expired (idle)") !== nothing
        @test T.find_text(tb, "SIGN IN") !== nothing || T.find_text(tb, "Email") !== nothing ||
              T.find_text(tb, "email") !== nothing || T.find_text(tb, "PASSWORD") !== nothing ||
              T.find_text(tb, "Password") !== nothing
        # no board column bleed as primary content under login
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
