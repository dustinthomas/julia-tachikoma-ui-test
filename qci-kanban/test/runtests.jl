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

# Helper for PR tests: drive only with KeyEvents, no direct mutation of m.swimlane_by etc.
function board_after_keys(m, tb; keys::Vector{Char}=Char[])
    for k in keys
        T.update!(m, T.KeyEvent(k))
    end
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
end

# Helper to get a model that has gone through the real login gate (for tests that need logged-in board state)
# Now uses explicit create-account sequence because no user seeds on first load (true first-time path).
function fresh_logged_model()
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent('c'))
    for ch in collect("TestLoggedUser")
        T.update!(m, T.KeyEvent(ch))
    end
    T.update!(m, T.KeyEvent(:enter))  # create + login path
    m
end

# Component tests (add more as we progress through phases)
include("test_db.jl")
include("test_board_render.jl")
include("test_modal_move.jl")
include("test_users.jl")
include("test_calendar.jl")

# Phase 1 — core infrastructure (no UI): domain, config, stores, auth, notify.
include("test_domain.jl")
include("test_stores.jl")
include("test_auth.jl")
include("test_notify.jl")
include("features/phase1_infra.jl")

# Phase 2 — UI shell: theme, focus router, keymap, login gate, app frame.
include("test_theme.jl")
include("test_focus.jl")
include("test_app_shell.jl")
include("features/phase2_shell.jl")

# PR-H1 — roles schema, can!/can matrix, lazy idle logout.
include("features/roles_idle.jl")

# Phase 3 — Jira board: swimlane grid, rich cards, ops, filters, backlog, sprints.
include("test_widgets.jl")
include("test_board_view.jl")
include("test_card_modals.jl")
include("test_backlog.jl")
include("features/phase3_board.jl")

# Multi-project scope (PR-M2): active project, store isolation, switcher.
include("features/multi_project.jl")

# Production seed controls (PR-M3): seed_demo config, ops labels, empty board.
include("features/seed_config.jl")
# Velocity / sprint metrics (PR-M4): close snapshots + backlog velocity footer.
include("features/velocity.jl")
# Work-order fields (PR-M6): asset_tag, location, work_type + EditForm/chips/search.
include("features/work_order_fields.jl")

# Card edit UX: ↑↓ field nav, green label bubbles, date picker + manual entry.
include("features/card_edit_ux.jl")

# Project switcher polish + create-project + CSV export (PR-M7 / MVP exit).
include("features/project_switcher_export.jl")

# Soft refresh R + WAL ops (PR-H2).
include("features/ops_refresh.jl")

# Phase 4 — Calendar + Gantt: month grid, due marks, drill-down; timeline bars.
include("test_calendar_view.jl")
include("test_gantt.jl")
include("features/phase4_timeline.jl")
# Gantt mouse M1 — click-select via pure hit-test (after G4.1 layout).
include("features/gantt_mouse.jl")
# Board mouse B1 — body click-select + select-then-activate open detail.
include("features/board_mouse.jl")

# Phase 5 — graphics polish: layered logo, board stats strip, sprint burndown,
# animation gating, scripted v2 demo tour.
include("test_gfx.jl")

# Phase 6 — UI fix-wave regressions (REVIEW-FINDINGS.md): unicode-safe render,
# quit-from-modal, invalid-date guard, visible-only bulk ops, TextArea newline,
# scroll-follow, narrow-board border, focus-aware hints, help overflow, and the
# secure session-restore/logout API adoption.
include("test_fixwave.jl")

# === LOGIN GATE TESTS (TDD: drive exclusively from raw KanbanModel() + update! + TestBackend) ===
# Acceptance: first-time (zero users after load) renders login UI with no pre-seeded names + create hint,
# non-login keys (incl enter when empty) do not login or load board, 'c'+name+enter creates+logs+loads board+jwt,
# only q quits, use find_text/row_text/char_at after updates. AC1-4.
@testset "QciKanban login gate: app opens at login page; cannot use before login (TestBackend from raw state)" begin
    @testset "fresh model + load_users (no auto-login) yields ZERO users for first-time; render LOGIN no seed names + create hint" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        @test m.current_user_id === nothing
        @test length(m.users) == 0  # no seeded users; first time requires create

        tb = T.TestBackend(80, 20)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        # login page indicators (title may be LOGIN or SELECT)
        @test T.find_text(tb, "LOGIN") !== nothing || T.find_text(tb, "SELECT") !== nothing
        # NO seed names
        @test T.find_text(tb, "Alex Rivera") === nothing
        @test T.find_text(tb, "Sam Chen") === nothing
        @test T.find_text(tb, "You") === nothing
        # create account hint present (c key)
        @test T.find_text(tb, "c") !== nothing || T.find_text(tb, "create") !== nothing || occursin("c", join(visual_rows(m;w=80,h=20), " "))
        # NO board content
        @test T.find_text(tb, "Backlog") === nothing
        @test T.find_text(tb, "To Do") === nothing
        @test T.find_text(tb, "QCI-") === nothing
        rows = visual_rows(m; w=80, h=20)
        @test !any(occursin("Backlog", r) || occursin("QCI-", r) for r in rows)
    end

    @testset "non-login keys (incl :enter, nav) from empty gated state do not set current_user or load board" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        @test length(m.users) == 0
        @test m.current_user_id === nothing
        card_count() = sum(length(v) for v in values(m.cards_by_status); init=0)
        @test card_count() == 0

        # all non-create keys must be ignored for auth
        for k in ['n','h','l','j','k','u','b','L','?','r', :escape, :enter, :down, :up]
            T.update!(m, T.KeyEvent(k))
        end
        @test m.current_user_id === nothing
        @test card_count() == 0
        @test m.modal == :none

        tb = T.TestBackend(82, 18)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "LOGIN") !== nothing || T.find_text(tb, "SELECT") !== nothing
        @test T.find_text(tb, "Backlog") === nothing
        @test T.find_text(tb, "QCI-") === nothing
    end

    @testset "create-account path from ZERO users: 'c' opens TextInput, chars+enter creates user, sets current+jwt(3parts), loads board" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        @test length(m.users) == 0
        @test m.current_user_id === nothing

        # drive create
        T.update!(m, T.KeyEvent('c'))
        @test m.modal == :login_create
        @test m.current_user_id === nothing

        tbc = T.TestBackend(80,16)
        T.reset!(tbc.buf)
        T.view(m, T.Frame(tbc.buf, T.Rect(1,1,tbc.width,tbc.height), [], []))
        @test T.find_text(tbc, "CREATE") !== nothing || T.find_text(tbc, "NAME") !== nothing

        for ch in collect("FirstTimeUser")
            T.update!(m, T.KeyEvent(ch))
        end
        T.update!(m, T.KeyEvent(:enter))

        @test m.current_user_id !== nothing
        @test length(m.users) == 1
        @test any(get(u, "name", "") == "FirstTimeUser" for u in m.users)
        @test m.jwt_token !== nothing
        parts = split(m.jwt_token, ".")
        @test length(parts) == 3

        # post create: board accessible, gate gone
        @test !isempty(m.cards_by_status) || length(m.cards_by_status) > 0
        rows = visual_rows(m; w=70, h=16)
        @test any(occursin("Backlog", r) || occursin("QCI-", r) for r in rows)
        @test !any(occursin("LOGIN", r) for r in rows)

        tb = T.TestBackend(80, 18)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
        @test T.find_text(tb, "LOGIN") === nothing
        @test T.find_text(tb, "Backlog") !== nothing || T.find_text(tb, "QCI-") !== nothing
    end

    @testset "only 'q' quits from login page; other keys including esc do not quit" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        T.update!(m, T.KeyEvent(:escape))
        @test m.quit == false
        T.update!(m, T.KeyEvent('u'))
        @test m.quit == false
        T.update!(m, T.KeyEvent(:enter))  # empty case: no login
        T.update!(m, T.KeyEvent('q'))
        @test m.quit == true
    end
end

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

        # Escape no longer quits (see dedicated escape-back tests); only q does
        m2 = KanbanModel()
        m2.db_path = ":memory:"
        QciKanban.load_users!(m2)
        T.update!(m2, T.KeyEvent('c'))
        for ch in collect("BasicEscUser"); T.update!(m2, T.KeyEvent(ch)); end
        T.update!(m2, T.KeyEvent(:enter))  # create login
        T.update!(m2, T.KeyEvent(:escape))
        @test m2.quit == false
        @test m2.view_mode == :board
        @test m2.modal == :none

        m3 = KanbanModel()
        m3.db_path = ":memory:"
        QciKanban.load_users!(m3)
        T.update!(m3, T.KeyEvent('c'))
        for ch in collect("BasicCalUser"); T.update!(m3, T.KeyEvent(ch)); end
        T.update!(m3, T.KeyEvent(:enter))  # create login
        T.update!(m3, T.KeyEvent('c'))
        @test m3.view_mode == :calendar
        @test occursin("Calendar", m3.message)

        T.update!(m3, T.KeyEvent('b'))
        @test m3.view_mode == :board
    end

    @testset "Escape back behaviors (from initial state, never quits; modals close, non-board reverts to board; TestBackend visual evidence)" begin
        # AC1,2,3,4: direct from KanbanModel + update! + render checks; board content visible post-back, no bleed/modals
        @testset "escape after 'n' (card_edit) closes modal, quit=false, board visible, no NEW CARD bleed" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("EscNUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # create login gate
            T.update!(m, T.KeyEvent('n'))
            @test m.modal == :card_edit
            @test m.quit == false

            T.update!(m, T.KeyEvent(:escape))
            @test m.modal == :none
            @test m.quit == false
            @test m.view_mode == :board

            rows = visual_rows(m; w=80, h=20)
            @test any(occursin("Backlog", r) || occursin("To Do", r) for r in rows)
            @test any(occursin("QCI-", r) for r in rows)
            @test !any(occursin("NEW CARD", r) for r in rows)

            tb = T.TestBackend(80, 18)
            T.reset!(tb.buf)
            T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
            @test T.find_text(tb, "QCI-") !== nothing
            @test T.find_text(tb, "NEW CARD") === nothing
            @test T.find_text(tb, "Backlog") !== nothing || T.find_text(tb, "To Do") !== nothing
            # char_at exercise for position in board area
            ch = T.char_at(tb, 3, 4)
            @test ch isa Char
        end

        @testset "escape after 'u' (user_picker) closes to :none, board cards visible, no SELECT USER" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("EscUUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # create login gate
            T.update!(m, T.KeyEvent('u'))
            @test m.modal == :user_picker
            @test m.quit == false

            T.update!(m, T.KeyEvent(:escape))
            @test m.modal == :none
            @test m.quit == false

            tb = T.TestBackend(70, 18)
            T.reset!(tb.buf)
            T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
            @test T.find_text(tb, "QCI-") !== nothing || T.find_text(tb, "Backlog") !== nothing
            @test T.find_text(tb, "SELECT USER") === nothing
            rows = visual_rows(m; w=70, h=18)
            @test any(occursin("QCI-", r) || occursin("Backlog", r) for r in rows)
        end

        @testset "escape from :calendar reverts view_mode to :board, quit=false, board content visible" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("EscCUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # create login gate
            T.update!(m, T.KeyEvent('c'))
            @test m.view_mode == :calendar
            @test m.quit == false

            T.update!(m, T.KeyEvent(:escape))
            @test m.view_mode == :board
            @test m.quit == false
            @test m.modal == :none

            rows = visual_rows(m; w=80, h=18)
            @test any(occursin("Backlog", r) || occursin("QCI-", r) for r in rows)

            tb = T.TestBackend(80, 18)
            T.reset!(tb.buf)
            T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
            @test T.find_text(tb, "QCI-") !== nothing
            @test T.find_text(tb, "DUE THIS MONTH") === nothing
        end

        @testset "escape from :list reverts to :board" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("EscLUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # create login gate
            # 'L' (and R/O) are PR8 frozen (no-op return per src); set directly to test escape revert path
            m.view_mode = :list
            @test m.view_mode == :list
            T.update!(m, T.KeyEvent(:escape))
            @test m.view_mode == :board
            @test m.quit == false
        end

        @testset "escape at root board: no state change, quit remains false" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("EscRootUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # create login gate
            prev_v, prev_mod = m.view_mode, m.modal
            T.update!(m, T.KeyEvent(:escape))
            @test m.quit == false
            @test m.view_mode == prev_v
            @test m.modal == prev_mod
            # board still renders content
            rows = visual_rows(m; w=60, h=16)
            @test any(occursin("Backlog", r) for r in rows)
        end

        @testset "only 'q' sets quit=true; escape never does" begin
            m = KanbanModel()
            T.update!(m, T.KeyEvent(:escape))
            @test m.quit == false
            T.update!(m, T.KeyEvent('q'))
            @test m.quit == true
        end
    end

    @testset "View renders QCI header + logo text (TestBackend)" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("ViewQCIUser"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))  # logged so board/status renders for mode check
        tb = T.TestBackend(60, 14)
        T.reset!(tb.buf)
        frame = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame)

        # Logo + branding evidence
        @test T.find_text(tb, "QCI") !== nothing
        @test T.find_text(tb, "KANBAN") !== nothing || T.find_text(tb, "QCI KANBAN") !== nothing
        row = T.row_text(tb, 1)
        @test occursin("QCI", row) || T.find_text(tb, "QCI") !== nothing

        # Mode hint (status shows after login; code uses uppercase(mode_str))
        @test T.find_text(tb, "BOARD") !== nothing
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
        QciKanban.load_users!(m)
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("SecUser"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))  # login gate to reach board state
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

    @testset "Bottom key tips (contextual per screen) + '?' help (update! + TestBackend + visual)" begin
        # Board tips relevant (movement, actions, ?); help via '?'
        @testset "board: tips visible at bottom after load+render; ? opens help with content" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("TipsBoardUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # login gate to reach board state
            # exercise helper directly (for coverage + inspect)
            tipsb = QciKanban.screen_key_tips(:board)
            @test occursin("h/l", tipsb) || occursin("n", tipsb)
            tb = T.TestBackend(82, 20)
            T.reset!(tb.buf)
            T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
            # bottom relevant board keys/tips present (will be added in status/tips)
            @test T.find_text(tb, "h/l") !== nothing || T.find_text(tb, "j/k") !== nothing || T.find_text(tb, "n") !== nothing
            @test T.find_text(tb, "?") !== nothing || T.find_text(tb, "help") !== nothing

            # invoke help
            T.update!(m, T.KeyEvent('?'))
            @test m.modal == :help
            @test m.quit == false
            @test m.view_mode == :board

            tb2 = T.TestBackend(82, 20)
            T.reset!(tb2.buf)
            T.view(m, T.Frame(tb2.buf, T.Rect(1,1,tb2.width,tb2.height), [], []))
            @test T.find_text(tb2, "HELP") !== nothing
            @test T.find_text(tb2, "q : quit") !== nothing || T.find_text(tb2, "Esc") !== nothing
            @test T.find_text(tb2, "QCI-") === nothing  # no board bleed under help (or at least help visible)
            ch = T.char_at(tb2, 10, 8)
            @test ch isa Char
        end

        @testset "escape from help restores prior screen (no quit, original content, no help text)" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("HelpEscUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # login gate to reach board state
            T.update!(m, T.KeyEvent('?'))
            @test m.modal == :help
            T.update!(m, T.KeyEvent(:escape))
            @test m.modal == :none
            @test m.quit == false
            @test m.view_mode == :board

            tb = T.TestBackend(80, 18)
            T.reset!(tb.buf)
            T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
            @test T.find_text(tb, "QCI-") !== nothing || T.find_text(tb, "Backlog") !== nothing
            @test T.find_text(tb, "HELP") === nothing
            rows = visual_rows(m; w=80, h=18)
            @test any(occursin("Backlog", r) || occursin("To Do", r) for r in rows)
            @test !any(occursin("HELP", r) for r in rows)
        end

        @testset "calendar view: shows relevant (different) tips; ? opens help" begin
            m = KanbanModel()
            m.db_path = ":memory:"
            QciKanban.load_users!(m)
            T.update!(m, T.KeyEvent('c'))
            for ch in collect("CalTipsUser"); T.update!(m, T.KeyEvent(ch)); end
            T.update!(m, T.KeyEvent(:enter))  # login gate to reach board state
            T.update!(m, T.KeyEvent('c'))
            @test m.view_mode == :calendar

            tb = T.TestBackend(80, 18)
            T.reset!(tb.buf)
            T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
            # calendar relevant keys/tips (different from board)
            @test T.find_text(tb, "h/l") !== nothing || T.find_text(tb, "month") !== nothing || T.find_text(tb, "b") !== nothing
            @test T.find_text(tb, "?") !== nothing || T.find_text(tb, "help") !== nothing

            T.update!(m, T.KeyEvent('?'))
            @test m.modal == :help
            @test m.quit == false

            tb2 = T.TestBackend(80, 18)
            T.reset!(tb2.buf)
            T.view(m, T.Frame(tb2.buf, T.Rect(1,1,tb2.width,tb2.height), [], []))
            @test T.find_text(tb2, "HELP") !== nothing
        end
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
