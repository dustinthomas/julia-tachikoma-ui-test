# Scout Report: Kanban functionality gaps (add to backlog, moves, modal cycle)

From disk reads (AGENTS, plan, src/QciKanban.jl, tests).

## Backlog add ('n' path)
- BOARD_COLUMNS[1] = "Backlog" (line 34)
- save_modal! create: status="To Do" hardcode, select To Do col (216-222)
- 'n' triggers open_edit_modal!(new=true) (332)
- open: title focused=true (186)
- Tests: count+1, title find, no Backlog status/col assert

## Move across cols
- move_selected!(dir) (131-179): left/right status + append pos, load, set col/index. up/down reorder.
- Calls: '<' left, '>' right (341,344). h/l = col nav only.
- Gaps: empty target, post-move select on Backlog, messages.
- Tests partial (some status change, no empty/Backlog specific polish)

## Modal edit cycle
- update modal: enter save, esc, 1/2/3, then handle_title then handle_desc (287-302) — no tab, always sequential.
- open: title focused (new and edit)
- view: static "TITLE>" "DESC>" + render widgets (589)
- No :tab handling.
- Focus: TextInput/TextArea use .focused + handle guards (Tachikoma).
- Tests: set_text! + enter, render "TITLE>", no tab/cycle/focus assert.

Precise edit sites: src ~34,131,181,216,287,332,341,589 + tests.

Patterns: manual focus toggle, consume tab early, visual_rows + update! + find/row after keys.

No Form. Keep manual.

Ready for impl per plan.