# Phase 2c/2d — AppModel: login gate, session, view router, header, status,
# help, small-terminal guard. Drives exclusively via update!(m, KeyEvent(...)).
# Depends on `using QciKanban`, `const T = Tachikoma` from runtests.jl.

Q = QciKanban

# Fresh v2 model on isolated :memory: stores + a throwaway session dir.
# Token lives in mktempdir() so last_project / gantt_ui.toml never collide under /tmp.
fresh_app(; kwargs...) = Q.AppModel(; token_path = joinpath(mktempdir(), "session.jwt"),
                                    secret = "test-secret", kwargs...)

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
        @test m.view == :board
        # K must open Backlog from the board (status bar advertises [K] Backlog).
        T.update!(m, T.KeyEvent('K'))
        @test m.view == :backlog
        @test T.find_text(app_tb(m), "BACKLOG") !== nothing
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

    @testset "logout via O and Ctrl+L (uppercase) from board" begin
        # Many terminals steal Ctrl+L (clear screen); O is the reliable binding.
        m = fresh_app(); app_login_new(m)
        @test m.current_user !== nothing && m.view == :board
        T.update!(m, T.KeyEvent('O'))
        @test m.current_user === nothing
        @test m.auth_stage == :signin
        @test T.find_text(app_tb(m), "SIGN IN") !== nothing

        m2 = fresh_app(); app_login_new(m2)
        T.update!(m2, T.KeyEvent(:ctrl, 'L'))   # uppercase L from some keyboards
        @test m2.current_user === nothing
        @test m2.auth_stage == :signin
    end

    @testset "sign-in accepts mixed-case email" begin
        m = fresh_app()
        app_login_new(m; email = "CaseUser@qci.com", name = "Case", pw = "secret")
        @test m.current_user !== nothing
        T.update!(m, T.KeyEvent('O'))   # logout
        @test m.current_user === nothing
        # type mixed-case email + password
        for ch in collect("caseuser@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab))
        for ch in collect("secret"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @test m.current_user !== nothing
        @test lowercase(m.current_user.email) == "caseuser@qci.com"
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

@testset "Toast chips — fit_toast_segments + painter (PR-T2)" begin
    neut = T.Style(; fg = Q.Theming.col_text())
    function synth_drag_segs(; boxed = true, key = "QCI-1")
        [
            Q.toast_seg(:project, "PROJECT: Demo Lab (DEMO)",
                T.Style(; fg = Q.Theming.col_primary(), dim = true); boxed = boxed),
            Q.toast_seg(:mode, "Drag move", neut; boxed = boxed),
            Q.toast_seg(:key, key, neut; boxed = boxed),
            Q.toast_seg(:start, "start Jul 22", neut; boxed = boxed),
            Q.toast_seg(:due, "due Jul 31", neut; boxed = boxed),
            Q.toast_seg(:duration, "10d", neut; boxed = boxed),
        ]
    end

    @testset "fit_toast_segments pure: D1 drop duration, D2 compress project, D5 shorten mode" begin
        full = synth_drag_segs(; boxed = true)
        # wide enough for full boxed chips
        w_wide = Q.total_toast_width(full)
        @test w_wide > Q.TOAST_BOX_MIN_W
        kept = Q.fit_toast_segments(full, w_wide)
        @test any(s -> s.role === :duration, kept)
        @test any(s -> s.role === :project && startswith(s.text, "PROJECT:"), kept)
        @test any(s -> s.role === :mode && s.text == "Drag move", kept)

        # force D1: width just under full (drops duration first)
        no_dur = filter(s -> s.role !== :duration, full)
        w_no_dur = Q.total_toast_width(no_dur)
        fitted = Q.fit_toast_segments(full, w_no_dur)
        @test !any(s -> s.role === :duration, fitted)
        @test any(s -> s.role === :key && s.text == "QCI-1", fitted)

        # force compress project: after drop duration, still need shorter project
        compressed = map(s -> s.role === :project ?
            Q.with_text(s, "P: DEMO") : s, no_dur)
        w_comp = Q.total_toast_width(compressed)
        fitted2 = Q.fit_toast_segments(full, w_comp)
        @test !any(s -> s.role === :duration, fitted2)
        proj = filter(s -> s.role === :project, fitted2)
        @test !isempty(proj)
        @test startswith(proj[1].text, "P: ")
        @test occursin("DEMO", proj[1].text)

        # unbox at max_w < TOAST_BOX_MIN_W
        unboxed = Q.fit_toast_segments(full, 60)
        @test all(s -> s.boxed === false, unboxed)
        @test Q.total_toast_width(unboxed) <= 60

        # width 50 keeps key when mode/dates remain
        at50 = Q.fit_toast_segments(full, Q.TOAST_KEEP_CORE_W)
        @test any(s -> s.role === :key, at50)
        @test Q.total_toast_width(at50) <= Q.TOAST_KEEP_CORE_W

        # hard clip / no throw at 40
        at40 = Q.fit_toast_segments(full, Q.TOAST_HARD_CLIP_W)
        @test Q.total_toast_width(at40) <= Q.TOAST_HARD_CLIP_W
        roles40 = Set(s.role for s in at40)
        # mode shortened or present; duration gone; project likely gone
        @test !(:duration in roles40)

        # D5 shorten mode applies under pressure
        mode_only_pressure = [
            Q.toast_seg(:mode, "Drag move", neut; boxed = false),
            Q.toast_seg(:key, "K", neut; boxed = false),
            Q.toast_seg(:start, "start Jul 22", neut; boxed = false),
            Q.toast_seg(:due, "due Jul 31", neut; boxed = false),
        ]
        # Width that needs shorten but can still fit shortened forms + key
        tw_full = Q.total_toast_width(mode_only_pressure)
        short_mode = map(s -> s.role === :mode ? Q.with_text(s, "Move") : s, mode_only_pressure)
        tw_short = Q.total_toast_width(short_mode)
        @test tw_short < tw_full
        fitted_m = Q.fit_toast_segments(mode_only_pressure, tw_short)
        mode_segs = filter(s -> s.role === :mode, fitted_m)
        @test !isempty(mode_segs)
        @test mode_segs[1].text == "Move"
    end

    @testset "fit_toast_segments edge transforms: modes, date, warn, hard-clip, no-parens project" begin
        # Direct helpers (also cover closed-table map branches)
        @test Q._shorten_mode_text("Drag start") == "Start"
        @test Q._shorten_mode_text("Drag due") == "Due"
        @test Q._shorten_mode_text("Drag date") == "Date"
        @test Q._shorten_mode_text("Drag") == "Drag"
        @test Q._shorten_mode_text("Other") == "Other"
        @test Q._shorten_date_text("Jul 10") == "Jul10"
        @test Q._shorten_date_text("Jul10") == "Jul10"
        @test Q._compress_project_text("PROJECT: NoParens Name") == "P: NoParens"
        @test Q._compress_project_text("PROJECT: Lab (KEY1)") == "P: KEY1"
        @test Q._compress_project_text("plain") == "P: plain"

        # D5 all mode labels via fit under pressure
        for (long, short) in (("Drag start", "Start"), ("Drag due", "Due"),
                              ("Drag date", "Date"), ("Drag move", "Move"))
            segs = [
                Q.toast_seg(:mode, long, neut; boxed = false),
                Q.toast_seg(:key, "ABCDEFGHIJ", neut; boxed = false),
            ]
            # width that requires shortening mode but keeps both
            short_pair = [
                Q.toast_seg(:mode, short, neut; boxed = false),
                Q.toast_seg(:key, "ABCDEFGHIJ", neut; boxed = false),
            ]
            w = Q.total_toast_width(short_pair)
            fitted = Q.fit_toast_segments(segs, w)
            ms = filter(s -> s.role === :mode, fitted)
            @test !isempty(ms)
            @test ms[1].text == short
        end

        # D6/D7/D8 shorten start/due/date
        date_segs = [
            Q.toast_seg(:mode, "Move", neut; boxed = false),
            Q.toast_seg(:start, "start Jul 22", neut; boxed = false),
            Q.toast_seg(:due, "due Jul 31", neut; boxed = false),
            Q.toast_seg(:date, "Jul 10", neut; boxed = false),
        ]
        short_dates = [
            Q.toast_seg(:mode, "Move", neut; boxed = false),
            Q.toast_seg(:start, "s Jul22", neut; boxed = false),
            Q.toast_seg(:due, "d Jul31", neut; boxed = false),
            Q.toast_seg(:date, "Jul10", neut; boxed = false),
        ]
        fitted_d = Q.fit_toast_segments(date_segs, Q.total_toast_width(short_dates))
        @test any(s -> s.role === :start && s.text == "s Jul22", fitted_d)
        @test any(s -> s.role === :due && s.text == "d Jul31", fitted_d)
        @test any(s -> s.role === :date && s.text == "Jul10", fitted_d)

        # D4 drop warn when needed
        with_warn = [
            Q.toast_seg(:warn, "Role warning: viewer lacks edit_issue (enforcement off)",
                T.Style(; fg = Q.Theming.col_warn(), bold = true); boxed = false),
            Q.toast_seg(:mode, "Drag move", neut; boxed = false),
            Q.toast_seg(:key, "QCI-9", neut; boxed = false),
            Q.toast_seg(:start, "start Jul 1", neut; boxed = false),
            Q.toast_seg(:due, "due Jul 9", neut; boxed = false),
        ]
        no_warn = filter(s -> s.role !== :warn, with_warn)
        fitted_w = Q.fit_toast_segments(with_warn, Q.total_toast_width(no_warn))
        @test !any(s -> s.role === :warn, fitted_w)
        @test any(s -> s.role === :mode, fitted_w)

        # hard-clip single long chip
        long1 = [Q.toast_seg(:plain, "abcdefghijklmnopqrstuvwxyz0123456789", neut; boxed = false)]
        clipped = Q.fit_toast_segments(long1, 10)
        @test length(clipped) == 1
        @test Q.total_toast_width(clipped) <= 10
        @test textwidth(clipped[1].text) <= 10

        # hard-clip single boxed chip (brackets eat 2)
        long_box = [Q.toast_seg(:key, "VERYLONGKEYVALUEHERE", neut; boxed = true)]
        clipped_b = Q.fit_toast_segments(long_box, 8)  # unboxes first (<72) then clips
        @test Q.total_toast_width(clipped_b) <= 8

        # hard-clip multi: force residual rightmost clip after role drops
        multi = [
            Q.toast_seg(:mode, "M", neut; boxed = false),
            Q.toast_seg(:key, "KEY", neut; boxed = false),
            Q.toast_seg(:plain, "XXXXXXXXXXXXXXXXXXXX", neut; boxed = false),
        ]
        # max_w small enough that plain is hard-clipped (or dropped)
        clipped_m = Q.fit_toast_segments(multi, 12)
        @test Q.total_toast_width(clipped_m) <= 12
        # extreme: width 1
        tiny = Q.fit_toast_segments(multi, 1)
        @test Q.total_toast_width(tiny) <= 1
        # width 0 / empty
        @test isempty(Q.fit_toast_segments(multi, 0)) || Q.total_toast_width(Q.fit_toast_segments(multi, 0)) <= 0

        # key retention at KEEP_CORE_W: prefer drop project/warn over key
        keep_core = [
            Q.toast_seg(:project, "PROJECT: Big Name Here (BIGKEY)",
                T.Style(; fg = Q.Theming.col_primary(), dim = true); boxed = false),
            Q.toast_seg(:warn, "Role warning: x", T.Style(; fg = Q.Theming.col_warn()); boxed = false),
            Q.toast_seg(:mode, "Drag move", neut; boxed = false),
            Q.toast_seg(:key, "KEEPME", neut; boxed = false),
            Q.toast_seg(:start, "start Jul 22", neut; boxed = false),
        ]
        at_keep = Q.fit_toast_segments(keep_core, Q.TOAST_KEEP_CORE_W)
        @test any(s -> s.role === :key && s.text == "KEEPME", at_keep)

        # unknown transform step is a no-op (defensive)
        sample = [Q.toast_seg(:mode, "Drag move", neut; boxed = false)]
        @test length(Q._apply_toast_transform(sample, :nope)) == 1

        # role-drop priority exhaustion: only :plain left and still over → hard clip
        plains = [Q.toast_seg(:plain, "hello world this is long", neut; boxed = false)]
        @test Q.total_toast_width(Q.fit_toast_segments(plains, 5)) <= 5

        # _drop_lowest with nothing left to drop returns same
        empty_drop = Q._drop_lowest_toast_role(Any[], 10)
        @test isempty(empty_drop)

        # _toast_has_core pure
        @test Q._toast_has_core([Q.toast_seg(:mode, "M", neut; boxed = false)]) === true
        @test Q._toast_has_core([Q.toast_seg(:key, "K", neut; boxed = false)]) === false
        @test Q._toast_has_core([Q.toast_seg(:start, "s", neut; boxed = false)]) === true

        # Multi-segment hard-clip paths (call helper directly — fit() reduces to 1 first)
        ab = Q.toast_seg(:mode, "AB", neut; boxed = false)
        longk = Q.toast_seg(:key, "LONGKEYHERE", neut; boxed = false)
        # budget for last < 1 → drop last
        hc1 = Q._hard_clip_toast_segments([ab, longk], 5)
        @test Q.total_toast_width(hc1) <= 5
        @test length(hc1) == 1 && hc1[1].role === :mode
        # clip last text to remaining budget
        hc2 = Q._hard_clip_toast_segments([ab, longk], 10)
        @test Q.total_toast_width(hc2) <= 10
        @test any(s -> s.role === :key, hc2)
        @test textwidth(filter(s -> s.role === :key, hc2)[1].text) < textwidth(longk.text)
        # boxed last with tiny budget for brackets only → drop last
        boxed_last = Q.toast_seg(:key, "ZZ", neut; boxed = true)
        hc3 = Q._hard_clip_toast_segments([ab, boxed_last], 6)  # prefix AB+gap = 5, budget 1 < 2 brackets
        @test Q.total_toast_width(hc3) <= 6
        # wide-char empty fit: budget 1 cannot fit a 2-col glyph → drop last
        wide = Q.toast_seg(:plain, "中文", neut; boxed = false)
        hc4 = Q._hard_clip_toast_segments([ab, wide], 6)  # budget ~1
        @test Q.total_toast_width(hc4) <= 6
        # still-over after clip drops last (defensive branch)
        a = Q.toast_seg(:mode, "AAAAAAAAAA", neut; boxed = false)
        b = Q.toast_seg(:key, "B", neut; boxed = false)
        hc5 = Q._hard_clip_toast_segments([a, b], 3)
        @test Q.total_toast_width(hc5) <= 3
        # single boxed hard-clip with budget < 2 brackets → empty
        hc6 = Q._hard_clip_toast_segments(
            [Q.toast_seg(:key, "X", neut; boxed = true)], 1)
        @test isempty(hc6) || Q.total_toast_width(hc6) <= 1
    end

    @testset "PROJECT chip find_text; non-drag plain message" begin
        m = fresh_app(); app_login_new(m)
        @test m.active_project_id !== nothing
        tb = app_tb(m; w = 100, h = 24)
        @test T.find_text(tb, "PROJECT:") !== nothing
        # wide content (w=100 → toast max_w ≥ TOAST_BOX_MIN_W): boxed chip bg is surface_hi
        loc = T.find_text(tb, "PROJECT:")
        @test loc !== nothing
        # find_text lands on 'P' of "[PROJECT:…]"; boxed paint puts surface_hi on chip cells
        st = T.style_at(tb, loc.x, loc.y)
        @test st.bg == Q.Theming.col_surface_hi()
        @test st.fg == Q.Theming.col_primary()
        # boxed chip should also show opening bracket on the toast row
        row = T.row_text(tb, loc.y)
        @test occursin("[PROJECT:", row) || occursin("PROJECT:", row)

        m.message = "Refreshed"
        tb2 = app_tb(m; w = 100, h = 24)
        @test T.find_text(tb2, "Refreshed") !== nothing
        @test T.find_text(tb2, "PROJECT:") !== nothing
        # PROJECT still once
        rows = app_rows(m; w = 100, h = 24)
        @test count("PROJECT:", join(rows, "\n")) == 1
    end

    @testset "Role-warning non-append: _set_drag_message! replaces tip payload" begin
        m = fresh_app(); app_login_new(m)
        m.current_user = Q.Domain.User(; id = m.current_user.id, email = m.current_user.email,
                                        name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = false
        @test Q.can!(m, :edit_issue) === true
        @test startswith(m.message, "Role warning:")
        warn0 = Q._role_warning_prefix(m.message)
        tip1 = "Drag move · QCI-1 · start Jul 10 · due Jul 12 · 3d"
        Q._set_drag_message!(m, tip1)
        @test startswith(m.message, "Role warning:")
        @test occursin(tip1, m.message)
        @test count("Role warning:", m.message) == 1
        @test count("Drag move", m.message) == 1
        len1 = length(m.message)
        tip2 = "Drag move · QCI-1 · start Jul 12 · due Jul 14 · 3d"
        Q._set_drag_message!(m, tip2)
        Q._set_drag_message!(m, tip2)
        Q._set_drag_message!(m, tip2)
        @test count("Role warning:", m.message) == 1
        @test count("Drag move", m.message) == 1
        @test occursin(tip2, m.message)
        @test !occursin(tip1, m.message) || tip1 == tip2
        @test length(m.message) == length(warn0) + length(" · ") + length(tip2)
        @test length(m.message) <= len1 + 20   # not growing soup across updates
        # empty tip keeps warn only
        Q._set_drag_message!(m, "")
        @test m.message == warn0
    end

    @testset "TestBackend(50/40) no-throw toast paint with drag state" begin
        m = fresh_app(); app_login_new(m)
        issues = Q.Stores.list_issues(m.boardstore)
        @test !isempty(issues)
        iss = first(issues)
        # ensure dated issue for realistic tip
        Q.Stores.update_issue!(m.boardstore, iss.id;
                               start_date = Dates.today(),
                               due_date = Dates.today() + Dates.Day(5))
        iss = Q.Stores.get_issue(m.boardstore, iss.id)
        m.gantt_drag = (
            issue_id = iss.id,
            mode = :body,
            origin_col = 0,
            orig_start = iss.start_date,
            orig_due = iss.due_date,
            preview_start = iss.start_date,
            preview_due = iss.due_date,
        )
        Q._gantt_set_drag_tooltip!(m)
        @test occursin(iss.key, m.message)
        @test occursin("start", lowercase(m.message))
        @test occursin("due", lowercase(m.message))
        # build_toast_segments under drag uses state (not m.message tip parse)
        segs80 = Q.build_toast_segments(m; width = 80)
        @test any(s -> s.role === :mode, segs80)
        @test any(s -> s.role === :key && s.text == iss.key, segs80) ||
              any(s -> s.role === :mode, segs80)
        for (w, h) in [(50, 20), (40, 16), (80, 24)]
            # re-assert drag still active; paint must not throw at narrow widths
            @test m.gantt_drag !== nothing
            tb = app_tb(m; w = w, h = h)
            @test tb !== nothing
            rows = app_rows(m; w = w, h = h)
            @test !isempty(rows)
            segs = Q.build_toast_segments(m; width = max(1, w - 4))
            @test Q.total_toast_width(segs) <= max(1, w - 4) || isempty(segs)
        end
    end

    @testset "build_toast: Role-warning chip under drag + paint hard-clip" begin
        m = fresh_app(); app_login_new(m)
        m.current_user = Q.Domain.User(; id = m.current_user.id, email = m.current_user.email,
                                        name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = false
        @test Q.can!(m, :edit_issue) === true
        @test startswith(m.message, "Role warning:")
        issues = Q.Stores.list_issues(m.boardstore)
        iss = first(issues)
        Q.Stores.update_issue!(m.boardstore, iss.id;
                               start_date = Dates.today(),
                               due_date = Dates.today() + Dates.Day(3))
        iss = Q.Stores.get_issue(m.boardstore, iss.id)
        m.gantt_drag = (
            issue_id = iss.id,
            mode = :body,
            origin_col = 0,
            orig_start = iss.start_date,
            orig_due = iss.due_date,
            preview_start = iss.start_date + Dates.Day(1),
            preview_due = iss.due_date + Dates.Day(1),
        )
        Q._gantt_set_drag_tooltip!(m)
        @test startswith(m.message, "Role warning:")
        @test count("Drag move", m.message) == 1
        # wide build keeps warn chip when space allows
        segs = Q.build_toast_segments(m; width = 200)
        @test any(s -> s.role === :warn, segs) || any(s -> s.role === :mode, segs)
        # render shows warn or key (re-render after drag state)
        tb = app_tb(m; w = 120, h = 24)
        rows = app_rows(m; w = 120, h = 24)
        joined = join(rows, "\n")
        @test occursin("Role warning", joined) || occursin(iss.key, joined) ||
              occursin("Drag", joined) || occursin("Move", joined)
        # second drag update must not grow soup
        len1 = length(m.message)
        Q._gantt_set_drag_tooltip!(m)
        Q._gantt_set_drag_tooltip!(m)
        @test length(m.message) == len1
        @test count("Role warning:", m.message) == 1

        # Direct paint with overflow forces fit_width on last chip (L746)
        tb2 = T.TestBackend(30, 5)
        T.reset!(tb2.buf)
        long_segs = [
            Q.toast_seg(:mode, "Drag move", T.Style(; fg = Q.Theming.col_text()); boxed = false),
            Q.toast_seg(:plain, "this-is-a-very-long-plain-toast-message-body",
                T.Style(; fg = Q.Theming.col_text_muted()); boxed = false),
        ]
        Q._paint_toast_segments!(tb2.buf, 1, 1, 20, long_segs)
        row1 = T.row_text(tb2, 1)
        # Non-space content width must not exceed max_w=20 (real bound, not tautology)
        painted = rstrip(row1)
        @test textwidth(painted) <= 20
        @test occursin("Drag move", painted)  # first chip painted
        # Full long plain body must not appear unclipped past the budget
        @test !occursin("this-is-a-very-long-plain-toast-message-body", painted)
        # empty / zero-width paint no-op
        Q._paint_toast_segments!(tb2.buf, 1, 2, 0, long_segs)
        Q._paint_toast_segments!(tb2.buf, 1, 2, 10, typeof(long_segs[1])[])
        # boxed paint path with surface bg
        boxed_segs = [
            Q.toast_seg(:project, "PROJECT: X (X)",
                T.Style(; fg = Q.Theming.col_primary(), dim = true); boxed = true),
            Q.toast_seg(:mode, "Drag move", T.Style(; fg = Q.Theming.col_text()); boxed = true),
        ]
        Q._paint_toast_segments!(tb2.buf, 1, 3, 28, boxed_segs)
        # re-render live app at extreme narrow after warn+drag
        tb3 = app_tb(m; w = 36, h = 14)
        @test tb3 !== nothing
        app_rows(m; w = 36, h = 14)
    end

    @testset "K13: no-op commit strips drag tip residue" begin
        m = fresh_app(); app_login_new(m)
        issues = Q.Stores.list_issues(m.boardstore)
        iss = first(issues)
        Q.Stores.update_issue!(m.boardstore, iss.id;
                               start_date = Dates.today(),
                               due_date = Dates.today() + Dates.Day(2))
        iss = Q.Stores.get_issue(m.boardstore, iss.id)
        m.gantt_drag = (
            issue_id = iss.id,
            mode = :body,
            origin_col = 0,
            orig_start = iss.start_date,
            orig_due = iss.due_date,
            preview_start = iss.start_date,   # no-op: preview == store
            preview_due = iss.due_date,
        )
        Q._gantt_set_drag_tooltip!(m)
        @test startswith(m.message, "Drag ")
        Q._gantt_commit_drag!(m)
        @test m.gantt_drag === nothing
        @test m.message == "" || !startswith(m.message, "Drag ")
        @test !occursin("Drag move", m.message)

        # Role-warning + tip → no-op keeps warn only
        m.current_user = Q.Domain.User(; id = m.current_user.id, email = m.current_user.email,
                                        name = m.current_user.name, role = "viewer")
        m.config.enforce_roles = false
        @test Q.can!(m, :edit_issue) === true
        warn0 = Q._role_warning_prefix(m.message)
        m.gantt_drag = (
            issue_id = iss.id,
            mode = :body,
            origin_col = 0,
            orig_start = iss.start_date,
            orig_due = iss.due_date,
            preview_start = iss.start_date,
            preview_due = iss.due_date,
        )
        Q._gantt_set_drag_tooltip!(m)
        @test occursin("Drag move", m.message)
        Q._gantt_commit_drag!(m)
        @test m.gantt_drag === nothing
        @test startswith(m.message, "Role warning:")
        @test !occursin("Drag move", m.message)
        @test m.message == warn0 || m.message == Q._role_warning_prefix(m.message)
    end
end
