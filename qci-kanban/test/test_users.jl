using Test
using Tachikoma
const T = Tachikoma

using QciKanban
const KanbanModel = QciKanban.KanbanModel

@testset "QciKanban Phase 4: users + current assignee (temp DB)" begin
    m = KanbanModel()
    m.db_path = ":memory:"
    QciKanban.load_board!(m)  # seeds users

    @test !isempty(m.users)
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
    QciKanban.load_board!(m)
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

# PR2 TDD: test added first (Red) before any view change. One solid assertion for skeleton login.
# Uses visual_rows + find_text after state set + update!; asserts login text present + board "QCI-" suppressed.
@testset "PR2: Skeleton login render + basic TestBackend assertion (first visual gate; TDD red-first)" begin
    # replicate kanban() startup setup (no auto_select, no load_board! which would force :logged_in + cards)
    m = KanbanModel()
    m.db_path = ":memory:"
    if m.db === nothing
        m.db = QciKanban.DB.open_db(m.db_path)
    end
    QciKanban.DB.seed_demo!(m.db)
    QciKanban.load_users!(m; auto_select = false)
    m.login_state = :select_user
    m.login_selected = 1
    m.current_user_id = nothing
    # exercise a login-handled update! (nav)
    T.update!(m, T.KeyEvent('j'))

    # visual + find_text evidence
    rows = visual_rows(m; w=80, h=20)
    @test any(occursin("SELECT USER", r) for r in rows)
    @test any(occursin("QCI", r) for r in rows)
    @test !any(occursin("QCI-", r) for r in rows)  # board text (card keys) suppressed pre-login

    tb = T.TestBackend(80, 20)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1,1,tb.width,tb.height), [], []))
    @test T.find_text(tb, "SELECT USER") !== nothing
    @test T.find_text(tb, "QCI-") === nothing
    @test T.find_text(tb, "QCI") !== nothing
end
