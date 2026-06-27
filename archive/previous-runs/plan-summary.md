# Plan Summary: Add Small Quantum Viz Using Real Aggregates

**Task**: /pipeline "add small quantum viz using real aggregates"

**What phases achieve**:
- Replace Sparkline TREND slot (left 35% of list_area) with small Canvas quantum effect (pulsing grid + arcs + fbm/noise points) driven purely by existing real `m.hehs_trend` (from aggregates) + `tick`.
- QCI cyan theme. Modulate density/radius/pulse from trend avg/max.
- Zero model changes. Tick contract respected (advance only in update!).
- Small delta, preserve all guards, fallback, right-side list, KPIs, status.

**Key files**:
- src/ai_metrics_dashboard.jl (Unit-6 view block only)
- test/test_ai_metrics_dashboard.jl (extend unit-6 + Phase5 data-driven TestBackend)

**Approach**: Direct port/adapt of cyberdeck Canvas patterns. Replace viz content for smallest scope.

**Testing strategy** (mandatory per AGENTS):
- TestBackend render + find_text("QUANTUM") + braille/non-ascii row checks.
- Data-driven: mktemp credited fixture → load_data! (real hehs_trend e.g. 3.5 values) → view + update!('j' or 'r') + re-render.
- Small terminal + empty data paths.
- Full `julia --project=. -e 'using Pkg; Pkg.test()'`

**Risks**:
- Layout on narrow terminals (mit: guards + 70w+ tests)
- Static without update! (mit: all TB tests drive keys + re-render)
- Unicode in headless (mit: proven checks)

**Status**: Plan complete. Next: Scout for exact patterns/file:line. Then impl loop.

Artifacts: plan.md (detailed), this summary. Use for coder/scout prompts.