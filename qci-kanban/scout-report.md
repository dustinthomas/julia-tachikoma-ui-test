# Scout Report: QciKanban secondary color (QCI_NAVY) contrast

## Colors (QciKanban.jl:23)
QCI_CYAN = (0,188,212)
QCI_NAVY = (30,32,75)  # invisible on black for text

Add QCI_SECONDARY ~ (100,110,165) for unselected text. Keep NAVY for borders/tag.

## All NAVY sites (file:line)
- 413: logo tag "QCI KANBAN" (keep navy subtle)
- 468: unsel column border_style (keep)
- 506: board unselected cards (change)
- 512: board empty (change)
- 531: calendar due items (change)
- 537: no dues (change)
- 541: stub view text (change)
- 602: modal priority (change)
- 622: unsel users (change)
- 626: no users (change)

## Patterns
- Manual set_string + Style in loops inside Block inners.
- sel ? cyan+bold : navy
- empties: navy + dim
- prefix "  " vs "▶ "
- visual_rows helper in runtests.jl (use it)
- Tests use TestBackend(80+,18+), visual_rows, find_text, row_text, update! + re-render. :memory: loads.

## Test gaps
No explicit checks that unselected card text / user names / dues / empties appear in buffer rows.

## Gotchas
- Manual render (no SelectableList for lists)
- Trunc + narrow avail
- Modal suppresses board (good for bleed tests)
- Always julia --project=qci-kanban
- Pure view change

See full scout output. Sites ready for targeted replace. Follow plan phases + AGENTS (TestBackend mandatory).