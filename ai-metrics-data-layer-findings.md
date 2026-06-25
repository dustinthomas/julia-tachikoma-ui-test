# AI Metrics Dashboard - Data Layer: Review Findings & Next Steps

**Date:** 2026-06-24 (pipeline run)
**Context:** /pipeline on "real data layer (data.json + jsonl parser + wiring) in the agreed order (data ops first), small testable units"

**Status after pipeline:** Changes-requested. Data layer (Phases 1-4) implemented and validated green (178/178 in AiMetrics suite on full `julia --project=. -e 'using Pkg; Pkg.test()'`). Real `~/.grok/logs/unified.jsonl` now drives sessions. But reviews identified issues.

## 1. SECURITY Lens
**Verdict:** NO FINDINGS

- All data ops are read-only on user-owned paths (`~/.ai-metrics/data.json`, `~/.grok/logs/unified.jsonl`).
- Defensive `try/catch`, `get(..., default)`, per-line JSON parse skipping.
- No writes, no external processes, no secrets, no injection.
- Tests use only `mktempdir()` fixtures (never real `~` paths).
- Matches plan intent ("safe read ... defaults on missing/malformed").

No action required.

## 2. CORRECTNESS Lens (Critical Issues)
**Verdict:** Strong on pure data logic / TS fidelity / fallbacks / edges, but **critical** and **warning** issues.

### Critical
- **Mutation outside `update!` (AGENTS.md violation + plan)**  
  `src/ai_metrics_dashboard.jl:665`
  ```julia
  function view(m::AiMetricsDashboard, f::Frame)
      ...
      if small guard ...
      end
      m.tick += 1   # <--- MUTATES MODEL IN VIEW
      ...
  ```
  - Affects every render (including TestBackend).
  - Tick also influences `last_ingested` string.
  - Conflicts with "mutations only in update!" and prior cyberdeck review.

- **Missing explicit exports for new data types** (plan.md requirement)  
  `src/TachikomaUITest.jl:17` only exports the model + runners.  
  New pure types (`TokenBreakdown`, `GrokSessionUsage`, `Attribution`, `MetricsConfig`, `StoredData`) and functions (`load_stored_data`, `parse_grok_unified_jsonl`, `compute_*`, `filter_quality_for_credit`) are not exported. Tests rely on qualified access.

### Warnings / Gaps
- **Incomplete TestBackend coverage for *real loaded data* effects** (plan Phase 5 + "mandatory TestBackend for every data effect")  
  Direct tests are excellent (mktemp fixtures, `load_data!` with real numbers, `update!('r')`).  
  But rendered UI (gauges, list, status, subtitle) from *actual* loaded/aggregated values (e.g. "3.5", "hehs=3.5", fixture sids, real timestamps) is only loosely asserted:
  ```julia
  @test T.find_text(tb, "HEHS") !== nothing
  @test T.find_text(tb, "EFF") !== nothing || T.find_text(tb, "10.0") !== nothing
  @test T.find_text(tb, "loaded") !== nothing || T.find_text(tb, "GROK") !== nothing
  ```
  No specific post-`load_data!` + re-render checks for computed strings in gauges/list/status.

- Minor: Some early tests still have `|| true` guards (e.g. `char_at != '\0' || true`).

## 3. CONVENTIONS Lens
**Verdict:** REQUEST CHANGES (overlaps heavily with correctness).

- View mutation (see above).
- Direct mutations in tests (`m.quit = true`, direct `reset!` calls) instead of only `update!`.
- `println` side-effect at load:
  `test/runtests.jl:15`
  ```julia
  println("All test suites loaded for julia-tachikoma-ui-test.")
  ```
- `@tachikoma_app` inconsistency (ai file declares it; cyberdeck does not).
- Plan fidelity gaps:
  - Exports section in plan.md not followed.
  - Phase 5 coverage not structured as a dedicated slice.
  - Loose TestBackend asserts.
- Positive: pure-first, small slices, mktemp hygiene, widgets/layouts, `julia --project=.` usage, 4-space.

## Actionable Fixes (prioritized for small units)

**Priority 1 (Critical - do first)**
1. Move tick increment (and any animation driver) exclusively into `update!`.
   - Example: increment on 'r' or introduce a lightweight tick event.
   - Remove `m.tick += 1` from `view`.
   - Update any tests that rely on tick side-effects during render.

2. Add exports in `src/TachikomaUITest.jl`:
   ```julia
   export TokenBreakdown, GrokSessionUsage, Attribution, MetricsConfig, StoredData
   export load_stored_data, parse_grok_unified_jsonl, compute_efficiency, compute_dashboard_aggregates, filter_quality_for_credit
   ```

**Priority 2 (Coverage & Hygiene)**
3. Add/expand explicit Phase 5 @testset(s) (or new slice):
   - Use mktemp fixtures with known credited data.
   - `load_data!(m; data_path=..., logs_path=...)`
   - `T.update!(m, T.KeyEvent('r'))` or direct call
   - Re-render via `Frame` + `view`
   - Tight asserts:
     - `find_text` / `row_text` for exact numbers like "3.5", "612", "hehs=3.5"
     - Specific session strings from fixture
     - `last_ingested` value
     - Gauge labels + values in status

4. Tighten existing loose guards (replace `|| true` patterns with real checks or remove).

5. Remove or guard the `println` in `test/runtests.jl`.

6. Make `cyberdeck.jl` consistent (`@tachikoma_app` + `using Tachikoma` at top) for future hygiene.

**Priority 3 (Next Features)**
- Full Phase 5 polish + any missing TestBackend for data-driven views.
- Add a small Canvas "quantum" effect or real BarChart using the new aggregates.
- Optional: make `load_data!` accept real paths by default in the runner, with a visible "source: real logs" indicator.
- Later: interactive tagging (TextInput + enter to set attributions), config editing, export.

## Evidence References
- Full pipeline artifacts: `plan.md`, `scout-report.md`, `scout-summary.md`, `plan-summary.md`
- Review outputs (from the three parallel reviewers): SECURITY (NO FINDINGS), CORRECTNESS (detailed issues), CONVENTIONS (request changes)
- Validation: multiple `julia --project=. -e 'using Pkg; Pkg.test()'` (178 passes post-Phase 4)
- Current source state captured in the reviews above.

## Suggested Next Pipeline / Work
1. Small unit fix for tick mutation + exports.
2. Small unit: tighten + add dedicated data-driven TestBackend tests.
3. Then: `/pipeline` for next slice (e.g. "add Canvas quantum viz using real aggregates" or "interactive attribution tagging").

This file serves as the hand-off / context clear for the data layer work. All major findings from the pipeline reviews are captured here for future fixes.

**Ready to clear context and move on.**
