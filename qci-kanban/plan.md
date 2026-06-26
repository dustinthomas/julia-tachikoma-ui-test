# Plan: QciKanban — Secondary Color Visibility Fix (unselected list items invisible on black bg)

Task: unselected list items use QCI_NAVY (secondary). Invisible on black terminal. Fix contrast for board cards, user picker, calendar dues, empties, stubs. Preserve QCI branding.

## Key Decisions (from planner)
- Add `QCI_SECONDARY = ColorRGB(100,110,165)` (lighter navy-blue for contrast on black).
- Export it.
- Use `QCI_SECONDARY` (or +dim) for all *text* unselected/secondary.
- Keep original `QCI_NAVY` for subtle borders (unsel column headers), logo tagline.
- Use `QCI_CYAN` (dim) as fallback if needed.
- Pure view/render change. No model/ logic/ DB.
- Mandatory: TestBackend + visual_rows + find_text/row_text on unselected content + update! + re-render.
- Always `julia --project=qci-kanban`.

## Phases
1. Color def + export + comments in QciKanban.jl
2. Board cards/empty/headers (keep navy for borders)
3. Modals (user picker, priority label in edit)
4. Calendar + stubs + due list
5. Expand tests (runtests + board_render + users + calendar + modal_move) using visual_rows for unselected visibility.
6. Validate (full test run), doc minor updates, evidence.

Files: qci-kanban/src/QciKanban.jl, test/*.jl, README optional.

Risks: term bg vary (dark assumed), narrow/empty paths, keep existing tests green.

See full planner output for details. All UI = TestBackend coverage.

## Artifacts
- This plan.md
- After scout: scout-report.md
- Phase summaries during loop
- All via `julia --project=qci-kanban`

## Commands
- Test: `julia --project=qci-kanban -e 'using Pkg; Pkg.test()'`
- Targeted renders with visual_rows.

Status: plan complete. Proceed to scout.