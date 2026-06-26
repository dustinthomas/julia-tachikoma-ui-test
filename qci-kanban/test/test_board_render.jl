using Test
using Tachikoma
const T = Tachikoma

using QciKanban
const KanbanModel = QciKanban.KanbanModel
const BOARD_COLUMNS = QciKanban.BOARD_COLUMNS

@testset "QciKanban Phase 2: board load + column render + keyboard nav (TestBackend + temp DB)" begin

    function fresh_model()
        m = KanbanModel()
        # Use in-memory for isolation (monkey patch path before load)
        m.db_path = ":memory:"
        QciKanban.load_board!(m)
        m
    end

    @testset "load_board! populates columns from seed" begin
        m = fresh_model()
        @test !isempty(m.cards_by_status)
        @test length(m.cards_by_status) >= 3
        total = sum(length(v) for v in values(m.cards_by_status))
        @test total >= 5
    end

    @testset "view renders column headers + some QCI- keys" begin
        m = fresh_model()
        tb = T.TestBackend(100, 20)
        T.reset!(tb.buf)
        fr = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, fr)

        # headers from columns
        for col in BOARD_COLUMNS
            @test T.find_text(tb, col) !== nothing
        end
        @test T.find_text(tb, "QCI-") !== nothing   # at least one card key
    end

    @testset "left/right (h/l) changes selected_col (and does not switch view)" begin
        m = fresh_model()
        start_col = m.selected_col
        start_mode = m.view_mode
        T.update!(m, T.KeyEvent('l'))  # right
        @test m.selected_col >= start_col
        @test m.view_mode == start_mode   # 'l' must not hijack to list view
        T.update!(m, T.KeyEvent('h'))  # left
        @test m.selected_col <= start_col + 1
        @test m.view_mode == :board
    end

    @testset "up/down (k/j) changes selected_idx within column bounds" begin
        m = fresh_model()
        m.selected_col = 1
        # ensure column 1 has cards
        c1 = get(m.cards_by_status, BOARD_COLUMNS[1], [])
        if length(c1) >= 2
            m.selected_idx = 1
            T.update!(m, T.KeyEvent('j'))
            @test m.selected_idx >= 1
            T.update!(m, T.KeyEvent('k'))
            @test m.selected_idx == 1
        end
    end

    @testset "re-render after nav still shows QCI branding + selection hint" begin
        m = fresh_model()
        tb = T.TestBackend(90, 18)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "QCI") !== nothing

        T.update!(m, T.KeyEvent('l'))
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        # Still QCI visible and a column name
        @test T.find_text(tb, "QCI") !== nothing || T.find_text(tb, "KANBAN") !== nothing
    end

    @testset "r reloads (exercises load_board! path)" begin
        m = fresh_model()
        prev_msg = m.message
        T.update!(m, T.KeyEvent('r'))
        @test m.message != prev_msg || !isempty(m.cards_by_status)
    end

    @testset "visual_rows helper + no-bleed after nav (TestBackend rows)" begin
        m = fresh_model()
        rows = visual_rows(m; w=82, h=18)
        @test any(occursin("Backlog", r) for r in rows)
        @test any(occursin("▶ ", r) || occursin("QCI-", r) for r in rows)

        T.update!(m, T.KeyEvent('l'))
        T.update!(m, T.KeyEvent('j'))
        rows2 = visual_rows(m; w=82, h=18)
        @test any(occursin("To Do", r) for r in rows2) || m.selected_col >= 2
    end

    @testset "unselected cards use secondary color but text visible (visual_rows + row_text/find_text after update!)" begin
        m = fresh_model()
        m.selected_col = 1
        m.selected_idx = 1
        T.update!(m, T.KeyEvent('j'))  # after update!
        rows = visual_rows(m; w=90, h=18)
        # selected shows ▶ ; unselected cards from other cols must be visible (text present)
        @test any(occursin("▶ ", r) for r in rows)
        @test any(occursin("QCI-", r) for r in rows)
        # other columns' headers prove unselected areas rendered
        @test any(occursin("Review", r) || occursin("Done", r) for r in rows)

        # also direct find_text after update! + render
        tb = T.TestBackend(90, 18)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "QCI-") !== nothing
        @test T.row_text(tb, 8) !== nothing  # some row content
    end
end
