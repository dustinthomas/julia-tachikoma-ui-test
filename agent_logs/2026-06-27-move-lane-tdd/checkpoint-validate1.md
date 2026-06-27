# Checkpoint: Validate 1 (Red)

**RUN_ID**: 2026-06-27-move-lane-tdd

## Validator JSON gate (exact)
```json
{
  "tests_passed": false,
  "coverage_percent": 81.8,
  "failing_tests": [
    "move via 'm' + nav + Enter non-adjacent Backlog->Done; cards_by_status, selection, msg, persist",
    "'esc' cancels move-to-lane modal without change"
  ],
  "coverage_gaps": ["lines in modal handler branches + board 'm' related ~10 lines"],
  "overall_status": "red",
  "recommendations": "Fix key routing priority. Board nav and top-level escape consume keys intended for :move_lane modal. Hoist guards or add modal==:none condition in board block + condition escape. Open+render path and direct helper already exercise well and have TestBackend coverage. 'm' open test passes fully."
}
```

## Evidence location
- validation-evidence.md (commands, tails, TestBackend snippets, root cause)
- Full suite shows only the 2 new failing testsets (7 asserts); "'m' opens" testset is green (9/9)
- Coverage on new logic ~82% (unreached because handlers not hit via update!)

## Diagnosis (from validator)
- Top `elseif :escape` unconditionally quits.
- `if m.view_mode == :board` block (j/k/enter etc return early) runs even after modal set to :move_lane.
- 'm' open succeeds because open happens inside board block while modal was none.
- Subsequent keys diverted.

## Next action
Spawn Coder again with scoped failing details + exact diagnosis + red-tests + plan. Ask for MINIMAL fix to routing so tests pass + 100% cov.

Only edit the minimal routing guards.
