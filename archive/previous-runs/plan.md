# Implementation Plan: Add Small Quantum Viz Using Real Aggregates to the AI Metrics Dashboard

### Overview & Scope
Add a **small, focused** Canvas-based "quantum" visualization (pulsing grid + arcs + fbm/noise-driven points, tick-animated) to the existing Unit-6 viz area in the left 35% split ("TREND" spot) of `list_area`.

- **Use *real* data only**: `m.hehs_trend::Vector{Float64}` (populated by `compute_dashboard_aggregates` from credited `hehsSaved` values + `sessions_data` / aggregates). Derive modulation (density, arc scale/radius, pulse strength/variation, grid step) from `mean`, `max`, `length`, and `tick`.
- **Quantum effect**: Directly adapted from proven patterns in `cyberdeck.jl` (create/clear/set_point/arc/fbm/noise/pulse + tick-driven).
- **Theme**: QCI cyan (via `QCI_CYAN` + `Style`).
- **Integration**: Inside the existing `viz_list = split_layout(Layout(Horizontal, [Percent(35), Fill()]), list_area)` block. Replace the Sparkline (optional per requirements; replacement keeps unit small). Add "QUANTUM" label (or "Q") + canvas. Preserve full layout contract, small-terminal guards, and fallback paths.
- **Constraints** (per AGENTS.md + exploration):
  - Elm/Tachikoma: `mutable struct`, `update!(m, KeyEvent)`, `view(m, Frame)` only. **Mutations ONLY in `update!`** (tick already correctly advanced only at end of `update!`; view must remain pure render).
  - Always invoke with `julia --project=.`.
  - **UI/visual change = mandatory TestBackend coverage** (render + `find_text`/`row_text`/`char_at` + `update!` + re-render; see Phase5 patterns).
  - Small unit (no refactor). 4-space indent, `split_layout`/`Block`/`Style`/`Rect`/`QCI_CYAN` patterns, existing guards.
  - Use existing `hehs_trend` (no model changes needed). Fallbacks for empty/zero data, tiny areas.
  - No view-side `tick += 1`, no new deps, no changes outside the two files below.

This fulfills the exact request from `ai-metrics-data-layer-findings.md` (next-slice quantum viz) while preserving the data layer (Phase 1-4 pures + `load_data!` + aggregates).

### Key Design Decisions & Trade-offs
- **Replace vs. augment Sparkline**: Replace (smallest delta; keeps 35% slot focused on quantum; "TREND" label becomes "QUANTUM" to reflect new viz). Sparkline was the only consumer of the left slot.
- **Modulation approach**: Stats from `hehs_trend` (avg for density/pulse, max for arc radius, length for variation). Tick for animation. Keeps effect visible even on low/zero data (light pulsing grid). Manual avg (no `Statistics` dep).
- **Canvas sizing/guards**: `viz_area` sub-guard `height >= 3 && width >= 8` (tighter than spark's 6; braille needs space). Outer list_area + app guards unchanged.
- **Canvas rendering**: Use `render_canvas(c, subrect, f)` (matches cyberdeck exactly; passes `Frame`).
- **Style**: `Style(; fg = QCI_CYAN)` (matches dashboard's QCI usage; `tstyle` only used once for dim fallback).
- **Tick contract**: Relies on existing `m.tick += 1` at end of `update!` (after 'r', nav, etc.). Animation advances on real interactions; tests drive it explicitly.
- **Fallbacks**: Empty trend → low-density static-ish quantum field; tiny terminal → skip (existing paths); `load_data!` already provides real or dummy trend.
- **Test strategy priority**: Data-driven TestBackend (mktemp + credited fixture → `load_data!` → `view` → asserts + `update!` + re-render). Mirrors Phase5 exactly. Direct tests optional (none planned).

**Follows token-efficiency.md**: Small scope, targeted changes, tight tests, plan will drive concise subagent context.

### Phase 1: Implement Quantum Canvas in `view` (Core Logic)
**File**: `src/ai_metrics_dashboard.jl`

**Actions (exact locations)**:
- Update Unit-6 comment (around line 718).
- In the `if list_area.height >= 3 && list_area.width >= 20` block, inside `viz_list = split_layout(Layout(Horizontal, [Percent(35), Fill()]), ...)`:
  - Replace the `# Sparkline for recent HEHS trend...` + `render(Sparkline...` block (lines ~725-730) with quantum canvas equivalent.
  - Use this structure (keep surrounding `viz_area = viz_list[1]` + right-side list unchanged):
    ```julia
    if viz_area.height >= 3 && viz_area.width >= 8
        set_string!(buf, viz_area.x, viz_area.y, "QUANTUM", Style(; fg=QCI_CYAN, bold=true))
        ca = Rect(viz_area.x, viz_area.y + 1, viz_area.width, viz_area.height - 1)
        if ca.height >= 2 && ca.width >= 6
            c = create_canvas(ca.width, ca.height; style=Style(; fg=QCI_CYAN))
            dw, dh = canvas_dot_size(c)
            clear!(c)

            # compute real-data modulators (no mutation)
            n = length(m.hehs_trend)
            avg = n > 0 ? sum(m.hehs_trend) / n : 0.0
            mx = n > 0 ? maximum(m.hehs_trend) : 0.0

            # Pulsing grid (tick + light avg modulation)
            gp = pulse(m.tick; period=18, lo=0.6, hi=1.0)
            gstep = max(2, round(Int, 5 - clamp(avg, 0.0, 2.0)))
            for x in 0:gstep:dw-1, y in 0:2:dh-1; set_point!(c, x, y); end
            for y in 0:gstep:dh-1, x in 0:3:dw-1; set_point!(c, x, y); end

            # Arcs (modulated radius/ count by mx + tick)
            cx, cy = dw ÷ 2, dh ÷ 2
            n_arcs = 1 + (mx > 0.5 ? 1 : 0)
            for i in 1:n_arcs
                r = max(2, round(Int, min(dw, dh) * (0.18 + 0.1*i + 0.02*mx) + 0.5*sin(m.tick/11.0 + i)))
                arc!(c, cx + (i-1)*1, cy-1, r, 25.0 + i*7, 155.0 - i*4)
            end

            # fbm/noise points (density from avg + tick)
            dens = 0.10 + clamp(avg * 0.04, 0.0, 0.09)
            for x in 0:2:dw-1, y in 0:1:dh-1
                if fbm(x*0.09 + m.tick*0.007, y*0.11 + m.tick*0.004; octaves=2) > (0.72 - dens)
                    set_point!(c, x, y)
                end
                if noise(x*0.17 + m.tick*0.013, y*0.19) > 0.85
                    set_point!(c, x+1, y)
                end
            end
            render_canvas(c, ca, f)
        end
    end
    ```
- Preserve outer guards, `else` fallback list path, and all other code.
- Style/indent exactly as surrounding (4 spaces).
- Update comment: `# Unit-6: quantum Canvas viz (pulsing grid/arcs/fbm+noise) using real hehs_trend aggregates + tick (QCI cyan)`
- Ensure `hehs_trend` usage works for both dummy and real `load_data!` paths (already does).

**No other changes** in this file (model, `update!`, `load_data!`, computes, small-terminal guard, etc. untouched).

**Validation in phase**: `julia --project=.` + targeted test later.

### Phase 2: Mandatory TestBackend Coverage + Extension
**File**: `test/test_ai_metrics_dashboard.jl`

**Actions**:
- Extend/rename the existing unit-6 viz test (around line 138):
  - Rename to `@testset "Viz Quantum Canvas (unit-6)" begin`
  - After `T.update!(m, T.KeyEvent('r'))` (or use fixture), render, assert:
    - `T.find_text(tb, "QUANTUM") !== nothing`
    - Canvas indicator: non-ascii braille or non-space unicode in viz rows (e.g. `row = T.row_text(tb, 5); any(c -> c != ' ' && !isascii(c), collect(row))` — mirrors cyberdeck test style).
- Add/expand inside the **Phase5 "TestBackend real data-driven views"** block (preferred for "real aggregates" requirement, ~lines 640+):
  - New or extended `@testset` using `mktempdir` + credited `data.json` fixture (multiple sessions with positive `hehsManual`/`hehsActual` to produce non-trivial `hehs_trend` e.g. containing 3.5/2.0/etc., matching existing Phase5 fixtures) + optional logs.
  - `load_data!(m; data_path=..., logs_path=...)`
  - `T.view(...)`
  - Tight asserts: `"QUANTUM"`, presence of loaded data strings (e.g. "3.5", "hehs=..."), + braille/non-ascii in the left viz column rows.
  - Then: `T.update!(m, T.KeyEvent('j'))` (or `'r'`), reset buffer, new `Frame` + `view`, re-assert label + canvas indicators + data still present.
- Follow exact Phase5 pattern: `TestBackend(w,h)`, `reset!`, `Frame`, `view`, `find_text`/`row_text`, `update!` + re-render.
- Update any incidental "TREND" or "Sparkline" references in comments/asserts that would break.
- Keep all prior Phase1-4 + Phase5 tests (they continue to pass; quantum is additive in the viz slot).
- Direct/pure tests optional (skip for minimality).

**Run command for this phase**: `julia --project=. test/runtests.jl` (or full Pkg.test).

### Phase 3: Validation, Evidence & Polish
- Execute (always with project):
  - `julia --project=. -e 'using Pkg; Pkg.test()'`
  - `julia --project=. test/runtests.jl`
- Verify:
  - New/extended tests pass with real fixture data.
  - Small terminal paths (TestBackend 10x4, 20x6 etc.) still work.
  - Re-render after `update!` shows evolving quantum effect (via tick).
  - No mutations in view (code review + run).
  - "QUANTUM" + canvas braille visible on reasonable sizes (60-90w); list nav etc. unaffected.
- Produce concise artifacts per `.grok/docs/token-efficiency.md` (phase summary, `validation-evidence.md` updates if needed).
- Optional live smoke (non-CI): `julia --project=. -e 'using TachikomaUITest; TachikomaUITest.run_ai_metrics_dashboard()'` (press keys to tick).
- Fix only within scope if issues surface (e.g. adjust canvas min size).

### Risks & Mitigations
- **Layout shifts / narrow 35% slot**: Canvas braille can be dense; `Percent(35)` on ~60-col terminal yields ~21 cells (sub-area ~7+). Mitigation: explicit `>=8`/`>=6` guards + test at 70-90 width; fallback to label-only inside viz_area.
- **Small terminal**: Existing outer guard (`<20x6`) + inner viz skip. Canvas never rendered in guard paths.
- **Tick dependency / animation in tests**: Viz is static without `update!`. Mitigation: All TestBackend tests explicitly call `update!` ( 'r'/'j') + re-render (already required by AGENTS + Phase5).
- **Data range / empty trend**: `hehs_trend` can be `[0.0]` or small floats. Mitigation: clamps + fallbacks to visible (but calm) pulsing grid.
- **Canvas unicode in TestBackend / headless**: Relies on braille output. Mitigation: copy proven check (`any non-ascii non-space`) from `test_cyberdeck.jl`; `find_text` on label is robust.
- **Style/availability of Canvas fns**: `create_canvas` etc. available via `using Tachikoma` + `@tachikoma_app` (proven in cyberdeck). Use `Style` (consistent with QCI code).
- **Tick contract violation**: Strictly avoid any `m.tick` mutation or other state change in `view`.
- **Future data changes**: `hehs_trend` capped at ~6 in aggregator; plan tolerates any length.
- **No breaking of existing**: Right-hand SESSIONS list, KPIs, status, 'r' load, nav, small guards, Phase1-5 tests all preserved.

**Out of scope**: New pure helpers, model fields, full theme, larger refactor, cyberdeck changes, live recording, property tests, other dashboards.

### Sequencing & Coder Instructions
1. Read AGENTS.md (Julia rules + TestBackend mandatory) + token-efficiency.md + target sections of `src/ai_metrics_dashboard.jl` (model/update!/load/view ~715) + cyberdeck Canvas examples + test Phase5 patterns.
2. Implement **Phase 1** (src change only). Provide before/after for the viz block.
3. Implement **Phase 2** (test extension).
4. Run validation commands yourself (`julia --project=. ...`); capture concise evidence.
5. Use `todo_write` for tracking.
6. End with "Implementation Complete" + files touched + links to evidence.
7. Follow minimal context: reference this plan + phase summaries.

After changes, lead will summarize phases per token-efficiency rules.

This is a high-signal, low-risk, repeatable addition leveraging existing real aggregates + proven Canvas + TestBackend.

### Critical Files for Implementation
- `src/ai_metrics_dashboard.jl` - Core logic to modify (Unit-6 viz block in `view`; uses `hehs_trend`, `tick`, `QCI_CYAN`; must preserve `update!` contract)
- `test/test_ai_metrics_dashboard.jl` - Interfaces/tests to implement (extend Phase5 + unit-6 with mktemp fixtures, `load_data!`, `TestBackend` render/find_text/row_text + update!+re-render)
- `src/cyberdeck.jl` - Pattern to follow (Canvas construction, pulsing grid/arcs/fbm/noise, `render_canvas(..., f)`, tick-driven effects, braille checks in tests)
- `test/test_ai_metrics_dashboard.jl` (Phase5 slice) - Reference for exact data-driven TestBackend style with credited fixtures
- `src/ai_metrics_dashboard.jl` (model + `compute_dashboard_aggregates` + `load_data!` sections) - Source of real `hehs_trend` data (read-only reference for modulation)
