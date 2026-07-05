# Phase 2b — focus router + declarative keymap (model-agnostic units).
# Depends on `using QciKanban`, `const T = Tachikoma` from runtests.jl.

const FS  = QciKanban
const KEY = T.KeyEvent

@testset "Phase 2b — FocusState" begin
    @testset "empty focus state owns no input" begin
        fs = FS.FocusState()
        @test FS.focused_editor(fs) === nothing
        @test FS.route_to_focus!(fs, KEY('x')) === :fallthrough
    end

    @testset "single editor: printable chars route only to it" begin
        a = T.TextInput(; focused = false)
        fs = FS.FocusState(Any[a])
        @test FS.focused_editor(fs) === a
        @test a.focused == true
        for ch in "q?bBhjkl<>"                 # all would be shortcuts if leaked
            @test FS.route_to_focus!(fs, KEY(ch)) === :consumed
        end
        @test T.text(a) == "q?bBhjkl<>"
    end

    @testset "Tab / Shift-Tab cycle focus; only active editor is focused" begin
        a = T.TextInput(; focused = false); b = T.TextInput(; focused = false)
        fs = FS.FocusState(Any[a, b])
        @test a.focused && !b.focused
        @test FS.route_to_focus!(fs, KEY(:tab)) === :consumed
        @test !a.focused && b.focused
        @test FS.focused_editor(fs) === b
        FS.route_to_focus!(fs, KEY(:backtab))
        @test a.focused && !b.focused
        # cycling wraps
        FS.focus_prev!(fs)
        @test b.focused && !a.focused
    end

    @testset "structural keys are handed back to the keymap" begin
        a = T.TextInput(; focused = false)
        fs = FS.FocusState(Any[a])
        @test FS.route_to_focus!(fs, KEY(:enter))  === :structural
        @test FS.route_to_focus!(fs, KEY(:escape)) === :structural
        @test FS.route_to_focus!(fs, KEY(:ctrl, 'l')) === :structural
        @test FS.route_to_focus!(fs, KEY(:ctrl_c)) === :structural
        @test T.text(a) == ""     # none of them mutated the editor
    end

    @testset "editing keys (backspace/arrows) are consumed by the editor" begin
        a = T.TextInput(; text = "ab", focused = false)
        fs = FS.FocusState(Any[a])
        @test FS.route_to_focus!(fs, KEY(:backspace)) === :consumed
        @test T.text(a) == "a"
        @test FS.route_to_focus!(fs, KEY(:left)) === :consumed
    end

    @testset "blur! releases input to the keymap" begin
        a = T.TextInput(; focused = false)
        fs = FS.FocusState(Any[a])
        FS.blur!(fs)
        @test a.focused == false
        @test FS.focused_editor(fs) === nothing
        @test FS.route_to_focus!(fs, KEY('b')) === :fallthrough
    end
end

@testset "Phase 2b — keymap table" begin
    @testset "key_token normalizes chars, symbols, ctrl-combos" begin
        @test FS.key_token(KEY('a')) == 'a'
        @test FS.key_token(KEY(:enter)) == :enter
        @test FS.key_token(KEY(:ctrl, 'l')) == (:ctrl, 'l')
    end

    @testset "lookup_action resolves per-context and walks the stack" begin
        @test FS.lookup_action(:global, KEY('q')) == :quit
        @test FS.lookup_action(:global, KEY('?')) == :toggle_help
        @test FS.lookup_action(:global, KEY(:ctrl, 'l')) == :logout
        @test FS.lookup_action(:login, KEY(:enter)) == :login_submit
        @test FS.lookup_action(:login, KEY('c')) == :login_to_create
        @test FS.lookup_action(:login_create, KEY(:escape)) == :login_to_signin
        @test FS.lookup_action(:help, KEY(:escape)) == :close_help
        # unknown → nothing
        @test FS.lookup_action(:global, KEY('z')) === nothing
        # stack: board falls through to global
        @test FS.lookup_action(Symbol[:board, :global], KEY('B')) == :view_board
        @test FS.lookup_action(Symbol[:board, :global], KEY('q')) == :quit
        @test FS.lookup_action(Symbol[:board, :global], KEY('z')) === nothing
    end

    @testset "help + status hints are generated from the table" begin
        hl = FS.help_lines([:global])
        @test any(occursin("Quit", l) for l in hl)
        @test any(occursin("Board", l) for l in hl)
        hints = FS.status_hints([:board, :global])
        @test occursin("[q] Quit", hints)
        @test occursin("[?] Help", hints)
        @test occursin("[^L] Log out", hints)
        # hint=false bindings (^C) are omitted from the status bar
        @test !occursin("^C", hints)
    end
end
