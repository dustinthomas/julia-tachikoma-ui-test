using Test
using Tachikoma
using Dates
const T = Tachikoma

using QciKanban
const KanbanModel = QciKanban.KanbanModel

@testset "QciKanban Phase 5: calendar view + marks (TestBackend)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_board!(m)
    T.update!(m, T.KeyEvent('c'))
    @test m.view_mode == :calendar
    @test m.cal !== nothing

    tb = T.TestBackend(70, 16)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    # Month name or year should be visible
    @test T.find_text(tb, string(Dates.year(Dates.today()))) !== nothing || T.find_text(tb, "DUE") !== nothing
end

@testset "calendar dues + no-dues/empty secondary visible (visual_rows + find_text/row_text after update!)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_board!(m)
    T.update!(m, T.KeyEvent('c'))  # after update!
    @test m.view_mode == :calendar
    rows = visual_rows(m; w=80, h=18)
    # dues or no-dues text (both use secondary now) must be visible
    @test any(occursin("DUE THIS MONTH", r) for r in rows)
    @test any(occursin("QCI-", r) || occursin("no dues", r) || occursin("no dues in data", r) for r in rows)
    tb = T.TestBackend(80, 18)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    @test T.find_text(tb, "DUE") !== nothing
    @test T.row_text(tb, 5) !== nothing
end
