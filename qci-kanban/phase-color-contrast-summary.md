# Phase Summary: Secondary Color Contrast Fix

## Status
Approved. 1 attempt. All validation + reviews passed.

## What done (caveman terse)
Added QCI_SECONDARY lighter navy. Swapped unselected text (cards/users/dues/empties/priority/stub) to it. Kept NAVY for borders + logo tag.

Pure view. Export added. Tests expanded with visual_rows + find/row on unselected after update!.

## Validation evidence
- julia --project=qci-kanban -e 'using Pkg; Pkg.test()' → exit 0, all suites pass (DB 21, board 26, modal 23, users+unsel 7+6, calendar+due 3+5, phase0 21, record 2)
- Targeted visual_rows after l/j/u/c/n: unsel card titles, "— empty —", users (Sam), "DUE", "(no dues", "PRIORITY:", stubs present in rows/find_text.
- Export: isdefined + value ok.
- Audit re-runs: same 0.

## Reviews (3 lenses)
- Security: 0 issues. No secrets/inj/unsafe Color/export/term esc. Quotes from QciKanban.jl.
- Correctness: PASS. Unsel now SECONDARY visible, sel cyan, tests cover, no logic change.
- Conventions: PASS (4sp, TestBackend+visual_rows mandatory followed, export grouped, QCI_ name, no model). Note: preexist load_board! in view (not introduced).

## Artifacts
plan.md, scout-report.md, phase-color-contrast-summary.md, updated src + tests.

## Commands
Always julia --project=qci-kanban.

## Next
None. Unselected lists now visible on black. Ready.