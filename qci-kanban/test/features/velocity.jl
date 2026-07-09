# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — velocity / sprint metrics (PR-M4 / design §4.3):
# closing a planning window snapshots sprint_metrics before incomplete
# rollback; backlog footer shows velocity spark + avg for the project.
# Driven via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qv = QciKanban
_login_vel(name = "Vel Lead") = (m = Qv.AppModel(; token_path = tempname(), secret = "s");
                                 app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))

@testset "FEATURE: velocity sprint metrics (PR-M4 BDD)" begin

    @testset "Given an active window When closed Then metrics snapshot before rollback" begin
        m = _login_vel("Close Snap")
        pid = m.active_project_id
        # Fresh future sprint with known points so metrics are assertable.
        sp = Qv.Stores.create_sprint!(m.boardstore; name = "Vel Week",
                                      project_id = pid,
                                      start_date = today(), end_date = today() + Day(7))
        d1 = Qv.Stores.create_issue!(m.boardstore; title = "Done A", project_id = pid,
                                     story_points = 5, sprint_id = sp.id, status = "To Do")
        d2 = Qv.Stores.create_issue!(m.boardstore; title = "Done B", project_id = pid,
                                     story_points = 3, sprint_id = sp.id, status = "To Do")
        inc = Qv.Stores.create_issue!(m.boardstore; title = "Incomplete", project_id = pid,
                                      story_points = 8, sprint_id = sp.id, status = "In Progress")
        Qv.Stores.start_sprint!(m.boardstore, sp.id)
        Qv.Stores.move_issue!(m.boardstore, d1.id; status = "Done")
        Qv.Stores.move_issue!(m.boardstore, d2.id; status = "Done")

        # Close via UI confirm path (the single owner of record_sprint_metrics!).
        u!(m, 'C'); u!(m, 'K')                     # backlog
        @test m.view == :backlog
        u!(m, 'X'); u!(m, 'y')
        @test Qv.Stores.get_sprint(m.boardstore, sp.id).state == :closed
        # incomplete rolled back; Done stay
        @test Qv.Stores.get_issue(m.boardstore, inc.id).sprint_id === nothing
        @test Qv.Stores.get_issue(m.boardstore, d1.id).sprint_id == sp.id

        mets = Qv.Stores.list_sprint_metrics(m.boardstore; project_id = pid, limit = 8)
        @test any(x -> x.sprint_id == sp.id, mets)
        snap = only(filter(x -> x.sprint_id == sp.id, mets))
        @test snap.project_id == pid
        @test snap.planned_units == 16          # 5+3+8 at close, before rollback
        @test snap.completed_units == 8         # 5+3 Done
        @test snap.completed_count == 2
        @test snap.incomplete_count == 1
        @test snap.unit_kind == :points
    end

    @testset "Given closed windows When backlog shown Then velocity footer with avg" begin
        m = _login_vel("Footer Chart")
        pid = m.active_project_id
        # Seed two metrics rows (simulates prior closed windows).
        Qv.Stores.record_sprint_metrics!(m.boardstore, Qv.Domain.SprintMetrics(;
            sprint_id = "hist-1", project_id = pid,
            planned_units = 10, completed_units = 8, completed_count = 3,
            incomplete_count = 1, unit_kind = :points,
            closed_at = DateTime(2026, 1, 1)))
        Qv.Stores.record_sprint_metrics!(m.boardstore, Qv.Domain.SprintMetrics(;
            sprint_id = "hist-2", project_id = pid,
            planned_units = 12, completed_units = 12, completed_count = 4,
            incomplete_count = 0, unit_kind = :points,
            closed_at = DateTime(2026, 1, 8)))
        # Default config velocity_unit is :count → avg of completed_count
        m.config.velocity_unit = :count
        u!(m, 'C'); u!(m, 'K')
        @test m.view == :backlog
        # No active sprint → velocity footer (not burndown)
        @test Qv.Stores.active_sprint(m.boardstore; project_id = pid) === nothing
        tb = app_tb(m; w = 100, h = 28)
        blob = join(app_rows(m; w = 100, h = 28), "\n")
        @test occursin("VEL", blob) || T.find_text(tb, "VEL") !== nothing
        @test occursin("avg=", blob)
        @test occursin("n=2", blob)
        # avg of completed_count 3 and 4 = 3.5 → rounds to 4 (or 3); accept either
        @test occursin("avg=4", blob) || occursin("avg=3", blob)
    end

    @testset "Given points unit When series plotted Then completed_units used" begin
        m = _login_vel("Points Unit")
        pid = m.active_project_id
        Qv.Stores.record_sprint_metrics!(m.boardstore, Qv.Domain.SprintMetrics(;
            sprint_id = "pu-1", project_id = pid,
            completed_units = 13, completed_count = 2, closed_at = DateTime(2026, 2, 1)))
        m.config.velocity_unit = :points
        mets = Qv.Stores.list_sprint_metrics(m.boardstore; project_id = pid)
        series = Qv.velocity_series(mets; unit = m.config.velocity_unit)
        @test 13.0 in series
        u!(m, 'C'); u!(m, 'K')
        blob = join(app_rows(m; w = 100, h = 28), "\n")
        @test occursin("VEL", blob)
        @test occursin("avg=13", blob) || occursin("pts", blob)
    end
end
