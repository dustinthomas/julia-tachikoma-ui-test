# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — work-order fields (PR-M6 / design §4.4):
# asset_tag, location, work_type on issues; EditForm order; card chips;
# detail ASSET/LOCATION/TYPE block; search includes asset_tag.
# Driven via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qm = QciKanban
_login_wo(name = "Maint Sup") = (m = Qm.AppModel(; token_path = tempname(), secret = "s");
                                 app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))
typ!(m, s) = (for ch in collect(s); u!(m, ch); end)

@testset "FEATURE: work-order fields (PR-M6 BDD)" begin

    @testset "Given create form When WO fields set Then issue persists asset/location/type" begin
        m = _login_wo("Create WO")
        u!(m, 'n')
        @test m.modal == :card_edit
        tb = app_tb(m; w = 100, h = 32)
        @test T.find_text(tb, "NEW CARD") !== nothing
        @test T.find_text(tb, "Type:") !== nothing || T.find_text(tb, "Asset:") !== nothing
        typ!(m, "Lube spindle bearings")
        # Tab: title → desc → priority → hours → work_type
        u!(m, :tab); u!(m, :tab); u!(m, :tab); u!(m, :tab)
        # work_type selector: default (none); right → PM
        u!(m, :right)
        @test Qm.sel_current_value(m.edit_form.work_type_sel) == "PM"
        u!(m, :tab)   # → asset_tag
        typ!(m, "CNC-42")
        u!(m, :tab)   # → location
        typ!(m, "Cell 3")
        u!(m, (:ctrl, 's'))
        @test m.modal == :none
        found = filter(i -> i.title == "Lube spindle bearings",
                       Qm.Stores.list_issues(m.boardstore; project_id = m.active_project_id))
        @test length(found) == 1
        @test found[1].asset_tag == "CNC-42"
        @test found[1].location == "Cell 3"
        @test found[1].work_type == "PM"
    end

    @testset "Given WO with asset When board renders Then asset and work_type chips show" begin
        m = _login_wo("Chips")
        iss = Qm.Stores.create_issue!(m.boardstore; title = "ZzChipWO",
                                      asset_tag = "PMP-9", work_type = "CM",
                                      status = "Backlog", project_id = m.active_project_id)
        # isolate via search so the card is visible
        u!(m, '/'); typ!(m, "ZzChipWO"); u!(m, :enter)
        tb = app_tb(m; w = 120, h = 30)
        @test T.find_text(tb, "ZzChipWO") !== nothing || T.find_text(tb, iss.key) !== nothing
        # work_type chip uses ⟨CM⟩; asset chip uses ⚙PMP-9 (shortened)
        rows = app_rows(m; w = 120, h = 30)
        joined = join(rows, "\n")
        @test occursin("CM", joined) || occursin("⟨CM⟩", joined)
        @test occursin("PMP", joined) || occursin("PMP-9", joined)
    end

    @testset "Given WO When detail opens Then ASSET/LOCATION/TYPE/EST HRS block shows" begin
        m = _login_wo("Detail")
        iss = Qm.Stores.create_issue!(m.boardstore; title = "ZzDetailWO",
                                      asset_tag = "LATHE-1", location = "Bay 1",
                                      work_type = "Safety", story_points = 2,
                                      status = "Backlog", project_id = m.active_project_id)
        u!(m, '/'); typ!(m, "ZzDetailWO"); u!(m, :enter)
        u!(m, 'v')
        @test m.modal == :card_detail
        tb = app_tb(m; w = 100, h = 30)
        @test T.find_text(tb, "ASSET:") !== nothing
        @test T.find_text(tb, "LATHE-1") !== nothing
        @test T.find_text(tb, "LOCATION:") !== nothing || T.find_text(tb, "Bay 1") !== nothing
        @test T.find_text(tb, "TYPE:") !== nothing || T.find_text(tb, "Safety") !== nothing
        @test T.find_text(tb, "EST HRS:") !== nothing || T.find_text(tb, "2") !== nothing
        u!(m, :escape)
    end

    @testset "Given search by asset_tag When applied Then matching WO is visible" begin
        m = _login_wo("Search Asset")
        Qm.Stores.create_issue!(m.boardstore; title = "Unrelated Pump Job",
                                asset_tag = "HYD-77", work_type = "CM",
                                status = "Backlog", project_id = m.active_project_id)
        Qm.Stores.create_issue!(m.boardstore; title = "Other Task No Tag",
                                status = "Backlog", project_id = m.active_project_id)
        u!(m, '/'); typ!(m, "HYD-77"); u!(m, :enter)
        @test m.modal == :none
        grid = Qm.board_grid(m)
        titles = String[iss.title for lane in grid for col in lane.cols for iss in col]
        @test "Unrelated Pump Job" in titles
        @test !("Other Task No Tag" in titles)
        # Esc clears query (see _clear_search!); re-open for a title-only search
        u!(m, '/'); u!(m, :escape)
        u!(m, '/'); typ!(m, "Other Task"); u!(m, :enter)
        grid2 = Qm.board_grid(m)
        titles2 = String[iss.title for lane in grid2 for col in lane.cols for iss in col]
        @test "Other Task No Tag" in titles2
    end

    @testset "Given edit of existing WO When fields change Then update persists" begin
        m = _login_wo("Edit WO")
        iss = Qm.Stores.create_issue!(m.boardstore; title = "ZzEditWO",
                                      asset_tag = "OLD-1", work_type = "PM",
                                      status = "Backlog", project_id = m.active_project_id)
        u!(m, '/'); typ!(m, "ZzEditWO"); u!(m, :enter)
        u!(m, 'e')
        @test m.modal == :card_edit
        @test Qm.text(m.edit_form.asset_input) == "OLD-1"
        @test Qm.sel_current_value(m.edit_form.work_type_sel) == "PM"
        # focus asset field (index 6), replace tag
        Qm.focus_index!(m.focus, 6)
        # clear and type new tag (select-all not available; overwrite by clearing widget)
        T.set_text!(m.edit_form.asset_input, "NEW-99")
        Qm.focus_index!(m.focus, 5)   # work_type
        u!(m, :right)                 # PM → CM
        u!(m, (:ctrl, 's'))
        got = Qm.Stores.get_issue(m.boardstore, iss.id)
        @test got.asset_tag == "NEW-99"
        @test got.work_type == "CM"
    end
end
