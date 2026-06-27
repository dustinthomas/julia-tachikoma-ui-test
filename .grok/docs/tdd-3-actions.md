# TDD 3-Actions Contract

The `tdd-orchestrator` delegates work using three core actions. These are the only things it spawns specialized workers for.

## Action 1: Write Red Tests (Test Writer)
**Persona**: `test-writer` (fast)

**Input (scoped)**:
- Task + acceptance criteria or gaps
- Relevant plan phase excerpt
- Current code state / existing tests (read from disk)
- Latest checkpoint if any

**Output**:
- Failing tests only (as unified diff or file patch)
- Short summary (what scenarios, why they fail, intended coverage)

**Rules**:
- Never any production code.
- UI behavior → mandatory `Tachikoma.TestBackend` + inspection + event simulation.
- Tests must be the first to go green when the minimal correct change lands.
- Orchestrator will apply, run to confirm red, and checkpoint.

## Action 2: Implement to Green (Coder)
**Persona**: `coder` (grok-composer-2.5-fast native)

**Input (very narrow)**:
- The current failing red tests (and only those)
- Tiny relevant diff or context from plan/checkpoint
- Instruction: "minimal code to pass exactly these tests"

**Output**:
- Smallest possible diff that makes the supplied tests pass
- Summary of changes

**Rules**:
- Receive **only** the red tests + minimal context. Do not re-explore broadly.
- Do not add extra features or refactor beyond making the red tests green.
- Orchestrator applies and immediately validates.

## Action 3: Validate + Gate (Validator)
**Persona**: `validator` (grok-build)

**Input**:
- The changes + the tests that should now pass
- Instruction to run full relevant suite + coverage on changed logic

**Output** (strict JSON gate preferred):
```json
{
  "tests_passed": true,
  "coverage_percent": 100,
  "failing_tests": [],
  "coverage_gaps": [],
  "overall_status": "GREEN_GATE_PASSED"
}
```
Plus verbatim command + exit_code + concise evidence for every run.

**Rules**:
- Must actually execute `julia --project=.` (targeted + full as appropriate).
- For UI: confirm TestBackend assertions are present and exercised.
- Coverage measurement required (Pkg.test with coverage or Coverage.jl).
- Only the orchestrator decides whether the gate is satisfied and whether to loop (more red/green) or advance.
- On success: orchestrator writes validation-evidence and advances.

## Orchestrator Responsibilities Across Actions
- Maintains `todo_write` with Red/Green/Validate phases.
- Writes checkpoints after each action (`checkpoint-red.md`, `checkpoint-greenN.md`, `checkpoint-validateN.md`).
- Ensures handoffs are minimal and subagents read artifacts from disk (`agent_logs/<slug>/`, `plan.md`).
- Enforces 100% coverage on changed code (or documented exception).
- Owns final summary and state.

These three actions + orchestrator state machine = the TDD workflow.
