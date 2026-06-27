# The 3 Core Actions (TDD Workflow)

This file defines the three primary specialized actions/roles in the hierarchical TDD agentic workflow for this project.

Use with the TDD skill (`/tdd`), the orchestrator prompt, or manually via `spawn_subagent` + the corresponding personas.

## 1. Test Writer (Red Phase)

**Persona**: `test-writer`

**Goal**: Produce the minimal set of failing tests that will drive correct implementation.

**Input (always scoped)**:
- Task description / acceptance criteria
- Existing relevant tests (if any)
- Coverage gaps or previous validator report (optional)
- References to `plan.md` / summaries / `agent_logs/<run>/...`

**Rules**:
- Tests must fail until the implementation exists.
- Prioritize tests that force real behavior (especially Tachikoma UI via TestBackend: render + char_at/find_text/row_text + update!/handle_key! + re-render).
- Use existing patterns from `test/*.jl`.
- Be concise; avoid over-testing trivial paths.

**Output**:
- Unified diff (or edit instructions) for test file(s)
- JSON summary:
  ```json
  {
    "tests_added_or_updated": ["test/foo.jl: new filter behavior"],
    "target_coverage": 100,
    "rationale": "..."
  }
  ```

**Model**: grok-composer-2.5-fast (fast)

## 2. Coder / Implementer (Green Phase)

**Persona**: `coder`

**Goal**: Write the smallest amount of code necessary to make the current failing tests pass.

**Input (always scoped)**:
- The failing tests (from Test Writer) or validator feedback
- Relevant unified diff of recent changes
- Task/plan excerpt
- Checkpoint summaries

**Rules**:
- Minimal implementation only.
- Follow project conventions (Julia + Tachikoma Elm model exactly).
- Edit via tools.
- No unrelated features or refactors yet.

**Output**:
- Code changes (search_replace / write)
- Unified diff or targeted excerpts
- JSON summary:
  ```json
  {
    "files_changed": ["src/foo.jl"],
    "tests_now_passing": "...",
    "notes": "Minimal changes to satisfy tests."
  }
  ```

**Model**: grok-composer-2.5-fast (locked native)

## 3. Validator / Evaluator (Gate + Feedback)

**Persona**: `validator`

**Goal**: Execute tests + coverage. Provide structured gate decision. Drive iteration.

**Input**:
- Current code state after Coder
- The tests being targeted

**Process (mandatory)**:
- Run `julia --project=. ...` (full or targeted)
- Measure coverage (`Pkg.test(coverage=true)` or Coverage.jl)
- For UI: actually exercise TestBackend assertions
- Never claim success without executing the commands

**Required Output** (strict JSON + evidence):
```json
{
  "tests_passed": true | false,
  "coverage_percent": 100,
  "failing_tests": [],
  "coverage_gaps": [],
  "overall_status": "green" | "yellow" | "red",
  "recommendations": "short actionable note"
}
```

Plus exact commands + concise evidence (full tail only on "all pass" claims or failures).

**Loop rule**: Orchestrator loops back to Coder (or Test Writer) until `overall_status == "green"` **and** `coverage_percent >= 100`.

**Model**: grok-build (strong for execution + judgment)

## Orchestrator Role (Thin Coordinator)

The lead (you, the `tdd-orchestrator` persona, or the `tdd` skill) owns:
- TDD state machine (Red → Green → Refactor)
- `todo_write`
- Writing checkpoints to `agent_logs/<slug>/`
- Deciding when to run selective reviews (on diffs only)
- Escalation to human
- Enforcing scoping on every spawn

It never does the 3 actions itself — it spawns the specialized personas.

## Usage

See:
- `.grok/docs/tdd-workflow.md` for full orchestrator prompt + commands
- `.grok/skills/tdd/SKILL.md` for the automated `/tdd` workflow
- Personas: `tdd-orchestrator.toml` (the agent that runs this), `test-writer.toml`, `coder.toml`, `validator.toml`

All handoffs must stay scoped. Repo + `agent_logs/` is source of truth.
