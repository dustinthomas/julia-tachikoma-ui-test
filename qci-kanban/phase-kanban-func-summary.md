# Phase Summary: Kanban Major Functionality (Backlog add, column moves, modal field cycle)

## Status
Implemented + validated. 1 attempt. Reviews: sec clean (0 crit), corr PASS, conv partial (preexist + gaps).

## What added (per plan)
1. 'n' + Enter now creates in "Backlog" + selects it (src ~222).
2. Move polish: clamps, empty col, messages, Backlog flow (move_selected! + calls).
3. Modal: Tab/Backtab cycles title<->desc focus (.focused toggle), chars to focused only, Enter saves (update! + view cue cyan bold for focused label).

All via existing keys, manual focus, pure update!.

## Validation evidence
- `julia --project=qci-kanban -e 'using Pkg; Pkg.test()'` → exit 0 (all suites pass).
- Targeted:
  - n+enter: selected_col=1, Backlog count++, visual find "Backlog" + card.
  - <> moves: col change, "moved →", persist on r, visual rows.
  - n + tab/backtab + chars to desc + enter: focus toggles, desc gets text, saves, no bleed (find no "Backlog"/"QCI-" under modal).
- visual_rows + find_text/row_text + update! used.

## Reviews
- Security: 0 critical. Warning: preexist global keys before modal guard (b/c/L/r leak). Nit: sequential handle without caller focus check.
- Correctness: PASS. Backlog lands, moves update/select/persist, tab cycles + focus + save + no bleed. Verbatim code matches plan.
- Conventions: PASS core (4sp, no model change, manual widgets, QCI_ + SECONDARY, update! mutations). Violations: preexist load_board! inside view; new flows lack explicit Tab/Backlog col tests in suite; README keys not updated (l vs L, no Tab).

## Artifacts
- kanban-func-plan.md
- scout-kanban-func.md
- phase-kanban-func-summary.md
- src/QciKanban.jl only

## Next
- Add targeted tests for cycle/Backlog select.
- Update README keys.
- Optional: move load out of view.
- All via `julia --project=qci-kanban`.

Core major pieces done. Tests pass. Ready.