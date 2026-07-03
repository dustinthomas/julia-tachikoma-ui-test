using Test
using Tachikoma
using Dates
const T = Tachikoma

using QciKanban
const KanbanModel = QciKanban.KanbanModel

@testset "QciKanban Phase 5: calendar view + marks (TestBackend)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent('c'))
    for ch in collect("CalTestUser"); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:enter))  # create-account login gate first
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
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent('c'))
    for ch in collect("CalDuesUser"); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:enter))  # create-account login gate first
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

@testset "escape from calendar view reverts to board (targeted TestBackend)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent('c'))
    for ch in collect("CalEscUser"); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:enter))  # create-account login gate first
    T.update!(m, T.KeyEvent('c'))
    @test m.view_mode == :calendar
    T.update!(m, T.KeyEvent(:escape))
    @test m.view_mode == :board
    @test m.quit == false
    rows = visual_rows(m; w=80, h=18)
    @test any(occursin("Backlog", r) || occursin("QCI-", r) for r in rows)
    tb = T.TestBackend(80, 18)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    @test T.find_text(tb, "QCI-") !== nothing
    @test T.find_text(tb, "DUE THIS MONTH") === nothing
    @test T.char_at(tb, 4, 4) isa Char
end

@testset "calendar: '?' opens help, tips differ, escape closes (targeted)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent('c'))
    for ch in collect("CalHelpUser"); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:enter))  # create-account login gate first
    T.update!(m, T.KeyEvent('c'))
    T.update!(m, T.KeyEvent('?'))
    @test m.modal == :help
    @test m.view_mode == :calendar
    @test m.quit == false

    tb = T.TestBackend(80, 18)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    @test T.find_text(tb, "HELP") !== nothing

    T.update!(m, T.KeyEvent(:escape))
    @test m.modal == :none
    rows = visual_rows(m; w=80, h=18)
    @test any(occursin("DUE", r) || occursin("QCI-", r) for r in rows)
    @test !any(occursin("HELP", r) for r in rows)
    tb2 = T.TestBackend(80, 18)
    T.reset!(tb2.buf)
    T.view(m, T.Frame(tb2.buf, T.Rect(1,1,tb2.width,tb2.height), [], []))
    @test T.find_text(tb2, "HELP") === nothing
    @test T.char_at(tb2, 5, 5) isa Char
end
