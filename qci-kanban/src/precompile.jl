# ═══════════════════════════════════════════════════════════════════════════
# src/precompile.jl — PrecompileTools workload (TTFX fix).
#
# Drives the same headless tour as `record_demo2` (login gate → create account
# → board → swimlanes → card detail + comment → stats → edit → project switcher
# → calendar → backlog → start sprint → gantt → soft refresh R → board → help)
# plus a short v1 pass, all against a TestBackend with `:memory:` stores and a
# throwaway token path. Running it at precompile time caches the native code for
# the ctor/`update!`/`view` paths in the pkgimage, so `kanban2()` reaches an
# interactive board in ~1s instead of ~20s of first-call JIT.
#
# Keep in sync with packaging/precompile_app.jl v2 tour (and vice versa).
# TODO: extract shared _v2_headless_tour! later (small follow-up PR).
#
# COV_EXCL_START — precompile-time-only code: the `@compile_workload` body runs
# during `Pkg.precompile`, never at runtime, so no coverage run can observe it
# executing. Any breakage fails package precompilation (and thus the suite)
# loudly. See COVERAGE.md.
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    _pc_type_keys!(m, s) = foreach(ch -> Tachikoma.update!(m, Tachikoma.KeyEvent(ch)), collect(s))

    @compile_workload begin
        tb = Tachikoma.TestBackend(120, 35)
        _pc_render!(m) = begin
            Tachikoma.reset!(tb.buf)
            Tachikoma.view(m, Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, tb.width, tb.height),
                                              Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]))
        end

        # ── v2 tour (mirrors record_demo2) ──────────────────────────────────
        m = AppModel(; user_db = ":memory:", board_db = ":memory:",
                     token_path = tempname(), secret = "precompile-secret",
                     restore = false)
        _pc_render!(m)                                   # first-run login screen
        Tachikoma.update!(m, Tachikoma.KeyEvent('c'))    # create account
        _pc_type_keys!(m, "pc@qci.com")
        Tachikoma.update!(m, Tachikoma.KeyEvent(:tab))
        _pc_type_keys!(m, "Precompile User")
        Tachikoma.update!(m, Tachikoma.KeyEvent(:tab))
        _pc_type_keys!(m, "password")
        Tachikoma.update!(m, Tachikoma.KeyEvent(:enter)) # create + sign in → board
        _pc_render!(m)
        for k in ('l', 'j', 'k', 'h')                    # board navigation
            Tachikoma.update!(m, Tachikoma.KeyEvent(k)); _pc_render!(m)
        end
        Tachikoma.update!(m, Tachikoma.KeyEvent('s')); _pc_render!(m)  # swimlane → assignee
        Tachikoma.update!(m, Tachikoma.KeyEvent('s')); _pc_render!(m)  # swimlane → epic
        Tachikoma.update!(m, Tachikoma.KeyEvent('v')); _pc_render!(m)  # card detail modal
        _pc_type_keys!(m, "LGTM")                                      # comment box
        Tachikoma.update!(m, Tachikoma.KeyEvent(:enter)); _pc_render!(m)
        Tachikoma.update!(m, Tachikoma.KeyEvent(:escape)); _pc_render!(m)
        Tachikoma.update!(m, Tachikoma.KeyEvent('t')); _pc_render!(m)  # stats strip
        Tachikoma.update!(m, Tachikoma.KeyEvent('e')); _pc_render!(m)  # edit card
        Tachikoma.update!(m, Tachikoma.KeyEvent(:escape)); _pc_render!(m)
        Tachikoma.update!(m, Tachikoma.KeyEvent('P')); _pc_render!(m)  # project switcher
        Tachikoma.update!(m, Tachikoma.KeyEvent(:escape)); _pc_render!(m)
        Tachikoma.update!(m, Tachikoma.KeyEvent('C')); _pc_render!(m)  # calendar view
        Tachikoma.update!(m, Tachikoma.KeyEvent('l')); _pc_render!(m)  # next month
        Tachikoma.update!(m, Tachikoma.KeyEvent('e')); _pc_render!(m)  # cal edit
        Tachikoma.update!(m, Tachikoma.KeyEvent(:escape)); _pc_render!(m)
        Tachikoma.update!(m, Tachikoma.KeyEvent('K')); _pc_render!(m)  # backlog view
        Tachikoma.update!(m, Tachikoma.KeyEvent('S')); _pc_render!(m)  # start sprint
        Tachikoma.update!(m, Tachikoma.KeyEvent('G')); _pc_render!(m)  # gantt view
        Tachikoma.update!(m, Tachikoma.KeyEvent('e')); _pc_render!(m)  # gantt edit
        Tachikoma.update!(m, Tachikoma.KeyEvent(:escape)); _pc_render!(m)
        Tachikoma.update!(m, Tachikoma.KeyEvent('R')); _pc_render!(m)  # soft refresh
        Tachikoma.update!(m, Tachikoma.KeyEvent('B')); _pc_render!(m)  # back to board
        Tachikoma.update!(m, Tachikoma.KeyEvent('?')); _pc_render!(m)  # help overlay
        Tachikoma.update!(m, Tachikoma.KeyEvent(:escape)); _pc_render!(m)

        # ── v1 pass (kanban() login gate + board) ───────────────────────────
        m1 = KanbanModel()
        m1.db_path = ":memory:"
        load_users!(m1)
        _pc_render!(m1)                                  # zero-users first-run screen
        Tachikoma.update!(m1, Tachikoma.KeyEvent('c'))
        _pc_type_keys!(m1, "PrecompileUser")
        Tachikoma.update!(m1, Tachikoma.KeyEvent(:enter))
        _pc_render!(m1)                                  # v1 board
        for k in ('l', 'j', 'c', 'b')                    # nav + calendar + back
            Tachikoma.update!(m1, Tachikoma.KeyEvent(k)); _pc_render!(m1)
        end
    end
end
# COV_EXCL_STOP
