# Phase 4 — Gantt view: pure date→column geometry + timeline rendering
# (BlockCanvas bars, diamonds for single-date issues, today marker, sprint
# bands), zoom week/month, scroll, row selection, Enter → card detail.
# Geometry is unit-tested directly; rendering is asserted via TestBackend
# row_text run-lengths (offset-independent).

using Dates
G4 = QciKanban
g4!(m, x) = T.update!(m, T.KeyEvent(x))
gantt_login() = (m = fresh_app(; seed = false); app_login_new(m; name = "Gantt User"); m)

# longest run of char `ch` in string `s`
function maxrun(s::AbstractString, ch::Char)
    best = 0; cur = 0
    for c in s
        cur = c == ch ? cur + 1 : 0
        best = max(best, cur)
    end
    best
end
gantt_render(m; w = 120, h = 30) = begin
    tb = T.TestBackend(w, h); T.reset!(tb.buf)
    G4.render_gantt!(m, tb.buf, T.Rect(1, 1, w, h))
    tb
end
row_with(tb, key, h) = begin
    r = nothing
    for i in 1:h
        rt = T.row_text(tb, i)
        rt !== nothing && occursin(key, rt) && (r = rt; break)
    end
    r
end

@testset "Phase 4 — Gantt geometry (pure)" begin
    ws = Date(2026, 3, 10)
    @test G4.gantt_days_per_col(:week) == 1
    @test G4.gantt_days_per_col(:month) == 7
    @test G4.gantt_scroll_days(:week) == 7
    @test G4.gantt_scroll_days(:month) == 28
    @test G4.gantt_col_for_date(ws, 1, Date(2026, 3, 15)) == 5
    @test G4.gantt_col_for_date(ws, 7, Date(2026, 3, 24)) == 2
    @test G4.gantt_col_for_date(ws, 1, Date(2026, 3, 7)) == -3      # before window (fld floors)
    @test G4.gantt_window_end(ws, 1, 10) == ws + Day(9)
    @test G4.gantt_window_end(ws, 7, 4) == ws + Day(27)

    @testset "gantt_bar_extent clamps / swaps / rejects" begin
        @test G4.gantt_bar_extent(ws, 1, Date(2026, 3, 12), Date(2026, 3, 16), 40) == (2, 6)
        @test G4.gantt_bar_extent(ws, 1, Date(2026, 3, 16), Date(2026, 3, 12), 40) == (2, 6)  # swapped
        @test G4.gantt_bar_extent(ws, 1, Date(2026, 1, 1), Date(2026, 1, 5), 40) === nothing  # off-left
        @test G4.gantt_bar_extent(ws, 1, Date(2026, 6, 1), Date(2026, 6, 5), 40) === nothing  # off-right
        @test G4.gantt_bar_extent(ws, 1, Date(2026, 3, 8), Date(2026, 3, 14), 40) == (0, 4)   # left-clamped
        @test G4.gantt_bar_extent(ws, 1, Date(2026, 3, 12), Date(2026, 4, 30), 20) == (2, 19) # right-clamped
    end

    @testset "gantt_point_col in / out / nothing" begin
        @test G4.gantt_point_col(ws, 1, Date(2026, 3, 18), 40) == 8
        @test G4.gantt_point_col(ws, 1, Date(2026, 3, 5), 40) === nothing   # before
        @test G4.gantt_point_col(ws, 1, Date(2026, 3, 18), 3) === nothing   # past right edge
        @test G4.gantt_point_col(ws, 1, nothing, 40) === nothing
    end
end

@testset "Phase 4 — Gantt rendering" begin

    @testset "empty: no dated issues → 'No scheduled issues'" begin
        m = gantt_login(); g4!(m, 'G')
        @test m.view == :gantt
        tb = gantt_render(m)
        @test T.find_text(tb, "GANTT") !== nothing
        @test T.find_text(tb, "No scheduled issues") !== nothing
        # row-nav / detail are inert with nothing scheduled
        g4!(m, 'j'); @test m.gantt_sel == 1
        @test G4._gantt_selected_issue(m) === nothing
        g4!(m, :enter); @test m.modal == :none
    end

    @testset "bars: deterministic extents via block-char run-lengths" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "Timeline")
        a = G4.Stores.create_issue!(m.boardstore; title = "Alpha", epic_id = e.id,
                                    start_date = Date(2026, 3, 12), due_date = Date(2026, 3, 16))
        b = G4.Stores.create_issue!(m.boardstore; title = "Beta", epic_id = e.id,
                                    start_date = Date(2026, 3, 14), due_date = Date(2026, 3, 20))
        g4!(m, 'G')                                     # init → win_start = 2026-03-12 (earliest)
        @test m.gantt_start == Date(2026, 3, 12)
        tb = gantt_render(m)
        @test T.find_text(tb, "Timeline") !== nothing   # epic header row
        ra = row_with(tb, a.key, 30); rb = row_with(tb, b.key, 30)
        @test ra !== nothing && maxrun(ra, '█') == 5    # Mar12→16 inclusive @ dpc 1
        @test rb !== nothing && maxrun(rb, '█') == 7    # Mar14→20 inclusive @ dpc 1
    end

    @testset "zoom z toggles week↔month scale and rescales bars" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "Zoomy")
        a = G4.Stores.create_issue!(m.boardstore; title = "Span", epic_id = e.id,
                                    start_date = Date(2026, 3, 12), due_date = Date(2026, 3, 16))
        g4!(m, 'G')
        @test m.gantt_scale == :week
        tb = gantt_render(m); @test maxrun(row_with(tb, a.key, 30), '█') == 5
        g4!(m, 'z')
        @test m.gantt_scale == :month
        tb2 = gantt_render(m)
        @test T.find_text(tb2, "[month]") !== nothing
        @test maxrun(row_with(tb2, a.key, 30), '█') == 1   # 5 days collapse into one week-column
        g4!(m, 'z'); @test m.gantt_scale == :week
    end

    @testset "single-date issues render a diamond; off-window issues draw nothing" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "Points")
        pt = G4.Stores.create_issue!(m.boardstore; title = "Milestone", epic_id = e.id,
                                     due_date = Date(2026, 3, 18))            # single date → diamond
        far = G4.Stores.create_issue!(m.boardstore; title = "FarBar", epic_id = e.id,
                                      start_date = Date(2030, 1, 1), due_date = Date(2030, 2, 1))
        farpt = G4.Stores.create_issue!(m.boardstore; title = "FarPoint", epic_id = e.id,
                                        due_date = Date(2030, 5, 5))
        g4!(m, 'G')                                       # win_start = 2026-03-18 (earliest in-store)
        tb = gantt_render(m)
        @test T.find_text(tb, "◆") !== nothing
        rpt = row_with(tb, pt.key, 30);  @test occursin("◆", rpt)
        rfar = row_with(tb, far.key, 30); @test rfar !== nothing && maxrun(rfar, '█') == 0   # off-window bar
        rfp = row_with(tb, farpt.key, 30); @test rfp !== nothing && !occursin("◆", rfp)      # off-window diamond
    end

    @testset "no-epic issues fall under a 'No Epic' band" begin
        m = gantt_login()
        G4.Stores.create_issue!(m.boardstore; title = "Loose", due_date = Date(2026, 3, 15))
        g4!(m, 'G')
        tb = gantt_render(m)
        @test T.find_text(tb, "No Epic") !== nothing
    end

    @testset "today marker: vertical line at today's column (computed from Dates.today())" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "Now")
        G4.Stores.create_issue!(m.boardstore; title = "Around today", epic_id = e.id,
                                start_date = Dates.today() - Day(1), due_date = Dates.today() + Day(1))
        g4!(m, 'G')
        @test m.gantt_start == Dates.today() - Day(1)
        # pure column of today matches the render window
        w = 120; left_w = clamp(w ÷ 3, 14, 22); ncols = w - left_w
        expect = G4.gantt_point_col(m.gantt_start, 1, Dates.today(), ncols)
        @test expect == 1
        tb = gantt_render(m; w = w, h = 20)
        loc = T.find_text(tb, "▼")
        @test loc !== nothing
        @test T.char_at(tb, loc.x, loc.y + 1) == '│'         # vertical line directly under the marker
    end

    @testset "sprint bands: dated sprints shade their column range with the name" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "S")
        G4.Stores.create_issue!(m.boardstore; title = "in-window", epic_id = e.id,
                                start_date = Date(2026, 3, 12), due_date = Date(2026, 3, 20))
        # sprints created via store with explicit dates
        C4store = m.boardstore
        s = G4.Stores.create_sprint!(C4store; name = "SprintBand")
        G4.Stores.update_sprint!(C4store, s.id; start_date = Date(2026, 3, 13), end_date = Date(2026, 3, 30))
        G4.Stores.create_sprint!(C4store; name = "NoDates")                       # no dates → skipped
        s3 = G4.Stores.create_sprint!(C4store; name = "OffWindow")
        G4.Stores.update_sprint!(C4store, s3.id; start_date = Date(2030, 1, 1), end_date = Date(2030, 1, 5))
        g4!(m, 'G')
        bands = G4.gantt_sprint_bands(m, m.gantt_start, 1, 60)
        @test any(nm == "SprintBand" for (nm, _, _) in bands)
        @test !any(nm == "NoDates" for (nm, _, _) in bands)      # dateless sprint skipped
        @test !any(nm == "OffWindow" for (nm, _, _) in bands)    # off-window sprint skipped
        tb = gantt_render(m)
        @test T.find_text(tb, "SprintBand") !== nothing
        @test T.find_text(tb, "░") !== nothing
    end

    @testset "row selection j/k highlights; Enter opens detail; scroll shifts window" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "Sel")
        a = G4.Stores.create_issue!(m.boardstore; title = "First", epic_id = e.id,
                                    start_date = Date(2026, 3, 12), due_date = Date(2026, 3, 14))
        b = G4.Stores.create_issue!(m.boardstore; title = "Second", epic_id = e.id,
                                    start_date = Date(2026, 3, 15), due_date = Date(2026, 3, 18))
        g4!(m, 'G')
        @test m.gantt_sel == 1
        @test G4._gantt_selected_issue(m).id == a.id
        g4!(m, 'j'); @test m.gantt_sel == 2
        @test G4._gantt_selected_issue(m).id == b.id
        g4!(m, 'k'); @test m.gantt_sel == 1
        # arrow keys mirror
        g4!(m, :down); @test m.gantt_sel == 2
        # Enter → detail of the selected issue
        g4!(m, :enter)
        @test m.modal == :card_detail && m.card_issue_id == b.id
        g4!(m, :escape)                          # back to gantt
        # scroll right then left moves the window by a week
        st0 = m.gantt_start
        g4!(m, 'l'); @test m.gantt_start == st0 + Day(7)
        g4!(m, 'h'); @test m.gantt_start == st0
        g4!(m, :right); @test m.gantt_start == st0 + Day(7)
        g4!(m, :left);  @test m.gantt_start == st0
    end

    @testset "many rows clamp to the visible height (no overflow)" begin
        m = gantt_login()
        e = G4.Stores.create_epic!(m.boardstore; name = "Many")
        for i in 1:12
            G4.Stores.create_issue!(m.boardstore; title = "Task $i", epic_id = e.id,
                                    start_date = Date(2026, 3, 10) + Day(i), due_date = Date(2026, 3, 12) + Day(i))
        end
        g4!(m, 'G')
        tb = T.TestBackend(80, 8); T.reset!(tb.buf)
        G4.render_gantt!(m, tb.buf, T.Rect(1, 1, 80, 8))     # only ~6 rows fit
        @test T.find_text(tb, "GANTT") !== nothing
        @test T.find_text(tb, "Many") !== nothing
    end

    @testset "small-terminal guard" begin
        m = gantt_login(); g4!(m, 'G')
        tb = T.TestBackend(20, 5); T.reset!(tb.buf)
        G4.render_gantt!(m, tb.buf, T.Rect(1, 1, 20, 5))
        @test T.find_text(tb, "Gantt needs") !== nothing
    end
end
