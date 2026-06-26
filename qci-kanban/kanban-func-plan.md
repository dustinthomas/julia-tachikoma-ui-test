# Plan: QciKanban — Major Functionality: Backlog add, column moves, modal field cycle

Task from user: keep prior list for later. Major pieces:
1. Way to add task to backlog.
2. Way to move tasks across Kanban columns.
3. In edit card: cycle through fields, edit, save.

Follows AGENTS.md + prior Kanban work (TestBackend mandatory, visual_rows, julia --project=qci-kanban, Elm style, pure update! for mutations, manual widgets in modals).

Current state (from reads):
- 'n' creates card but forces "To Do".
- Move exists via h/l (nav) + < > (status) + j/k (reorder), but polish gaps (selection after move, empty cols, Backlog flow).
- Edit modal: static key feed to title then desc, no Tab cycle, no explicit focus toggle.
- All other core (board render, calendar, users, DB) solid + recent color fix + tests passing.

See full planner output for details, phases, risks.

## Key Decisions
- Leverage existing 'n'+Enter for (1). Set status="Backlog", select it.
- Enhance existing move paths for (2).
- Add :tab / :backtab handling in update! for (3) modal. Toggle .focused on title/desc. Keep Enter save, 1/2/3 priority.
- Minimal visual cue in modal for focused field (cyan label).
- Test: update! + visual_rows + find_text/row_text + re-render for every flow.
- No new hotkeys, no Form widget (keep manual), no DB changes.

## Phases
1. Logic for Backlog create + move polish (QciKanban.jl)
2. Modal Tab cycle + focus (update! + open + view)
3. Board/view minimal polish
4. Test coverage (test_modal_move.jl + board_render)
5. Docs + full validate

## Files
- qci-kanban/src/QciKanban.jl
- qci-kanban/test/test_modal_move.jl
- qci-kanban/test/test_board_render.jl
- qci-kanban/README.md (keys)
- This plan + future phase summary

## Validation
julia --project=qci-kanban -e 'using Pkg; Pkg.test()'
Targeted renders with update! sequences for new flows.

Risks: modal focus isolation, empty col moves, persist after 'r', narrow.

See detailed planner output above for exact code sites + test assertions.