# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance specs for Phase 2 — UI shell (theme, focus, login, frame).
# Given/When/Then nested testsets driving the app purely via
# update!(m, KeyEvent(...)) + TestBackend. Includes the mandatory property
# test: in every focused-editor context, ANY printable char mutates only that
# editor's text — view/global state unchanged.
# ═══════════════════════════════════════════════════════════════════════
using Test

const HAS_SUPPOSITION2 = try
    @eval import Supposition
    true
catch
    false
end

Qk = QciKanban

# Build a model positioned in a focused-editor context.
function _ctx_model(stage::Symbol)
    if stage == :create
        m = Qk.AppModel(; token_path = tempname(), secret = "s")
        T.update!(m, T.KeyEvent('c'))          # → create stage, email focused
        return m
    else # signin with an existing user
        udb = tempname()
        Qk.Stores.create_user!(Qk.Stores.SQLiteUserStore(udb);
                               email = "p@qci.com", name = "P", password = "pw12")
        return Qk.AppModel(; user_db = udb, token_path = tempname(), secret = "s")
    end
end

# Feed one printable char at a given focus index; return true iff ONLY that
# editor's text changed (by exactly the char) and all view/global state held.
function _only_focused_editor_changes(m, focus_idx::Int, ch::Char)::Bool
    Qk.focus_index!(m.focus, focus_idx)
    eds = m.focus.editors
    before = [Qk.text(e) for e in eds]
    snap = (m.quit, m.current_user, m.view, m.modal, m.auth_stage)
    T.update!(m, T.KeyEvent(ch))
    for (i, e) in enumerate(eds)
        want = i == focus_idx ? before[i] * string(ch) : before[i]
        Qk.text(e) == want || return false
    end
    m.quit == snap[1] && m.current_user === snap[2] && m.view === snap[3] &&
        m.modal === snap[4] && m.auth_stage === snap[5]
end

@testset "FEATURE: Phase 2 UI shell (BDD acceptance)" begin

    @testset "Login: gate, error, success, restore, tamper" begin
        @testset "Given a fresh first-run app (zero users)" begin
            m = Qk.AppModel(; token_path = tempname(), secret = "s")
            @testset "When rendered Then the create-account prompt is shown, board hidden" begin
                tb = T.TestBackend(80, 20); T.reset!(tb.buf)
                T.view(m, T.Frame(tb.buf, T.Rect(1, 1, 80, 20), T.GraphicsRegion[], T.PixelSnapshot[]))
                @test T.find_text(tb, "No users — press [c] to create account") !== nothing
                @test T.find_text(tb, "coming in a later phase") === nothing
            end
        end

        @testset "Given a registered user" begin
            udb = tempname()
            Qk.Stores.create_user!(Qk.Stores.SQLiteUserStore(udb);
                                   email = "u@qci.com", name = "Registered", password = "correct")
            @testset "When the wrong password is entered Then it errors and stays gated" begin
                m = Qk.AppModel(; user_db = udb, token_path = tempname(), secret = "s")
                for ch in collect("u@qci.com"); T.update!(m, T.KeyEvent(ch)); end
                T.update!(m, T.KeyEvent(:tab))
                for ch in collect("nope"); T.update!(m, T.KeyEvent(ch)); end
                T.update!(m, T.KeyEvent(:enter))
                @test m.current_user === nothing
                @test !isempty(m.login_error)
            end
            @testset "When the correct password is entered Then it lands on the board" begin
                m = Qk.AppModel(; user_db = udb, token_path = tempname(), secret = "s")
                for ch in collect("u@qci.com"); T.update!(m, T.KeyEvent(ch)); end
                T.update!(m, T.KeyEvent(:tab))
                for ch in collect("correct"); T.update!(m, T.KeyEvent(ch)); end
                T.update!(m, T.KeyEvent(:enter))
                @test m.current_user !== nothing
                @test m.view == :board
            end
        end

        @testset "Given a signed-in session persisted to disk" begin
            udb = tempname(); tok = tempname()
            m1 = Qk.AppModel(; user_db = udb, token_path = tok, secret = "shared")
            T.update!(m1, T.KeyEvent('c'))
            for ch in collect("re@qci.com"); T.update!(m1, T.KeyEvent(ch)); end
            T.update!(m1, T.KeyEvent(:tab)); for ch in collect("Re"); T.update!(m1, T.KeyEvent(ch)); end
            T.update!(m1, T.KeyEvent(:tab)); for ch in collect("pw12"); T.update!(m1, T.KeyEvent(ch)); end
            T.update!(m1, T.KeyEvent(:enter))
            @testset "When the app restarts with a valid token Then login is skipped" begin
                m2 = Qk.AppModel(; user_db = udb, token_path = tok, secret = "shared")
                @test m2.current_user !== nothing
            end
            @testset "When the token/secret is tampered Then it returns to login" begin
                m3 = Qk.AppModel(; user_db = udb, token_path = tok, secret = "tampered")
                @test m3.current_user === nothing
            end
        end
    end

    @testset "PROPERTY: focused editor absorbs every printable char" begin
        # For every focused-editor context (signin email/password; create
        # email/name/password) and any printable char, only that editor mutates.
        cases = [(:signin, 1), (:signin, 2), (:create, 1), (:create, 2), (:create, 3)]

        # C1/U1 regression: the sweep now spans ASCII *and* multibyte + emoji
        # code points (Latin-1, CJK, box-drawing, and the emoji planes), so a
        # focused editor must absorb any Unicode char — never a byte-slice crash.
        NONASCII = Char[
            'é', 'ñ', 'ü', '—', '…', '©', '►', '◄', '☑', '☐', '▬', '◆',
            '日', '本', '語', 'م', 'Ω', '\U0001F3AF', '\U0001F600', '\U0001F680',
        ]
        if HAS_SUPPOSITION2
            @eval using Supposition
            for (stage, idx) in cases
                m = _ctx_model(stage)
                @eval begin
                    _pm = $m
                    Supposition.@check function focused_absorbs(
                            code = Supposition.Data.Integers(32, 129791))  # 0x1FAFF; both bounds Int (Supposition requires matching types)
                        isvalid(Char, code) || return true      # skip surrogates/invalid
                        $(_only_focused_editor_changes)(_pm, $idx, Char(code))
                    end
                end
            end
            @testset "explicit non-ASCII/emoji chars absorbed by the focused editor" begin
                for (stage, idx) in cases
                    m = _ctx_model(stage)
                    for ch in NONASCII
                        @test _only_focused_editor_changes(m, idx, ch)
                    end
                end
            end
        else
            @testset "deterministic sweep over printable + non-ASCII chars (Supposition unavailable)" begin
                for (stage, idx) in cases
                    m = _ctx_model(stage)
                    for code in 32:126
                        @test _only_focused_editor_changes(m, idx, Char(code))
                    end
                    for ch in NONASCII
                        @test _only_focused_editor_changes(m, idx, ch)
                    end
                end
            end
        end

        @testset "sanity: shortcut chars (q,c,B,?) still only type into the field" begin
            m = _ctx_model(:signin)
            for ch in ['q', 'c', 'B', '?', '1', '9', '<', '>']
                @test _only_focused_editor_changes(m, 1, ch)
            end
            @test m.quit == false
            @test m.current_user === nothing
        end
    end

    @testset "App frame: view router + logout + help are keymap-driven" begin
        m = Qk.AppModel(; token_path = tempname(), secret = "s")
        T.update!(m, T.KeyEvent('c'))
        for ch in collect("f@qci.com"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab)); for ch in collect("F"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:tab)); for ch in collect("pw12"); T.update!(m, T.KeyEvent(ch)); end
        T.update!(m, T.KeyEvent(:enter))
        @testset "When switching views Then the router follows the keymap" begin
            T.update!(m, T.KeyEvent('G')); @test m.view == :gantt
            T.update!(m, T.KeyEvent('C')); @test m.view == :calendar
            T.update!(m, T.KeyEvent('B')); @test m.view == :board
        end
        @testset "When Ctrl+L is pressed Then the session ends" begin
            @test m.current_user !== nothing
            T.update!(m, T.KeyEvent(:ctrl, 'l'))
            @test m.current_user === nothing
        end
    end
end
