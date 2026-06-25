# 3-Lens Review Summary

**SECURITY**: NO FINDINGS. Clean, no IO, no eval, cmd parser strict whitelist, pure in-mem.

**CORRECTNESS**:
Critical:
- Key routing: hotkeys (space r p a j k arrows) before handle_key!(input) → chars like 'p' for "pulse" stolen, can't type most cmds interactively (tests bypass with set_text!)
  Evidence verbatim src/cyberdeck.jl:69 `if evt.key == :char c==' ' ... return; elseif ... 'p' ... ; end ; if handle_key!(m.input, evt) return`

- randn() unqualified: crashes on step!/running view (UndefVarError)
  src/cyberdeck.jl:352 `... + 0.05 * randn() ...`

Warnings:
- View does mutations (tick + step!) — follows Tachikoma demos but conflicts AGENTS "mutations only in update!"
- Small area guard (w<20 h<8) but fixed layout rows sum 17; sub-rects not fully guarded (e.g. title +5)
- `paused` field dead: never set true, only running used
- Some test asserts loose (`|| true`)

**CONVENTIONS**:
Good on structure, @tachikoma_app, widgets/layouts, TestBackend, 4-space.
Mismatches:
- view mutates
- tests do direct m.quit=true ; reset! direct calls
- println in runtests.jl

Verdict: changes-requested. Fix criticals (routing + randn). Nits optional.

Next: fix loop with coder.
