# TDD Workflow for Grok Build (Hierarchical + Scoped)

**Status**: 2026-06-27 — Initial version aligned with research and this project's token-efficiency lessons.

This document gives you copy-paste-ready prompts, schemas, and commands.

**For the full architecture explanation + usage breakdown with diagrams, see:**
→ [`.grok/docs/tdd-architecture.md`](tdd-architecture.md)

## Why This Exists
The classic `/pipeline` (and older flat multi-agent runs) can explode to 24M+ tokens because the lead accumulates everything.

This workflow implements the stronger 2025–2026 pattern:
- Thin hierarchical orchestrator (owns state + TDD machine).
- Sub-agents receive **only** what they need (failing tests + diff + summary).
- Structured handoffs (JSON + unified diffs).
- Persistent checkpoints in the repo (`agent_logs/`).
- Explicit 100% coverage gate + Tachikoma TestBackend enforcement for UI.
- Prefer the advanced bundled skills (`/design` + `/execute-plan`, `/implement`) for large work; use this when you want explicit local TDD control.

## The Loop (Red → Green → Refactor)
1. **Plan** (planner or orchestrator) → TDD plan (tasks, test strategy, coverage targets).
2. **Test Writer** → failing tests only (diff + JSON).
3. **Coder** → minimal code to pass those tests (diff + JSON).
4. **Validator** → run tests + coverage. Emit strict JSON gate. Loop if not green+100%.
5. **(Optional) Reviewers** — only on diffs, when orchestrator decides. Diff-only input.
6. **Checkpoint** after major steps (lead writes to agent_logs).

## 1. Orchestrator Prompt (paste as your main /goal or lead instructions)

```
You are the TDD Orchestrator (grok-build). Enforce strict Red-Green-Refactor until tests pass + coverage >= 100%.

Non-negotiable rules:
- Scoped context ONLY for every delegation: failing tests (excerpt) + relevant unified diff + task/plan summary + current checkpoint. Tell subagents: "read plan.md and agent_logs/<id>/checkpoint-*.md from disk".
- Handoffs: unified diffs or exact JSON. Never dump full source or conversation history.
- TDD loop: 
  1. Test Writer → failing tests (diff + JSON).
  2. Coder → minimal implementation to make them green (diff + JSON).
  3. Validator → run tests + coverage (Julia + Tachikoma TestBackend). Structured JSON gate.
  4. Orchestrator decides: loop, refactor, checkpoint, or escalate.
- Write checkpoints after each phase to agent_logs/<feature>/checkpoint-N.md + update tdd-state.json.
- Use todo_write for TDD state (Red/Green/Refactor + current task).
- Reviews: only when significant or on your decision. Pass diff + relevant tests only. Parallel when possible.
- Escalate to human on persistent coverage failure, high-risk, or after N iterations.
- Persistent truth is the git repo + agent_logs/.

Current user goal: [PASTE USER FEATURE REQUEST HERE]

First action: Create a structured TDD plan (JSON) with tasks, test strategy, coverage targets. Write initial artifacts. Then start the loop.
```

## 2. JSON Handoff Schemas (require these in subagent outputs)

Test Writer:
```json
{
  "tests_added_or_updated": ["test/test_foo.jl: filter by status"],
  "target_coverage": 100,
  "rationale": "Covers new view path + update! behavior that was uncovered"
}
```

Coder:
```json
{
  "files_changed": ["src/foo.jl", "test/test_foo.jl"],
  "tests_now_passing": 12,
  "notes": "Minimal change to satisfy the two new tests. No extras."
}
```

Validator (the gate):
```json
{
  "tests_passed": true,
  "coverage_percent": 100,
  "failing_tests": [],
  "coverage_gaps": [],
  "overall_status": "green",
  "recommendations": "Ready for optional review or refactor checkpoint."
}
```

## 3. Julia Commands (hardcode / always use these)

- Full run: `julia --project=. -e 'using Pkg; Pkg.test()'`
- Targeted: `julia --project=. test/runtests.jl`
- With coverage: `julia --project=. -e 'using Pkg; Pkg.test(coverage=true)'`
- Or with Coverage.jl (add to [test] deps if needed):
  ```julia
  using Coverage
  # after test run
  cov = process_folder("src")
  covered, total = get_summary(cov)
  percent = covered / total * 100
  ```

For every UI change, the validator (or test writer) must also execute:
- `TestBackend`, `render_widget!`, `char_at`, `find_text`, `row_text`, `handle_key!` / `update!` + re-render assertions.

See existing tests in `test/test_ai_metrics_dashboard.jl` and `test/test_cyberdeck.jl` for exact patterns.

## 4. agent_logs/ Layout (create per feature/run)

```
agent_logs/
  add-status-filter-abc123/
    tdd-plan.json
    checkpoint-1-plan.md
    checkpoint-2-red.md          # after Test Writer
    checkpoint-3-green-attempt-1.md
    coverage-report.json
    changes.diff
    state.json                   # simple {phase: "green", coverage: 100, ...}
    final-summary.md
```

Lead writes the checkpoints. Sub-agents are told the path and instructed to read from disk.

.gitignore suggestion (project root):
```
agent_logs/
# or keep specific runs if you want them in history
```

## 5. How to Run (practical options)

**Option A — Manual orchestrated (full control)**
1. Start a fresh session or use a long-running lead.
2. Paste the Orchestrator Prompt + user goal.
3. Let it spawn Test Writer (new persona), then Coder, then Validator.
4. On validator "yellow/red" → feed the JSON back and loop.
5. When green + 100%, optionally spawn diff-only reviewers.
6. Write final checkpoint + run tests one last time.

**Option B — Use evolved local pipeline**
Use `/pipeline` (once the skill is updated) with TDD emphasis, or just follow the steps above.

**Option C — Recommended for anything non-trivial (best isolation)**
```
/design "Add X with full Tachikoma TestBackend coverage and 100% on changed code"
# review the PR plan
/execute-plan <path-to-design-doc> --concurrency 3 --instructions "Follow TDD: tests first via Test Writer mindset. Use strict TestBackend assertions. Target 100% coverage."
```

Pass extra instructions to bundled skills to import the TDD discipline.

## 6. Reviewer Scoping (when triggered)

Prompt skeleton for reviewers:
```
You are a [Security|Correctness] Reviewer.

Input: ONLY the code diff + relevant failing/passing tests + guidelines.

Output structured JSON:
{
  "issues": [
    {"severity": "high|medium|low", "description": "...", "location": "file:line", "suggestion": "..."}
  ],
  "overall_risk": "low|medium|high",
  "approval_recommendation": "approve|revise|block"
}

Quote only from the diff. Be concise.
```

## 7. Measurement & Iteration
- Track tokens per phase when possible (unified.jsonl analysis).
- After a run, compare `coverage_percent` and final test count vs. plan.
- Update `.grok/docs/pipeline-token-usage-and-better-architectures.md` or create a new benchmark summary with real numbers.

## 8. Related Files
- AGENTS.md (TDD section + workflow choice table)
- .grok/personas/tdd-orchestrator.toml (the dedicated agent for running this workflow)
- .grok/personas/{test-writer,coder,validator}.toml
- .grok/docs/tdd-3-actions.md (the three core actions)
- .grok/skills/tdd/SKILL.md (the /tdd command)
- .grok/skills/pipeline/SKILL.md (and bundled implement/design/execute-plan)
- Existing token-efficiency.md

This setup is directly usable today in Grok Build. Start small (one contained widget or filter) to calibrate the loop and token savings.

Ready for implementation or further tuning.
