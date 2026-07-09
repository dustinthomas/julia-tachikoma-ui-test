# Phase 5 — gfx: layered QCI logo, board stats strip, sprint burndown,
# subtle (animation-gated) polish, and the scripted v2 demo tour.
# Drives the app exclusively via update!(m, KeyEvent) + TestBackend.

Q = QciKanban
using Dates

# A logged-in v2 board model on isolated stores (reuses test_app_shell helpers).
gfx_model() = (m = fresh_app(); app_login_new(m); m)

# Render a widget/logo call into a fresh TestBackend and return it.
function gfx_tb(f; w = 60, h = 8)
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    f(tb.buf, T.Rect(1, 1, w, h))
    tb
end

# Run `body` with animations forced to `enabled`, restoring the prior state.
function with_animations(body; enabled::Bool)
    prev = T.ANIMATIONS_ENABLED[]
    T.ANIMATIONS_ENABLED[] = enabled
    try
        body()
    finally
        T.ANIMATIONS_ENABLED[] = prev
    end
end

@testset "Phase 5 — gfx logo / charts / demo" begin

    @testset "spinner_glyph is deterministic and cyclic" begin
        @test Q.spinner_glyph(0) == Q.SPINNER_FRAMES[1]
        @test Q.spinner_glyph(0) == Q.spinner_glyph(length(Q.SPINNER_FRAMES))  # wraps
        @test all(Q.spinner_glyph(t) in Q.SPINNER_FRAMES for t in 0:20)
    end

    @testset "logo canvas layer renders under TestBackend with assertable branding" begin
        with_animations(enabled = false) do
            tb = gfx_tb((buf, r) -> (layer = Q.render_qci_logo_v2!(buf, r; tick = 3);
                                     @test layer == :canvas); w = 60, h = 8)
            @test T.find_text(tb, "QCI") !== nothing
            @test T.find_text(tb, "KANBAN") !== nothing
            @test T.find_text(tb, Q.LOGO_TAGLINE) !== nothing
        end
    end

    @testset "logo pixel-art mark: bitmap + scaler + filled render" begin
        # master bitmap is well-formed pixel art (derived from branding/qci-logo-ref.png)
        bm = Q.QCI_MARK_BITMAP
        @test length(bm) >= 12
        @test all(length(r) == length(bm[1]) for r in bm)
        @test all(all(ch -> ch == ' ' || ch == '#', r) for r in bm)
        @test count(==('#'), join(bm)) > 200            # a filled wordmark, not line art

        # pure scaler: deterministic, in-bounds, non-empty at real header dot sizes
        for (dw, dh) in ((160, 20), (100, 12), (52, 8))
            dots = Q._mark_dots(dw, dh)
            @test !isempty(dots)
            @test all(0 <= d[1] < dw && 0 <= d[2] < dh for d in dots)
            @test dots == Q._mark_dots(dw, dh)          # pure / deterministic
        end
        @test isempty(Q._mark_dots(1, 1))               # degenerate: no dots, no throw

        # the rendered mark is substantially filled — the old thin-arc art was sparse
        with_animations(enabled = false) do
            tb = gfx_tb((buf, r) -> Q.render_qci_logo_v2!(buf, r; tick = 0); w = 50, h = 7)
            mark_cells = count(!isspace, join([T.row_text(tb, i) for i in 1:6]))
            @test mark_cells > 110
        end
    end

    @testset "logo tiny fallback is the text layer" begin
        tb = gfx_tb((buf, r) -> (@test Q.render_qci_logo_v2!(buf, r) == :text); w = 8, h = 2)
        @test T.find_text(tb, "QCI") !== nothing
        # zero-size guard
        @test Q.render_qci_logo_v2!(T.TestBackend(60, 8).buf, T.Rect(1, 1, 2, 0)) == :none
    end

    @testset "logo is byte-identical across renders when animations are off" begin
        with_animations(enabled = false) do
            a = [T.row_text(gfx_tb((buf, r) -> Q.render_qci_logo_v2!(buf, r; tick = 5); w = 50, h = 7), i) for i in 1:7]
            b = [T.row_text(gfx_tb((buf, r) -> Q.render_qci_logo_v2!(buf, r; tick = 5); w = 50, h = 7), i) for i in 1:7]
            @test a == b
        end
    end

    @testset "animated glow + spinner branch runs when animations are on" begin
        with_animations(enabled = true) do
            tb = gfx_tb((buf, r) -> Q.render_qci_logo_v2!(buf, r; tick = 2); w = 50, h = 7)
            blob = join([T.row_text(tb, i) for i in 1:7], "")
            @test any(occursin(string(g), blob) for g in Q.SPINNER_FRAMES)
            @test T.find_text(tb, Q.LOGO_TAGLINE) !== nothing
        end
    end

    @testset "column_counts is a pure per-status projection" begin
        m = gfx_model()
        cc = Q.column_counts(m)
        @test length(cc) == length(Q.Domain.STATUSES)
        @test [first(c) for c in cc] == collect(Q.Domain.STATUSES)
        @test sum(last, cc) == length(Q.Stores.list_issues(m.boardstore))
    end

    @testset "stats strip toggles with `t` and renders sparkline + WIP gauge" begin
        m = gfx_model()
        @test m.show_stats == false
        rows0 = app_rows(m; w = 90, h = 26)
        @test !any(occursin("STATS", r) for r in rows0)

        T.update!(m, T.KeyEvent('t'))
        @test m.show_stats == true
        tb = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb, "STATS") !== nothing
        @test T.find_text(tb, "WIP") !== nothing
        # board still present beneath the strip
        @test T.find_text(tb, "Backlog") !== nothing

        T.update!(m, T.KeyEvent('t'))
        @test m.show_stats == false
        @test !any(occursin("STATS", r) for r in app_rows(m; w = 90, h = 26))
    end

    @testset "render_board_stats! no-ops in a tiny area" begin
        m = gfx_model()
        @test Q.render_board_stats!(m, T.TestBackend(60, 8).buf, T.Rect(1, 1, 8, 2)) == 0
    end

    @testset "burndown_series is a pure, monotone-scoped model" begin
        today = Date(2026, 7, 3)
        start = today - Day(4)
        finish = today + Day(9)
        iss = [
            Q.Domain.Issue(; id = "1", key = "QCI-1", title = "a", status = "Done",  updated = DateTime(today)),
            Q.Domain.Issue(; id = "2", key = "QCI-2", title = "b", status = "Done",  updated = DateTime(today)),
            Q.Domain.Issue(; id = "3", key = "QCI-3", title = "c", status = "To Do", updated = DateTime(today)),
            Q.Domain.Issue(; id = "4", key = "QCI-4", title = "d", status = "Review", updated = DateTime(today)),
        ]
        s = Q.burndown_series(iss, start, finish; today = today)
        n = Dates.value(finish - start) + 1
        @test length(s.days) == n == length(s.ideal) == length(s.remaining)
        @test s.total == 4
        @test s.ideal[1] == 4.0
        @test s.ideal[end] == 0.0
        @test s.remaining[1] == 4.0            # start day: nothing burned yet
        @test s.remaining[end] == 2.0          # two Done (as of today) remain burned
        @test Q._remaining_now(s, today) == 2

        # single-day window is widened so the ideal line is defined
        s1 = Q.burndown_series(iss, today, today; today = today)
        @test length(s1.days) == 2
        @test s1.ideal[1] == 4.0 && s1.ideal[end] == 0.0
    end

    @testset "velocity_series is pure chronological completed units/counts" begin
        t0 = DateTime(2026, 1, 1)
        mets = [
            Q.Domain.SprintMetrics(; sprint_id = "a", project_id = "p",
                                   completed_units = 5, completed_count = 2, closed_at = t0),
            Q.Domain.SprintMetrics(; sprint_id = "b", project_id = "p",
                                   completed_units = 8, completed_count = 3,
                                   closed_at = t0 + Day(7)),
        ]
        @test Q.velocity_series(mets; unit = :points) == Float64[5, 8]
        @test Q.velocity_series(mets; unit = :count) == Float64[2, 3]
        @test Q.velocity_series(Q.Domain.SprintMetrics[]; unit = :points) == Float64[]
        # unit_kind on rows is ignored for series pick
        mets2 = [Q.Domain.SprintMetrics(; sprint_id = "c", project_id = "p",
                                        completed_units = 10, completed_count = 4,
                                        unit_kind = :count)]
        @test Q.velocity_series(mets2; unit = :points) == Float64[10]
        @test Q.velocity_series(mets2; unit = :count) == Float64[4]
    end

    @testset "backlog footer: burndown when sprint active; velocity when closed" begin
        m = gfx_model()
        T.update!(m, T.KeyEvent('C'))          # leave board (K = rank-up there)
        T.update!(m, T.KeyEvent('K'))          # backlog view
        @test m.view == :backlog
        # Seeded Sprint 1 is future → no active window → velocity empty state
        tb0 = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb0, "VELOCITY") !== nothing || T.find_text(tb0, "VEL") !== nothing
        @test T.find_text(tb0, "Sprint 1") !== nothing   # list still present

        # Start sprint → burndown footer
        T.update!(m, T.KeyEvent('S'))
        tb1 = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb1, "BURNDOWN") !== nothing
        @test T.find_text(tb1, "Sprint 1") !== nothing

        # Close sprint → velocity spark with avg line
        sissues = Q.Stores.issues_for_sprint(m.boardstore,
            Q.Stores.active_sprint(m.boardstore; project_id = m.active_project_id).id)
        for iss in sissues
            Q.Stores.move_issue!(m.boardstore, iss.id; status = "Done")
        end
        T.update!(m, T.KeyEvent('X'))
        T.update!(m, T.KeyEvent('y'))
        tb2 = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb2, "VEL") !== nothing
        @test T.find_text(tb2, "avg=") !== nothing || any(occursin("avg=", r) for r in app_rows(m; w = 90, h = 26))
    end

    @testset "render_burndown! no-ops when no dated sprint exists" begin
        m = fresh_app(seed = false)            # empty board, no sprints
        app_login_new(m)
        @test Q._burndown_sprint(m) === nothing
        @test Q.render_burndown!(m, T.TestBackend(60, 8).buf, T.Rect(1, 1, 40, 3)) == 0
        # a date-less sprint is skipped (loop iterates, still falls through to nothing)
        Q.Stores.create_sprint!(m.boardstore; name = "No Dates")
        @test Q._burndown_sprint(m) === nothing
        # velocity empty-state still draws a footer line
        @test Q.render_velocity!(m, T.TestBackend(60, 8).buf, T.Rect(1, 1, 40, 3)) > 0
        @test Q.render_velocity!(m, T.TestBackend(60, 8).buf, T.Rect(1, 1, 8, 1)) == 0
    end

    @testset "keymap: `t` → :toggle_stats, surfaced in board help" begin
        @test Q.lookup_action([:board, :global], T.KeyEvent('t')) == :toggle_stats
        @test any(occursin("Stats", l) for l in Q.help_lines([:board]))
    end

    @testset "record_demo2 produces a playable .tach with frames" begin
        mktempdir() do dir
            fn = Q.record_demo2(joinpath(dir, "v2.tach"); frames = 60, fps = 8)
            @test isfile(fn)
            w, h, cells, ts, _ = T.load_tach(fn)
            @test length(cells) > 0
            @test length(cells) == length(ts)
            @test (w, h) == (90, 28)
        end
    end

    @testset "record_demo2 svg export + guarded catch" begin
        mktempdir() do dir
            fn = Q.record_demo2(joinpath(dir, "v2.tach"); frames = 24, fps = 8, svg = true)
            @test isfile(splitext(fn)[1] * ".svg")
        end
        # export from a missing file is caught and skipped gracefully
        @test Q._export_demo(joinpath(tempdir(), "does-not-exist.tach"); svg = true) === nothing
    end
end
