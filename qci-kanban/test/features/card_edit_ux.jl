# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — card edit UX polish:
#   • ↑/↓ field navigation (alongside Tab / Shift-Tab)
#   • Labels as toggling green bubbles (no checkmarks; no overlap)
#   • Start/Due date selector menu + manual YYYY-MM-DD entry
# Driven via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qe = QciKanban
_login_ce(name = "Edit UX") = (m = Qe.AppModel(; token_path = tempname(), secret = "s");
                               app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))
typ!(m, s) = (for ch in collect(s); u!(m, ch); end)

@testset "FEATURE: card edit field nav, label bubbles, date picker (BDD)" begin

    @testset "Given NEW CARD When user presses Down Then focus advances field-by-field" begin
        m = _login_ce("Nav")
        u!(m, 'n')
        @test m.modal == :card_edit
        @test Qe.focused_editor(m.focus) === m.edit_form.title_input
        u!(m, :down)
        @test Qe.focused_editor(m.focus) === m.edit_form.desc_area
        u!(m, :down)
        @test Qe.focused_editor(m.focus) === m.edit_form.priority_sel
        u!(m, :up)
        @test Qe.focused_editor(m.focus) === m.edit_form.desc_area
        # Tab still works
        u!(m, :tab)
        @test Qe.focused_editor(m.focus) === m.edit_form.priority_sel
    end

    @testset "Given labels on the form When a label is toggled Then green bubble shows without overlapping the name" begin
        m = _login_ce("Bubbles")
        u!(m, 'n'); typ!(m, "Labeled work")
        Qe.focus_index!(m.focus, 10)
        ms = m.edit_form.labels_ms
        @test !isempty(ms.options)
        u!(m, ' ')
        @test ms.checked[ms.cursor]
        tb = app_tb(m; w = 100, h = 32)
        blob = join(app_rows(m; w = 100, h = 32), "\n")
        @test occursin("●", blob) || occursin("•", blob)
        @test !occursin("☑", blob) && !occursin("☐", blob)
        nm = ms.options[ms.cursor]
        @test occursin("● " * nm, blob) || occursin("• " * nm, blob)
        lab = T.find_text(tb, "Labels")
        name_loc = T.find_text(tb, nm)
        @test lab !== nothing && name_loc !== nothing
        @test name_loc.x > lab.x + length("Labels:")
    end

    @testset "Given Start/Due fields When Space Then calendar menu; typing still works for manual entry" begin
        m = _login_ce("Dates")
        u!(m, 'n'); typ!(m, "Schedule WO")
        Qe.focus_index!(m.focus, 12)
        @test m.edit_form.start_input isa Qe.DateField
        u!(m, ' ')
        @test m.edit_form.start_input.menu_open
        blob = join(app_rows(m; w = 100, h = 32), "\n")
        @test occursin("Su", blob) || occursin("Mo", blob) || occursin(string(year(today())), blob)
        # commit a day from the menu
        u!(m, :right); u!(m, :enter)
        @test !m.edit_form.start_input.menu_open
        @test m.modal == :card_edit
        start_d = Qe.Stores.parse_date(Qe.text(m.edit_form.start_input))
        @test start_d isa Date
        # manual due date
        Qe.focus_index!(m.focus, 13)
        typ!(m, "2026-12-01")
        u!(m, (:ctrl, 's'))
        @test m.modal == :none
        found = filter(i -> i.title == "Schedule WO",
                       Qe.Stores.list_issues(m.boardstore; project_id = m.active_project_id))
        @test length(found) == 1
        @test found[1].due_date == Date(2026, 12, 1)
        @test found[1].start_date == start_d
    end

    @testset "Given open date menu When Esc Then menu closes and edit form remains" begin
        m = _login_ce("EscDate")
        u!(m, 'n'); typ!(m, "Keep form")
        Qe.focus_index!(m.focus, 12)
        u!(m, ' ')
        @test m.edit_form.start_input.menu_open
        u!(m, :escape)
        @test m.modal == :card_edit
        @test !m.edit_form.start_input.menu_open
    end

    @testset "Given Start date focused When menu closed Then [Spc] Calendar is on status bar not beside the date" begin
        m = _login_ce("DateTip")
        u!(m, 'n'); typ!(m, "Uncluttered dates")
        Qe.focus_index!(m.focus, 12)
        rows = app_rows(m; w = 100, h = 32)
        date_line = something(findfirst(r -> occursin("Start:", r) && occursin("Due:", r), rows), 0)
        @test date_line > 0
        @test !occursin("Spc", rows[date_line])
        # App status footer (Quit/Help), not the outer box border.
        si = something(findfirst(r -> occursin("[q]Quit", r) || occursin("Quit", r), rows), 0)
        @test si > 0
        status = rows[si]
        @test occursin("[Spc] Calendar", status)
        @test occursin("Save", status) || occursin("^S", status)
    end
end
