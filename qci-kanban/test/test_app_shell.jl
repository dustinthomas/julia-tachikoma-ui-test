# Phase 2c/2d — AppModel: login gate, session, view router, header, status,
# help, small-terminal guard. Drives exclusively via update!(m, KeyEvent(...)).
# Depends on `using QciKanban`, `const T = Tachikoma` from runtests.jl.

Q = QciKanban

# Fresh v2 model on isolated :memory: stores + a throwaway token path.
fresh_app(; kwargs...) = Q.AppModel(; token_path = tempname(), secret = "test-secret", kwargs...)

app_rows(m; w = 80, h = 20) = begin
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1, 1, w, h), T.GraphicsRegion[], T.PixelSnapshot[]))
    [T.row_text(tb, i) for i in 1:h]
end

app_tb(m; w = 80, h = 20) = begin
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    T.view(m, T.Frame(tb.buf, T.Rect(1, 1, w, h), T.GraphicsRegion[], T.PixelSnapshot[]))
    tb
end

# Drive the create-account flow to a logged-in board.
function app_login_new(m; email = "user@qci.com", name = "Test User", pw = "password")
    T.update!(m, T.KeyEvent('c'))
    for ch in collect(email); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:tab))
    for ch in collect(name); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:tab))
    for ch in collect(pw); T.update!(m, T.KeyEvent(ch)); end
    T.update!(m, T.KeyEvent(:enter))
    m
end

@testset "Phase 2c — Login gate" begin
    @testset "first-run: zero users → exact create-account prompt, no board bleed" begin
        m = fresh_app()
        @test m.current_user === nothing
        @test m.user_count == 0
        tb = app_tb(m; w = 80, h = 20)
        @test T.find_text(tb, "No users — press [c] to create account") !== nothing
        @test T.find_text(tb, "LOGIN") !== nothing
        # no main-shell / board content leaks under the gate
        @test T.find_text(tb, "coming in a later phase") === nothing
        rows = app_rows(m; w = 80, h = 20)
        @test !any(occursin("BACKLOG", r) for r in rows)
    end

    @testset "create-account flow lands on the board, seeded demo present" begin
        m = fresh_app()
        app_login_new(m; name = "Ada Lovelace")
        @test m.current_user !== nothing
        @test m.current_user.name == "Ada Lovelace"
        @test m.view == :board
        # session token was persisted
        @test isfile(m.session.token_path)
        tb = app_tb(m)
        @test T.find_text(tb, "BOARD") !== nothing
        @test T.find_text(tb, "No users") === nothing
        # seeded board (issues) exists in the store
        @test !isempty(Q.Stores.list_issues(m.boardstore))
    end

    @testset "password never appears in the render buffer (masked)" begin
        m = fresh_app()
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("neo@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("Neo"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("trinity"); T.update!(m, T.KeyEvent(ch)); end
        rows = app_rows(m; w = 90, h = 24)
        blob = join(rows, "\n")
        @test !occursin("trinity", blob)     # plaintext never rendered
        @test occursin("•", blob)            # masked bullets shown
        @test Q.text(m.password_input) == "trinity"  # but state holds the real value
    end

    @testset "wrong password shows error (err color) and stays gated" begin
        udb = tempname()
        # seed a real user via the store
        Q.Stores.create_user!(Q.Stores.SQLiteUserStore(udb); email = "x@qci.com", name = "X", password = "rightpw")
        m = fresh_app(; user_db = udb)
        @test m.user_count == 1
        @test m.auth_stage == :signin
        for ch in collect("x@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("bogus"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user === nothing
        @test occursin("Invalid", m.login_error)
        tb = app_tb(m; w = 90, h = 22)
        loc = T.find_text(tb, "Invalid email or password")
        @test loc !== nothing
        st = T.style_at(tb, loc.x, loc.y)
        @test st.fg == Q.Theming.col_err()      # error line uses theme err color
        # correct password now logs in
        for ch in collect("rightpw"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user !== nothing
    end

    @testset "invalid inputs on create surface a validation error, no user made" begin
        m = fresh_app()
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("not-an-email"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user === nothing
        @test occursin("valid email", m.login_error)
        @test isempty(Q.Stores.list_users(m.userstore))
    end

    @testset "create validation: empty name, then short password" begin
        m = fresh_app()
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("who@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))               # valid email, empty name
        @test occursin("name", m.login_error)
        @test isempty(Q.Stores.list_users(m.userstore))
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("Who"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("no"); T.update!(m, T.KeyEvent(ch)); end   # < 4 chars
        T.update!(m, T.KeyEvent(:enter))
        @test occursin("Password", m.login_error)
        @test isempty(Q.Stores.list_users(m.userstore))
    end

    @testset "create with a duplicate email errors and makes no second user" begin
        udb = tempname()
        Q.Stores.create_user!(Q.Stores.SQLiteUserStore(udb); email = "dup@qci.com", name = "Dup", password = "pw12")
        m = fresh_app(; user_db = udb)                 # 1 user → sign-in stage
        T.update!(m, T.KeyEvent(:ctrl, 'n'))           # to create via Ctrl+N
        @test m.auth_stage == :create
        for ch in collect("dup@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab)); for ch in collect("Dup2"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab)); for ch in collect("pw12"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user === nothing
        @test occursin("Could not create", m.login_error)
        @test length(Q.Stores.list_users(m.userstore)) == 1
    end

    @testset "empty-email sign-in submit errors without authenticating" begin
        udb = tempname()
        Q.Stores.create_user!(Q.Stores.SQLiteUserStore(udb); email = "e@qci.com", name = "E", password = "pw12")
        m = fresh_app(; user_db = udb)
        T.update!(m, T.KeyEvent(:enter))               # nothing typed
        @test m.current_user === nothing
        @test occursin("email", m.login_error)
    end

    @testset "Esc from create returns to the sign-in stage" begin
        m = fresh_app()
        T.update!(m, T.KeyEvent('c'))
        @test m.auth_stage == :create
        T.update!(m, T.KeyEvent(:escape))
        @test m.auth_stage == :signin
    end
end

@testset "Phase 2c — Session restore on startup" begin
    @testset "valid persisted token skips login" begin
        udb = tempname(); tok = tempname()
        m1 = Q.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        app_login_new(m1; email = "a@qci.com", name = "Restored")
        @test isfile(tok)
        m2 = Q.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        @test m2.current_user !== nothing
        @test m2.current_user.name == "Restored"
        @test m2.view == :board
    end

    @testset "tampered/expired token → login screen" begin
        udb = tempname(); tok = tempname()
        m1 = Q.AppModel(; user_db = udb, token_path = tok, secret = "shared")
        app_login_new(m1; email = "b@qci.com")
        # wrong secret cannot verify the signature
        m2 = Q.AppModel(; user_db = udb, token_path = tok, secret = "different")
        @test m2.current_user === nothing
        # expired ttl: negative ttl makes exp <= now
        udb2 = tempname(); tok2 = tempname()
        me = Q.AppModel(; user_db = udb2, token_path = tok2, secret = "s", ttl_seconds = -10)
        app_login_new(me; email = "c@qci.com")
        m3 = Q.AppModel(; user_db = udb2, token_path = tok2, secret = "s")
        @test m3.current_user === nothing
    end
end

@testset "Phase 2d — App frame: views, header, status, help, logout" begin
    @testset "view router switches board/backlog/calendar/gantt" begin
        m = fresh_app(); app_login_new(m)
        # NOTE: press 'K' (Backlog) from a non-board view — on the board 'K' is
        # rank-up (Phase 3 view-beats-global binding), so we leave the board first.
        for (k, v, title) in [('C', :calendar, "CALENDAR"), ('K', :backlog, "BACKLOG"),
                              ('G', :gantt, "GANTT"), ('B', :board, "BOARD")]
            T.update!(m, T.KeyEvent(k))
            @test m.view == v
            tb = app_tb(m)
            @test T.find_text(tb, title) !== nothing
        end
    end

    @testset "header shows QCI branding, status bar shows contextual hints" begin
        m = fresh_app(); app_login_new(m)
        tb = app_tb(m)
        @test T.find_text(tb, "QCI") !== nothing
        @test T.find_text(tb, "KANBAN") !== nothing
        # status hints generated from keymap (Quit / Help present somewhere)
        rows = app_rows(m)
        blob = join(rows, " ")
        @test occursin("Quit", blob) || occursin("[q]", blob)
        @test occursin("Help", blob) || occursin("[?]", blob)
    end

    @testset "help overlay opens from keymap, closes on Esc, no bleed rules" begin
        m = fresh_app(); app_login_new(m)
        T.update!(m, T.KeyEvent('?'))
        @test m.modal == :help
        tb = app_tb(m)
        @test T.find_text(tb, "HELP") !== nothing
        @test T.find_text(tb, "Quit") !== nothing        # generated content
        # underlying stub placeholder is cleared under the overlay box
        T.update!(m, T.KeyEvent(:escape))
        @test m.modal == :none
        tb2 = app_tb(m)
        @test T.find_text(tb2, "HELP") === nothing
        @test T.find_text(tb2, "BOARD") !== nothing
    end

    @testset "logout (Ctrl+L) returns to login and deletes token" begin
        m = fresh_app(); app_login_new(m)
        tok = m.session.token_path
        @test isfile(tok)
        T.update!(m, T.KeyEvent(:ctrl, 'l'))
        @test m.current_user === nothing
        @test m.auth_stage == :signin
        @test !isfile(tok)
        tb = app_tb(m)
        # after logout the (now 1) user store means the sign-in form, not first-run
        @test T.find_text(tb, "SIGN IN") !== nothing
    end

    @testset "quit only from a non-focused context; q types into a focused field" begin
        m = fresh_app()      # first-run: no editor focused → q quits
        # go into create so an editor is focused
        T.update!(m, T.KeyEvent('c'))
        T.update!(m, T.KeyEvent('q'))
        @test m.quit == false                 # typed into email, did not quit
        @test occursin("q", Q.text(m.email_input))
        # logged-in board: q quits (no editor focused)
        m2 = fresh_app(); app_login_new(m2)
        T.update!(m2, T.KeyEvent('q'))
        @test m2.quit == true
    end
end

@testset "Phase 2d — sizes: 80x20, 100x28, small guard" begin
    @testset "renders without error at target + large sizes" begin
        m = fresh_app()
        for (w, h) in [(80, 20), (100, 28)]
            tb = app_tb(m; w = w, h = h)
            @test T.find_text(tb, "No users — press [c] to create account") !== nothing
        end
        m2 = fresh_app(); app_login_new(m2)
        for (w, h) in [(80, 20), (100, 28)]
            tb = app_tb(m2; w = w, h = h)
            @test T.find_text(tb, "BOARD") !== nothing
        end
    end

    @testset "small terminal shows a graceful guard, no crash" begin
        m = fresh_app()
        for (w, h) in [(18, 4), (20, 6), (22, 7)]
            tb = app_tb(m; w = w, h = h)
            @test T.find_text(tb, "QCI") !== nothing
        end
    end
end

@testset "PackageCompiler entry — julia_main / smoke / help" begin
    @testset "_compiled_app_smoke returns 0 with full gate string (isolated)" begin
        # Call helper directly — never mutate global ARGS.
        code = Q._compiled_app_smoke()
        @test code == 0
        @test code isa Cint
    end

    @testset "_smoke_check_gate covers missing-text failure path" begin
        tb = T.TestBackend(80, 24)
        T.reset!(tb.buf)
        # Empty buffer cannot contain the production gate string.
        mktemp() do path, io
            code = redirect_stderr(io) do
                Q._smoke_check_gate(tb)
            end
            flush(io)
            @test code == 1
            @test occursin("missing gate text", read(path, String))
        end
        # Success path via the same helper (after a real first-run render).
        m = fresh_app()
        tb2 = app_tb(m; w = 80, h = 24)
        @test Q._smoke_check_gate(tb2) == 0
    end

    @testset "pure ARG dispatch: help / smoke / interactive / env" begin
        @test Q._app_cli_mode(String["--help"]) === :help
        @test Q._app_cli_mode(String["-h"]) === :help
        @test Q._app_cli_mode(String["--smoke"]) === :smoke
        @test Q._app_cli_mode(String[]; env_smoke = "1") === :smoke
        @test Q._app_cli_mode(String["--smoke"]; env_smoke = "") === :smoke
        @test Q._app_cli_mode(String[]) === :interactive
        @test Q._app_cli_mode(String["--other"]) === :interactive
        # help wins when both present
        @test Q._app_cli_mode(String["--help", "--smoke"]) === :help
    end

    @testset "julia_main help / smoke via local args (no ARGS mutation)" begin
        @test Q.julia_main(String["--help"]) == 0
        @test Q.julia_main(String["-h"]) == 0
        @test Q.julia_main(String["--smoke"]) == 0
        @test Q.julia_main(String[]; env_smoke = "1") == 0
    end

    @testset "julia_main interactive path uses injectable handoff (no live TUI)" begin
        called = Ref(false)
        # Explicit env_smoke="" so a real QCI_SMOKE=1 in the environment cannot divert.
        code = Q.julia_main(String[]; env_smoke = "",
                            interactive = () -> (called[] = true; Cint(0)))
        @test code == 0
        @test called[]
    end

    @testset "julia_main catch returns 1 on error" begin
        code = Q.julia_main(String[]; env_smoke = "",
                            interactive = () -> error("forced entry failure"))
        @test code == 1
    end

    @testset "_print_app_help is callable" begin
        # Redirect stderr so the suite stays quiet; still executes the printer.
        mktemp() do path, io
            redirect_stderr(io) do
                Q._print_app_help()
            end
            flush(io)
            body = read(path, String)
            @test occursin("qci-kanban", body)
            @test occursin("--smoke", body)
            @test occursin("kanban2", body)
        end
    end
end
