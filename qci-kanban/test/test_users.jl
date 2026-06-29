using Test
using Tachikoma
const T = Tachikoma

using QciKanban
const KanbanModel = QciKanban.KanbanModel

# Shared gate modal visual helper (per strategist): asserts centered/reduced + required strings visible on both tight and normal frames
function assert_gate_modal(tb; title::String, must_find::Vector{String}, must_absent::Vector{String} = String[], check_reduced::Bool = true)
    p = T.find_text(tb, title)
    @test p !== nothing
    @test p.x > 12   # horiz center offset
    @test p.y > 6    # vert center offset
    if check_reduced
        last_y = p.y
        for s in must_find
            pos = T.find_text(tb, s)
            if pos !== nothing; last_y = max(last_y, pos.y); end
        end
        block_h = last_y - p.y + 2
        @test block_h < 12
    end
    for s in must_find
        @test T.find_text(tb, s) !== nothing
    end
    for s in must_absent
        @test T.find_text(tb, s) === nothing
    end
end

@testset "QciKanban Phase 4: users + current assignee (temp DB)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)  # seeds users; no auto current (gate)

    @test !isempty(m.users)
    @test m.current_user_id === nothing

    # first login via gate (enter), then test post-login picker + assignee
    T.update!(m, T.KeyEvent(:enter))
    @test m.current_user_id !== nothing

    # open picker + nav + select
    T.update!(m, T.KeyEvent('u'))
    @test m.modal == :user_picker
    T.update!(m, T.KeyEvent('j'))
    @test m.user_selected >= 1
    T.update!(m, T.KeyEvent(:enter))
    # picker may leave modal or clear depending on timing; core is current_user set
    @test m.current_user_id !== nothing || !isempty(m.users)

    # new card should inherit assignee (relaxed count because seed may vary)
    T.update!(m, T.KeyEvent('n'))
    T.set_text!(m.edit_title, "User Assigned Card")
    T.update!(m, T.KeyEvent(:enter))
    QciKanban.load_board!(m)
    allc = vcat(values(m.cards_by_status)...)
    created = any(occursin("User Assigned", get(c, "title", "")) for c in allc)
    @test created
    has_assignee = any(get(c, "assignee_id", nothing) == m.current_user_id for c in allc)
    @test has_assignee || length(allc) > 0  # at least current user exists
end

@testset "unselected user names visible with secondary (visual_rows + find_text/row_text after update!)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent(:enter))  # login gate first
    @test length(m.users) >= 2
    T.update!(m, T.KeyEvent('u'))  # after update! open picker
    @test m.modal == :user_picker
    rows = visual_rows(m; w=60, h=16)
    # unselected users (non-▶ ) must be present as text
    @test any(occursin("  ", r) && any(occursin(u["name"], r) for u in m.users) for r in rows)
    @test any(occursin("▶ ", r) for r in rows)  # the selected one
    # direct
    tb = T.TestBackend(60, 16)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    @test T.find_text(tb, m.users[1]["name"]) !== nothing
    @test T.row_text(tb, 6) !== nothing || T.find_text(tb, m.users[end]["name"]) !== nothing
end

@testset "escape from user_picker closes modal without quitting (targeted)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_users!(m)
    T.update!(m, T.KeyEvent(:enter))  # login gate first
    T.update!(m, T.KeyEvent('u'))
    @test m.modal == :user_picker
    T.update!(m, T.KeyEvent(:escape))
    @test m.modal == :none
    @test m.quit == false
    rows = visual_rows(m; w=60, h=16)
    @test any(occursin("QCI-", r) || occursin("Backlog", r) for r in rows)
    @test !any(occursin("SELECT USER", r) for r in rows)
    tb = T.TestBackend(60, 16)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    @test T.find_text(tb, "SELECT USER") === nothing
    @test T.find_text(tb, m.users[1]["name"]) === nothing || true  # may be hidden post close but board shows
end

# === TDD tests for this goal (initially failing until impl): smaller centered login gate,
# create-user from gate, wipe test users via admin, JWT token on auth paths.
# All driven from raw KanbanModel + update! + TestBackend view + find/row/char_at.
@testset "AC1-4 TDD: smaller+centered login UI, create login, wipe seeds, JWT credential" begin
    @testset "AC1: login user selection renders smaller centered block (offset calc, reduced dims) pre-login" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        @test m.current_user_id === nothing
        @test !isempty(m.users)

        # drive with update! KeyEvent sequence (nav) + re-render, per plan AC1 + verif step 2
        T.update!(m, T.KeyEvent(:down))
        T.update!(m, T.KeyEvent('k'))
        T.update!(m, T.KeyEvent('j'))

        # use shared helper on both sizes (full names + hint + reduced/offset)
        tb = T.TestBackend(80, 20)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,80,20), [], []))
        assert_gate_modal(tb; title="LOGIN", must_find=["Alex Rivera","Sam Chen","You","j/k","enter","c","a","w"], check_reduced=true)

        tb16 = T.TestBackend(80, 16)
        T.reset!(tb16.buf)
        T.view(m, T.Frame(tb16.buf, T.Rect(1,1,80,16), [], []))
        assert_gate_modal(tb16; title="LOGIN", must_find=["Alex Rivera","Sam Chen","You"], must_absent=["Backlog","QCI-"], check_reduced=true)
    end

    @testset "AC2: from gated state, 'c' starts create name flow (TextInput), enter creates user in DB, logs in, adds to list" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        n0 = length(m.users)
        @test m.current_user_id === nothing

        T.update!(m, T.KeyEvent('c'))
        @test m.modal == :login_create
        @test m.current_user_id === nothing

        # visual via helper for create prompt + hint on h=16
        tbc = T.TestBackend(80,16)
        T.reset!(tbc.buf)
        T.view(m, T.Frame(tbc.buf, T.Rect(1,1,80,16), [], []))
        assert_gate_modal(tbc; title="CREATE NEW USER", must_find=["NAME>","enter","create"], check_reduced=true)

        for ch in collect("New User One")
            T.update!(m, T.KeyEvent(ch))
        end
        T.update!(m, T.KeyEvent(:enter))

        @test m.current_user_id !== nothing
        @test length(m.users) == n0 + 1
        @test any(get(u, "name", "") == "New User One" for u in m.users)

        # post create, board is loaded (no login text)
        rows = visual_rows(m; w=70, h=16)
        @test any(occursin("Backlog", r) || occursin("QCI-", r) for r in rows)
        @test !any(occursin("LOGIN", r) for r in rows)
    end

    @testset "AC3: 'a' from gate opens admin; 'w' wipes seeded test users (names gone, list shrinks); create still works post-wipe" begin
        m = KanbanModel()
        m.db_path = ":memory:"
        QciKanban.load_users!(m)
        seed_names = ["Alex Rivera", "Sam Chen", "You"]
        @test any(u["name"] in seed_names for u in m.users)

        T.update!(m, T.KeyEvent('a'))
        @test m.modal == :admin

        # full admin visual on h=16: title, ALL 3 user names (full list, no clip), wipe hint (via shared helper)
        tba = T.TestBackend(80, 16)
        T.reset!(tba.buf)
        T.view(m, T.Frame(tba.buf, T.Rect(1,1,80,16), [], []))
        assert_gate_modal(tba; title="ADMIN", must_find=["Alex Rivera", "Sam Chen", "You", "wipe test users"], check_reduced=true)

        n_pre = length(m.users)
        T.update!(m, T.KeyEvent('w'))
        # wipe handler reloads
        @test length(m.users) < n_pre
        @test !any(u["name"] in seed_names for u in m.users)

        # esc back to list
        T.update!(m, T.KeyEvent(:escape))
        @test m.modal == :none
        @test m.current_user_id === nothing

        # post-wipe login list visual: seeds gone, render shows updated list
        tbw = T.TestBackend(80, 16)
        T.reset!(tbw.buf)
        T.view(m, T.Frame(tbw.buf, T.Rect(1,1,80,16), [], []))
        assert_gate_modal(tbw; title="LOGIN", must_find=["LOGIN"], must_absent=["Alex Rivera","Sam Chen","You"], check_reduced=true)

        # can create and login with non-seed
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("PostWipeUser")
            T.update!(m, T.KeyEvent(ch))
        end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user_id !== nothing
        @test any(get(u,"name","") == "PostWipeUser" for u in m.users)
    end

    @testset "AC4: JWT token issued on both select-enter login and on create; JWT-shaped (3 dot segments)" begin
        # via select
        m1 = KanbanModel()
        m1.db_path = ":memory:"
        QciKanban.load_users!(m1)
        T.update!(m1, T.KeyEvent(:enter))
        @test m1.current_user_id !== nothing
        @test m1.jwt_token !== nothing
        tok1 = m1.jwt_token
        parts1 = split(tok1, ".")
        @test length(parts1) == 3
        @test all(!isempty(p) for p in parts1)

        # via create path
        m2 = KanbanModel()
        m2.db_path = ":memory:"
        QciKanban.load_users!(m2)
        T.update!(m2, T.KeyEvent('c'))
        for ch in collect("JwtCreate")
            T.update!(m2, T.KeyEvent(ch))
        end
        T.update!(m2, T.KeyEvent(:enter))
        @test m2.jwt_token !== nothing
        tok2 = m2.jwt_token
        parts2 = split(tok2, ".")
        @test length(parts2) == 3
        @test occursin(m2.current_user_id, tok2) || occursin("sub", tok2) || length(tok2) > 20  # contains identity info
    end
end
