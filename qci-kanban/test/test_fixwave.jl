# ═══════════════════════════════════════════════════════════════════════
# test_fixwave.jl — Phase 6 UI fix-wave regressions (REVIEW-FINDINGS.md).
# Every fix is proven headlessly via update!(m, KeyEvent) + TestBackend, with
# a re-render after each key, and presence AND absence assertions at multiple
# sizes. Reuses helpers from test_app_shell.jl (fresh_app / app_login_new /
# app_tb / app_rows). Depends on `using QciKanban`, `const T = Tachikoma`.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qf = QciKanban
fw_key!(m, x) = T.update!(m, T.KeyEvent(x))
fw_key!(m, a, b) = T.update!(m, T.KeyEvent(a, b))
fw_type!(m, s) = (for ch in collect(s); T.update!(m, T.KeyEvent(ch)); end)
fw_login(; name = "Fix Wave", email = "fw@qci.com") =
    (m = Qf.AppModel(; token_path = tempname(), secret = "s"); app_login_new(m; name = name, email = email); m)

@testset "Fix-wave: prior-wave API adoption in app.jl (S1/S2)" begin
    @testset "S1 — a deactivated user with a valid token file is sent to login on startup" begin
        udb = tempname(); tok = tempname()
        us = Qf.Stores.SQLiteUserStore(udb)
        Qf.Stores.create_user!(us; email = "d@qci.com", name = "Deact", password = "pw12")
        m = Qf.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        fw_type!(m, "d@qci.com"); fw_key!(m, :tab); fw_type!(m, "pw12"); fw_key!(m, :enter)
        @test m.current_user !== nothing
        @test isfile(tok)
        uid = m.current_user.id
        # deactivate in the shared store (bumps active=0 + token_version)
        @test Qf.Stores.deactivate_user!(us, uid)
        # restart: the token file is still valid-signed, but the DB re-check rejects it
        m2 = Qf.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        @test m2.current_user === nothing
        tb = app_tb(m2; w = 80, h = 20)
        @test T.find_text(tb, "SIGN IN") !== nothing
        @test T.find_text(tb, "BOARD") === nothing
    end

    @testset "S2 — after logout the old token no longer restores (token_version bump)" begin
        udb = tempname(); tok = tempname()
        m = Qf.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        app_login_new(m; email = "rev@qci.com", name = "Rev")
        old_token = m.session.token
        @test old_token !== nothing
        fw_key!(m, :ctrl, 'l')                      # logout: revoke + delete file
        @test m.current_user === nothing
        @test !isfile(tok)
        # resurrect the exact old token on disk and try to restore it
        Qf.Auth.save_token(tok, old_token)
        m2 = Qf.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        @test m2.current_user === nothing           # revoked — tv mismatch
    end

    @testset "account-creation session (tv=0) still restores normally" begin
        udb = tempname(); tok = tempname()
        m = Qf.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        app_login_new(m; email = "new@qci.com", name = "New")
        m2 = Qf.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        @test m2.current_user !== nothing
        @test m2.current_user.name == "New"
    end
end

@testset "Fix-wave: C1/U1 unicode board render never crashes" begin
    m = fw_login()
    Qf.Stores.create_issue!(m.boardstore; title = "🎯 Ship — 日本語 release ✨", status = "Backlog")
    Qf.Stores.create_issue!(m.boardstore; title = "Fix café crash — naïve —— edge", status = "To Do")
    @testset "renders at many sizes (tight widths stress mid-glyph truncation)" begin
        for h in (16, 24, 30), w in 24:2:110
            tb = app_tb(m; w = w, h = h)            # must not throw a StringIndexError
            @test T.find_text(tb, "BOARD") !== nothing
        end
    end
    @testset "emoji search query does not crash the filter/render" begin
        fw_key!(m, '/'); fw_type!(m, "🎯"); fw_key!(m, :enter)
        tb = app_tb(m; w = 90, h = 22)
        @test T.find_text(tb, "BOARD") !== nothing
        fw_key!(m, '/'); fw_key!(m, :escape)        # clear search
    end
    @testset "a non-ASCII user name renders in the status bar without crashing" begin
        m2 = fresh_app(); app_login_new(m2; name = "José 日本 🎯", email = "jose@qci.com")
        @test m2.current_user.name == "José 日本 🎯"
        for (w, h) in [(80, 20), (40, 12), (100, 28)]
            tb = app_tb(m2; w = w, h = h)
            @test T.find_text(tb, "BOARD") !== nothing
        end
    end
    @testset "emoji card detail + edit modals render safely" begin
        m3 = fw_login()
        Qf.Stores.create_issue!(m3.boardstore; title = "ZzEmoji 🚀 — 日本 test", status = "Backlog")
        fw_key!(m3, '/'); fw_type!(m3, "ZzEmoji"); fw_key!(m3, :enter)
        fw_key!(m3, 'v')                            # detail
        tb = app_tb(m3; w = 90, h = 24)
        @test T.find_text(tb, "COMMENTS") !== nothing
        fw_key!(m3, :escape); fw_key!(m3, 'e')      # edit
        tb2 = app_tb(m3; w = 70, h = 24)
        @test T.find_text(tb2, "EDIT CARD") !== nothing
    end
end

@testset "Fix-wave: U2 quit reaches dispatch from every modal" begin
    for opener in ['v', 'n', 'd', '/']              # card_detail, card_edit, confirm, search
        m = fw_login()
        fw_key!(m, opener)
        @test m.modal !== :none
        fw_key!(m, :ctrl_c)
        @test m.quit == true
    end
    @testset "help modal too" begin
        m = fw_login(); fw_key!(m, '?')
        @test m.modal == :help
        fw_key!(m, :ctrl_c)
        @test m.quit == true
    end
    @testset "new-sprint modal" begin
        m = fw_login(); fw_key!(m, 'C'); fw_key!(m, 'K'); fw_key!(m, 'n')
        @test m.modal == :new_sprint
        fw_key!(m, :ctrl_c)
        @test m.quit == true
    end
end

@testset "Fix-wave: C6 invalid date must not erase the stored date" begin
    m = fw_login()
    Qf.Stores.create_issue!(m.boardstore; title = "ZzDueCard", due_date = Date(2026, 3, 3),
                            start_date = Date(2026, 3, 1), status = "Backlog")
    fw_key!(m, '/'); fw_type!(m, "ZzDueCard"); fw_key!(m, :enter)   # isolate + select it
    iss0 = Qf.selected_issue(m)
    @test iss0.title == "ZzDueCard"
    @test iss0.due_date == Date(2026, 3, 3)

    # Current UX (modals.jl): malformed dates open a :bad_date confirm dialog
    # ("Invalid <field> date format… Save anyway?") instead of staying on
    # card_edit with m.message. DB is untouched until the user confirms (yes
    # clears the bad field then saves) or declines (no closes without write).

    @testset "malformed due date → confirm warning, DB date untouched on decline" begin
        fw_key!(m, 'e')
        @test Qf.text(m.edit_form.due_input) == "2026-03-03"
        Qf.focus_index!(m.focus, 9)                 # due field
        fw_type!(m, "x")                            # "2026-03-03x" — unparseable
        fw_key!(m, :ctrl, 's')                      # attempt save
        @test m.modal == :confirm
        @test m.confirm_kind === :bad_date
        @test m.confirm_target == "due"
        tb = app_tb(m; w = 80, h = 20)
        @test T.find_text(tb, "Invalid due date") !== nothing
        @test Qf.Stores.get_issue(m.boardstore, iss0.id).due_date == Date(2026, 3, 3)
        fw_key!(m, 'n')                             # decline — no write
        @test Qf.Stores.get_issue(m.boardstore, iss0.id).due_date == Date(2026, 3, 3)
    end
    @testset "malformed start date reports the start field" begin
        fw_key!(m, 'e')
        T.set_text!(m.edit_form.due_input, "2026-03-03")   # fix due
        T.set_text!(m.edit_form.start_input, "not-a-date")
        fw_key!(m, :ctrl, 's')
        @test m.modal == :confirm
        @test m.confirm_kind === :bad_date
        @test m.confirm_target == "start"
        tb = app_tb(m; w = 80, h = 20)
        @test T.find_text(tb, "Invalid start date") !== nothing
        @test Qf.Stores.get_issue(m.boardstore, iss0.id).start_date == Date(2026, 3, 1)
        fw_key!(m, 'n')
        @test Qf.Stores.get_issue(m.boardstore, iss0.id).start_date == Date(2026, 3, 1)
    end
    @testset "empty date field clears the stored date" begin
        fw_key!(m, 'e')
        T.set_text!(m.edit_form.start_input, "2026-03-01")
        T.set_text!(m.edit_form.due_input, "")             # intentional clear
        fw_key!(m, :ctrl, 's')
        @test m.modal == :none
        @test Qf.Stores.get_issue(m.boardstore, iss0.id).due_date === nothing
    end
end

@testset "Fix-wave: C7 bulk ops act only on visible selections" begin
    @testset "bulk delete of hidden selection is refused (no data loss)" begin
        m = fw_login()
        fw_key!(m, ' '); fw_key!(m, 'j'); fw_key!(m, ' ')       # select 2 Backlog cards
        ids = collect(m.selected_ids)
        @test length(ids) == 2
        fw_key!(m, '/'); fw_type!(m, "zzz_no_match_xyzzy"); fw_key!(m, :enter)  # hide everything
        fw_key!(m, 'D')
        @test m.modal == :none
        @test occursin("No visible", m.message)
        for id in ids
            @test Qf.Stores.get_issue(m.boardstore, id) !== nothing            # still alive
        end
    end
    @testset "bulk move skips hidden selections and counts zero" begin
        m = fw_login()
        fw_key!(m, ' '); fw_key!(m, 'j'); fw_key!(m, ' ')
        ids = collect(m.selected_ids)
        s0 = Dict(id => Qf.Stores.get_issue(m.boardstore, id).status for id in ids)
        fw_key!(m, '/'); fw_type!(m, "zzz_no_match_xyzzy"); fw_key!(m, :enter)
        fw_key!(m, 'l')                                        # cursor → next column (target)
        fw_key!(m, 'M')
        @test occursin("Moved 0", m.message)
        for id in ids
            @test Qf.Stores.get_issue(m.boardstore, id).status == s0[id]
        end
    end
    @testset "bulk delete counts only issues actually removed" begin
        m = fw_login()
        fw_key!(m, ' '); fw_key!(m, 'j'); fw_key!(m, ' ')
        ids = collect(m.selected_ids)
        fw_key!(m, 'D')                                        # confirm modal, 2 targets
        @test m.modal == :confirm
        Qf.Stores.delete_issue!(m.boardstore, ids[1])         # vanish one before confirm
        fw_key!(m, 'y')
        @test occursin("Deleted 1", m.message)                # not "Deleted 2"
    end
    @testset "bulk assign skips hidden selections" begin
        m = fw_login()
        fw_key!(m, ' '); fw_key!(m, 'j'); fw_key!(m, ' ')
        ids = collect(m.selected_ids)
        fw_key!(m, '/'); fw_type!(m, "zzz_no_match_xyzzy"); fw_key!(m, :enter)
        fw_key!(m, 'A')
        @test occursin("Assigned 0", m.message)
        for id in ids
            @test Qf.Stores.get_issue(m.boardstore, id).assignee_id === nothing
        end
    end
end

@testset "Fix-wave: U6 Enter = newline in the Desc TextArea; Ctrl+S saves" begin
    @testset "Enter inserts a newline in Desc; only Ctrl+S saves the multi-line body" begin
        m = fw_login()
        fw_key!(m, 'n'); fw_type!(m, "Multiline")               # title focused
        Qf.focus_index!(m.focus, 2)                             # → Desc TextArea
        fw_type!(m, "line1"); fw_key!(m, :enter); fw_type!(m, "line2")
        @test occursin("\n", Qf.text(m.edit_form.desc_area))
        @test m.modal == :card_edit                             # Enter did NOT save
        fw_key!(m, :ctrl, 's')                                  # dedicated save
        @test m.modal == :none
        made = first(filter(i -> i.title == "Multiline", Qf.Stores.list_issues(m.boardstore)))
        @test made.description == "line1\nline2"
    end
    @testset "Enter from a single-line field (title) still saves" begin
        m = fw_login()
        fw_key!(m, 'n'); fw_type!(m, "OneLine")                 # title focused (TextInput)
        fw_key!(m, :enter)
        @test m.modal == :none
        @test any(i.title == "OneLine" for i in Qf.Stores.list_issues(m.boardstore))
    end
    @testset "^S is advertised in the keymap-generated help" begin
        @test occursin("^S", Qf.status_hints([:card_edit]))
    end
end

@testset "Fix-wave: U5 selection stays within the rendered region" begin
    @testset "board: cursor card is rendered after scrolling past the fold" begin
        m = fw_login()
        for i in 1:14; Qf.Stores.create_issue!(m.boardstore; title = "ScrollCard $i", status = "Backlog"); end
        for _ in 1:11; fw_key!(m, 'j'); end                     # deep into the Backlog column
        sel = Qf.selected_issue(m)
        @test sel !== nothing
        rows = app_rows(m; w = 100, h = 16)                     # short: not all cards fit
        @test any(occursin(sel.key, r) for r in rows)           # scroll-follow keeps it visible
    end
    @testset "backlog: last item stays visible after scrolling" begin
        m = fw_login()
        for i in 1:22; Qf.Stores.create_issue!(m.boardstore; title = "BL $i", status = "Backlog"); end
        fw_key!(m, 'C'); fw_key!(m, 'K')                        # backlog view
        n = length(Qf._backlog_selectable(m))
        for _ in 1:(n - 1); fw_key!(m, 'j'); end
        sel = Qf._backlog_selected_issue(m)
        rows = app_rows(m; w = 100, h = 14)
        @test any(occursin(sel.key, r) for r in rows)
    end
    @testset "gantt: selected row stays visible after scrolling" begin
        m = fw_login()
        d = Dates.today()
        for i in 1:20
            Qf.Stores.create_issue!(m.boardstore; title = "G$i",
                                    start_date = d + Day(i), due_date = d + Day(i + 2), status = "To Do")
        end
        fw_key!(m, 'C'); fw_key!(m, 'G')                        # gantt view
        n = length(Qf.gantt_issue_rows(m))
        for _ in 1:(n - 1); fw_key!(m, 'j'); end
        sel = Qf._gantt_selected_issue(m)
        rows = app_rows(m; w = 110, h = 14)
        @test any(occursin(sel.key, r) for r in rows)
    end
end

@testset "Fix-wave: U4 board columns never overwrite the right border" begin
    m = fw_login()
    # Check the board/content region (below the logo band) so this isolates the
    # board grid, whose columns must fit the body width (finding U4). The right
    # border column must stay an unbroken vertical rule across those rows.
    for (w, h) in [(38, 24), (40, 24), (43, 22), (30, 20)]
        tb = app_tb(m; w = w, h = h)
        rows = 9:(h - 2)                                        # board grid + blank rows
        border = T.char_at(tb, w, first(rows))
        @test all(T.char_at(tb, w, y) == border for y in rows)
        @test border != ' '                                    # it really is a border rule
    end
end

@testset "Fix-wave: U3 sign-in hints respect the focused email field" begin
    udb = tempname()
    Qf.Stores.create_user!(Qf.Stores.SQLiteUserStore(udb); email = "h@qci.com", name = "H", password = "pw12")
    m = fresh_app(; user_db = udb)                              # sign-in stage, email focused
    @test m.auth_stage == :signin
    @test Qf.focused_editor(m.focus) !== nothing
    # generated hints must drop printable-char shortcuts while an editor owns input
    h = Qf.status_hints([:login]; editors_focused = true)
    @test !occursin("[c]", h) && !occursin("[q]", h)
    @test occursin("[Enter]", h)
    tb = app_tb(m; w = 90, h = 22)
    @test T.find_text(tb, "Sign in") !== nothing
    @test T.find_text(tb, "Create account") === nothing        # not advertised (would type 'c')
    # first-run (no editor focused) DOES advertise create-account
    m2 = fresh_app()
    @test Qf.focused_editor(m2.focus) === nothing
    @test occursin("[c]", Qf.status_hints([:login]; editors_focused = false))
end

@testset "Fix-wave: U10 help overlay flags hidden bindings" begin
    m = fw_login(); fw_key!(m, '?')
    @test m.modal == :help
    @testset "80x24 overflows → shows a 'more' indicator, essentials still visible" begin
        tb = app_tb(m; w = 80, h = 24)
        @test T.find_text(tb, "HELP") !== nothing
        @test T.find_text(tb, "more — resize") !== nothing
        @test T.find_text(tb, "Quit") !== nothing              # global (rendered first)
    end
    @testset "tall terminal shows everything, no indicator" begin
        tb = app_tb(m; w = 80, h = 70)
        @test T.find_text(tb, "HELP") !== nothing
        @test T.find_text(tb, "more — resize") === nothing
    end
end
