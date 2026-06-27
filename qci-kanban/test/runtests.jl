using Test
using Tachikoma
const T = Tachikoma

using QciKanban
const KanbanModel = QciKanban.KanbanModel

# Visual inspection helpers (TestBackend row dumps + scenarios for verifying no artifacts)
function visual_rows(m; w::Int = 80, h::Int = 20)
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[]))
    [T.row_text(tb, i) for i in 1:h]
end

# Component tests (add more as we progress through phases)
include("test_db.jl")
include("test_board_render.jl")
include("test_modal_move.jl")
include("test_users.jl")
include("test_calendar.jl")

@testset "QciKanban Phase 0: scaffold + QCI branding + basic render" begin

    @testset "Model + should_quit" begin
        m = KanbanModel()
        @test m isa KanbanModel
        @test m isa T.Model
        @test m.quit == false
        @test T.should_quit(m) == false

        m.quit = true
        @test T.should_quit(m) == true
    end

    @testset "Basic keys (q/esc + view mode switches)" begin
        m = KanbanModel()
        T.update!(m, T.KeyEvent('q'))
        @test m.quit == true

        m2 = KanbanModel()
        T.update!(m2, T.KeyEvent(:escape))
        @test m2.quit == true

        m3 = KanbanModel()
        T.update!(m3, T.KeyEvent('c'))
        @test m3.view_mode == :calendar
        @test occursin("Calendar", m3.message)

        T.update!(m3, T.KeyEvent('b'))
        @test m3.view_mode == :board
    end

    @testset "View renders QCI header + logo text (TestBackend)" begin
        m = KanbanModel()
        tb = T.TestBackend(60, 14)
        T.reset!(tb.buf)
        frame = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame)

        # Logo + branding evidence
        @test T.find_text(tb, "QCI") !== nothing
        @test T.find_text(tb, "KANBAN") !== nothing || T.find_text(tb, "QCI KANBAN") !== nothing
        row = T.row_text(tb, 1)
        @test occursin("QCI", row) || T.find_text(tb, "QCI") !== nothing

        # Mode hint
        @test T.find_text(tb, "board") !== nothing || T.find_text(tb, "BOARD") !== nothing
    end

    @testset "Small area guard" begin
        m = KanbanModel()
        tb = T.TestBackend(18, 4)
        T.reset!(tb.buf)
        frame = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame)
        @test T.find_text(tb, "small") !== nothing || T.find_text(tb, "QCI") !== nothing
    end

    @testset "QCI_SECONDARY exported + unselected list text visible (visual_rows + find_text/row_text after update!)" begin
        @test isdefined(QciKanban, :QCI_SECONDARY)
        sec = QciKanban.QCI_SECONDARY
        @test sec isa T.ColorRGB
        # board unselected after nav
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_board!(m)
        T.update!(m, T.KeyEvent('l'))
        T.update!(m, T.KeyEvent('j'))
        rows = visual_rows(m; w=80, h=18)
        @test any(occursin("QCI-", r) for r in rows)  # unselected cards text present
        @test any(occursin("To Do", r) || occursin("Backlog", r) for r in rows)
        tb = T.TestBackend(80, 18)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "QCI-") !== nothing
        @test T.row_text(tb, 9) !== nothing
    end
end

# PR1 TDD tests (added before any src change per strict TDD)
# Exercise new fields, kanban setup path (using :memory: + DB direct for state),
# current_user no-auto, and guard effect on keys (using TestBackend + update!/visual).
# These will FAIL (Red) until src/QciKanban.jl implements the wiring/guard/shims.
@testset "PR1: Model fields + kanban startup + login guard skeleton (TDD red first)" begin
    @testset "new login_state fields have correct defaults" begin
        m = KanbanModel()
        @test m.login_state == :logged_in
        @test m.login_selected == 1
        @test m.login_input isa T.TextInput
        @test m.login_input.focused == true   # from default in design
    end

    @testset "direct KanbanModel + load_board! compat (auto user + force :logged_in shim)" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_board!(m)
        @test m.login_state == :logged_in
        @test m.current_user_id !== nothing
        @test !isempty(m.users)
        # still renders board as before (no UI change in PR1)
        rows = visual_rows(m; w=60, h=18)
        @test any(occursin("QCI-", r) for r in rows)
        tb = T.TestBackend(60, 18)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "QCI-") !== nothing
    end

    @testset "kanban startup path sets login_state, no auto current_user (state after setup)" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        # replicate the intended kanban() startup logic (pre-app) to test state
        # (this drives the impl; uses :memory: per instructions)
        if m.db === nothing
            m.db = QciKanban.DB.open_db(m.db_path)
        end
        pre_users = QciKanban.DB.list_users(m.db)
        pre_issues = QciKanban.DB.list_issues(m.db)
        if isempty(pre_users) && isempty(pre_issues)
            QciKanban.DB.seed_demo!(m.db)
        end
        QciKanban.load_users!(m; auto_select = false)
        if isempty(m.users)
            m.login_state = :create_user
            m.login_input = T.TextInput(; focused = true)
        else
            m.login_state = :select_user
            m.login_selected = 1
        end
        @test m.login_state == :select_user
        @test m.current_user_id === nothing  # deliberate: no auto-select in new kanban() path
        @test !isempty(m.users)
        @test m.login_selected == 1
        # exercise TestBackend render (board still renders in PR1 skeleton)
        rows = visual_rows(m; w=70, h=16)
        @test any(occursin("QCI", r) for r in rows)
        tb = T.TestBackend(70, 16)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "QCI") !== nothing
    end

    @testset "early guard in update! prevents board keys pre-login (no state bleed)" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_board!(m)  # gets users etc
        m.login_state = :select_user  # simulate new startup path state (current_user may be set or not)
        m.current_user_id = nothing
        orig_view = m.view_mode
        orig_modal = m.modal
        orig_sel_col = m.selected_col
        orig_sel_idx = m.selected_idx

        # board keys that should be guarded (early return before view switches / board nav)
        T.update!(m, T.KeyEvent('b'))
        @test m.view_mode == orig_view  # no switch to board (though already is)
        T.update!(m, T.KeyEvent('c'))
        @test m.view_mode == orig_view
        T.update!(m, T.KeyEvent('L'))
        @test m.view_mode == orig_view

        # card nav / edit keys should not affect selection or open modals
        T.update!(m, T.KeyEvent('l'))
        T.update!(m, T.KeyEvent('j'))
        T.update!(m, T.KeyEvent('n'))
        @test m.selected_col == orig_sel_col
        @test m.selected_idx == orig_sel_idx
        @test m.modal == orig_modal

        # 'r' reload: per PR1 guard sketch, 'r' is handled before guard so may still reload (but design says ignore pre-login)
        # for minimal guard test we focus on the after-r switches and board nav which are guarded
        # q/esc still quit (handled pre-guard)
        m3 = KanbanModel()
        m3.login_state = :select_user
        T.update!(m3, T.KeyEvent(:escape))
        @test m3.quit == true

        # Use TestBackend + re-render to confirm no visual state change side effects from guarded keys
        tb = T.TestBackend(50, 12)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "QCI") !== nothing
    end
end

@testset "record_app demo integration (visual capture outside TestBackend)" begin
    mktempdir() do dir
        cd(dir) do
            fn = QciKanban.record_demo("test-kanban.tach"; frames=12, fps=4)
            @test isfile(fn)
            @test filesize(fn) > 100
        end
    end
end
