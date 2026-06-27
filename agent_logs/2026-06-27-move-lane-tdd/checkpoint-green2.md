# Checkpoint: Green 2 (Coder fix)

**RUN_ID**: 2026-06-27-move-lane-tdd

## Fix applied (minimal)
Exactly two guards per validator diagnosis:
1. `elseif evt.key == :escape && m.modal == :none`
2. `if m.view_mode == :board && m.modal == :none`

This makes:
- 'm' open (from none) still work.
- j/k/enter when modal=move_lane skip board nav and reach dedicated handler.
- esc when modal active skips quit and reaches cancel handler in picker.

Diff: 2 lines changed (guards only).

## Syntax verified
`julia --project=qci-kanban -e 'using QciKanban; println("ok")'` → ok

Now invoke validator for full gate.
