# packaging/precompile_app.jl — free-standing PackageCompiler precompile_execution_file.
#
# Traced during create_app into the app sysimage. Not the same as
# src/precompile.jl (PrecompileTools @compile_workload for pkgimages).
#
# Keep in sync with the v2 tour in src/precompile.jl (and vice versa).
# TODO: extract shared _v2_headless_tour! later (small follow-up PR).
#
# Forbidden: kanban2(), kanban(), or Tachikoma app(m) — would hang the build.
# Isolation: :memory: DBs, token_path=tempname(), injected secret, restore=false.

using QciKanban
using Tachikoma

_pc_type_keys!(m, s) = foreach(ch -> Tachikoma.update!(m, Tachikoma.KeyEvent(ch)), collect(s))

tb = Tachikoma.TestBackend(120, 35)
_pc_render!(m) = begin
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(m, Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, tb.width, tb.height),
                                      Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]))
end

# ── v2 tour (mirrors src/precompile.jl / record_demo2; binary ships v2 only) ─
m = QciKanban.AppModel(; user_db = ":memory:", board_db = ":memory:",
                       token_path = tempname(),
                       secret = "precompile-app-secret-packagecompiler!!",
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
