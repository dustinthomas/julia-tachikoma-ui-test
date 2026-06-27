# TDD Plan: Direct Move to Lane (any column, not just adjacent) for QCI Kanban

## Task
Add the ability for the user to move a selected task/card directly to any lane (e.g. Backlog → Done) in one action.
Current UX only supports adjacent moves via `<` / `>` (see move_selected! and 'm' not bound).

Example: from Backlog directly to "To Do", "Review", or "Done".

## Acceptance Criteria (must pass tests + coverage)
1. On board view, pressing 'm' opens a "Move to lane" modal/picker (similar UX to user picker).
2. Picker lists all BOARD_COLUMNS in order, with current lane highlighted or indicated.
3. Arrow/k/j or up/down navigate the lane choices; Enter confirms move to chosen lane.
4. On confirm:
   - Card is moved from current status to target status (appended to end of target, or last pos+1).
   - Model selection updates: selected_col to target index, selected_idx to end of that column.
   - Message indicates "moved to X".
   - If target == current: either no-op or treat as confirm (no harm).
5. 'esc' or 'q' cancels the move modal without change.
6. After move, 'r' (reload) shows the card in new lane persistently.
7. Full TestBackend coverage:
   - update!(m, KeyEvent('m')) opens modal, view shows lane names in picker.
   - Navigation + Enter performs move; assert cards_by_status before/after, selected_col/idx.
   - Re-render after move + find_text / row_text / visual_rows.
   - Modal suppresses board bleed (no stray card keys or original column headers under modal? or at least modal title present).
   - Works from any starting lane to non-adjacent target.
8. No regression on existing < > moves, n/create, edit, etc.
9. Update README keys section to document 'm'.

## Scope / Files
- Primary: qci-kanban/src/QciKanban.jl  (add modal handling, move_to_lane logic, view for picker, update! binding for 'm')
- Test: qci-kanban/test/test_modal_move.jl  (add dedicated @testset for the direct move flow, using visual_rows + update! + assertions)
- Docs: qci-kanban/README.md (keys)
- Artifacts: this plan + checkpoints in agent_logs/2026-06-27-move-lane-tdd/

Do NOT touch db.jl (existing update_issue_status_and_position! is sufficient).
Reuse as much as possible from existing modal and move code.

## Test Strategy (TDD Red first)
- Test Writer produces tests that FAIL initially (no 'm' handler, no :move_lane, no direct move API).
- Tests use fresh() :memory: models.
- Exercise:
  - open modal via 'm' after selecting a card
  - render assertions (find "MOVE" or "Move to lane", lane names visible)
  - select different lane via keys + enter → card status changed in model
  - cross-lane (Backlog → Done) specifically
  - cancel with esc
  - persist check with 'r' + reload
  - visual_rows after sequence
- Direct model + update! tests preferred; full TestBackend for UI paths.
- Validator must execute the tests + measure coverage (Pkg.test in subproject context).
- Goal: 100% coverage on the new move-to-lane code paths.

## Coverage target
100% on changed logic (KanbanModel update/view paths for new modal + move function).

## Implementation notes (for later Coder, minimal)
- Add to KanbanModel: nothing major new; reuse modal + add maybe `move_lane_selected::Int` or use user_selected pattern for simplicity, or a dedicated field. Prefer minimal: reuse a picker idx or add `lane_selected::Int`.
- New modal symbol: :move_lane
- New function `open_move_lane_picker!(m)`, `confirm_move_to_lane!(m)`
- In move logic, extract a helper `move_card_to!(m, id, new_status)` that computes pos = length(target)+1, calls DB, reloads, updates selection + msg.
- In update!: if board && 'm' → open. Route keys for the modal.
- In view: if modal==:move_lane render a centered Block picker listing columns, ▶ for current choice.
- Keep style consistent (QCI_CYAN etc).
- 'm' should only work in :board + :none modal.

## Current relevant code pointers (read from disk)
- BOARD_COLUMNS const (src/QciKanban.jl:34)
- move_selected! (131-180) — refactor lightly to share status-move core if helpful.
- modals: :card_edit, :user_picker handling (update 289+, view ~600+)
- load_board! , ensure_db
- test_modal_move.jl patterns (fresh, update!, visual_rows, assertions on modal, counts, find_text after update!)

## Plan steps for orchestrator
1. Setup complete (this file + todo + dir).
2. Red: spawn test-writer with scoped prompt (this plan + current test patterns).
3. Green: spawn coder with the failing test diff + plan excerpt.
4. Validate (use julia --project=qci-kanban), collect JSON gate.
5. Loop as needed.
6. Checkpoint after Red, each Green/Validate.
7. Selective review if warranted.
8. Final summary + token accounting.

RUN_ID: 2026-06-27-move-lane-tdd
Target: green + 100% cov on feature.
