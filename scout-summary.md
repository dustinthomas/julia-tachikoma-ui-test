# Scout Summary: Quantum Viz (real aggregates)

**Key patterns (file:line + snippet)**:
- AGENTS: julia --project=., TestBackend mandatory for UI (render/find_text/row_text + update! + re-render), mutations ONLY update!, Elm model/view. (AGENTS.md)
- plan sketch: replace Sparkline in viz_list[Percent(35)], "QUANTUM" + create_canvas using m.hehs_trend avg/mx + tick (pulse/fbm/noise/arc/set_point), render_canvas(..., f). QCI_CYAN Style. (plan.md)
- Current viz target: ai_metrics_dashboard.jl:718 (if list_area >=3x20, viz_list split, set "TREND", render Sparkline(m.hehs_trend), right list_sub)
- hehs_trend source: ai_metrics_dashboard.jl:552 (model), ~494 (push eff.hehsSaved in compute), 622 (m.hehs_trend=agg in load)
- update tick: 634 (load on 'r'; tick+=1 end of update; no view mut)
- Canvas patterns: cyberdeck.jl:216 (create_canvas(w,h;style), dw=canvas_dot_size, clear, set_point, arc, fbm+noise+tick points, pulsing gp=pulse, render_canvas(c,area,f) ). pulse/fbm/noise sigs exact.
- QCI: ai_metrics_dashboard.jl:14 (QCI_CYAN), Style(;fg=QCI_CYAN,bold=true)
- Tests: test_ai_metrics_dashboard.jl ~138 (update'r', TB(80,12), view, find TREND || chars); Phase5 ~640 (mktemp credited fixture → load_data! paths → TB(90,16) → view + find "3.5" + re-update 'j' + re-view)
- Canvas TB check: test_cyberdeck.jl ~165 (any !isascii non-space in row_text)

**Data flow**: compute_dashboard_aggregates (real credited hehs) → load_data! (or dummy) → m.hehs_trend → pure view read (avg/max + tick anim)
**Conventions**: 4-space, split_layout + guards (>=3x8 for canvas), no view state, preserve right list/fallbacks, exact Phase5 TB style for real aggregates.

Ready for coder. Use plan + these highlights.