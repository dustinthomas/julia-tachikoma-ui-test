# Scout Report: Add Small Quantum Viz Using Real Aggregates (Unit-6 left 35% slot)

**Scope reminder (from plan + AGENTS)**: Small focused addition. Replace Sparkline in existing `viz_list = split_layout(...)` inside `list_area` (TREND → QUANTUM label + Canvas). **Only real aggregates via `m.hehs_trend`** (no model changes, no new fields). Tick-driven pulsing grid + arcs + fbm/noise points (adapted from cyberdeck). QCI_CYAN + `Style`. Pure `view` (mutations *only* in `update!`). Mandatory TestBackend coverage (render + `find_text`/`row_text`/`char_at` + `update!` + re-render). 4-space indent. No new deps. Use existing guards/fallbacks. Always `julia --project=.`. Follows Elm/Tachikoma: `mutable struct <: Model`, `update!(m, KeyEvent)`, `view(m, Frame)`.

All exploration used read-only tools. Report quotes verbatim + exact `file:line` from current state.

### 1. AGENTS.md (Julia + Tachikoma + TestBackend Rules)
Key verbatim:
- "Always invoke Julia with `julia --project=.`."
- "**UI changes require TestBackend coverage** (see https://kahliburke.github.io/Tachikoma.jl/dev/testing). Validator will execute render + char_at / find_text / row_text / handle_key! + re-render checks."
- "Tachikoma apps follow Elm: `mutable struct X <: Model`, `should_quit`, `update!(m, KeyEvent)`, `view(m, Frame)`. Use `@tachikoma_app`."
- "Mutations ONLY in `update!` (tick already correctly advanced only at end of `update!`; view must remain pure render)."

### 2. plan.md (Full Scope + Exact Phase 1 Code Sketch)
Core: use `m.hehs_trend`, adapt cyberdeck Canvas, replace in 35% slot, "QUANTUM" label + canvas, mandatory TB tests with real fixtures.

**Exact Phase 1 sketch** (from plan):
```julia
if viz_area.height >= 3 && viz_area.width >= 8
    set_string!(buf, viz_area.x, viz_area.y, "QUANTUM", Style(; fg=QCI_CYAN, bold=true))
    ca = Rect(viz_area.x, viz_area.y + 1, viz_area.width, viz_area.height - 1)
    if ca.height >= 2 && ca.width >= 6
        c = create_canvas(ca.width, ca.height; style=Style(; fg=QCI_CYAN))
        dw, dh = canvas_dot_size(c)
        clear!(c)
        # modulators from hehs_trend
        n = length(m.hehs_trend)
        avg = n > 0 ? sum(m.hehs_trend) / n : 0.0
        mx = n > 0 ? maximum(m.hehs_trend) : 0.0
        # pulsing grid, arcs, fbm/noise (see full in plan.md)
        render_canvas(c, ca, f)
    end
end
```
Update comment to quantum. Right list + fallbacks untouched.

### 3. src/ai_metrics_dashboard.jl (Key excerpts + lines)
- hehs_trend in model: line 552 (default [1.2,...]), 538 struct
- compute... : line 475 sig, ~494 push eff.hehsSaved into trend, cap 6
- load_data!: 583 m.hehs_trend = agg..., 622
- Current viz (replace target): lines 718-739 exactly (Sparkline block under if list_area... viz_list Percent(35))
  ```julia
  # Unit-6: small viz row (Sparkline HEHS trend + Bar stub) split inside list area
  if list_area.height >= 3 && list_area.width >= 20
      viz_list = split_layout(Layout(Horizontal, [Percent(35), Fill()]), list_area)
      ...
      if viz_area.height >= 2 && viz_area.width >= 6
          set_string!(buf, viz_area.x, viz_area.y, "TREND", Style(; fg=QCI_CYAN, bold=true))
          render(Sparkline(m.hehs_trend; ...), Rect(...), buf)
      end
      ... list_sub right ...
  ```
- QCI: const line 14
- view: 658 buf=f.buffer, 663 small guard <20x6
- update tick: 634-648 (load on r; tick +=1 at end; no view mutation)
- Data flow: aggregates → load_data! → m.hehs_trend → pure read in view

### 4. src/cyberdeck.jl (Canvas patterns, exact signatures)
Core canvas block ~216-260 (pulsing grid with gp=pulse(tick), gstep, arcs with sin(tick), dens + fbm/noise + tick points, render_canvas(c, area, f))

Signatures:
- create_canvas(w, h; style=...)
- dw,dh = canvas_dot_size(c)
- clear!(c)
- set_point!(c, x, y)
- arc!(c, cx, cy, r, start, end; steps=...)
- render_canvas(c, rect, f)
- pulse(tick; period=18, lo=0.6, hi=1.0)
- fbm(x,y; octaves=2), noise(x,y)

Used inside split viz, tick + data modulate.

### 5. test/test_ai_metrics_dashboard.jl (Test patterns)
- Old unit-6: ~138 (update 'r', TestBackend(80,12), view, find "TREND" || spark chars)
- Phase5 real data pattern (preferred): mktemp credited fixture (hehs 5.0/1.5 → 3.5), load_data!(; paths), TestBackend(90,16), reset, Frame, view, find_text("3.5" etc), row_text, then update('j'), re-view + re-assert. See ~640+
- Rename unit-6 + extend Phase5 for QUANTUM + braille.

### 6. test/test_cyberdeck.jl (Braille checks)
`any(c -> c != ' ' && !isascii(c), collect(mid_row)) || find_text(...)`

All patterns use reset + Frame + view + update! + re-render.

**Data flow summary**: real hehs_trend from compute (eff.hehsSaved) → model via load → view (read avg/max + tick for anim). Always valid vector.

**Coder ready**: follow plan sketch + these exact snippets/lines. Match 4-space, QCI_CYAN Style, guards. Add TB with real fixture for aggregates.