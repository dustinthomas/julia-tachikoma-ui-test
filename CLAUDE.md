# CLAUDE.md — julia-tachikoma-ui-test (repo root)

Julia + Tachikoma.jl TUI experiments plus the agentic-workflow setup used to build them. Main sub-projects: `qci-kanban/` (Jira-grade Kanban TUI — has its own CLAUDE.md) and `particle-life/`. Path-scoped rules in `qci-kanban/.claude/rules/` carry the Julia/Tachikoma methodology, the test-impact map, and the run-the-app gate — they load automatically when you touch matching files.

## Workflow (2026-07 revision — see `.grok/docs/agentic-workflow-2026-07.md` for rationale + evidence)

Work is tiered by size. Default to doing the work yourself in one context; the agent that implements a feature also writes its tests. Never split plan/code/test across separate agents by role.

**Tier 0 — trivial** (typo, label, one-line guard): direct edit + the targeted tests from the test-impact map. No subagents, no ceremony.

**Tier 1 — normal feature/bugfix (the default):**
1. *Scout* — if you need broad codebase context, dispatch a read-only Explore subagent and use its summary; don't paste file dumps into your context. For a change where you already know the files, just read them.
2. *Plan inline* — a short written plan (in your response or a plan file for larger work). No separate planner agent.
3. *Implement + test in the same context* — you write both the change and its TestBackend tests. Run the targeted tests from the test-impact map as you go, then the full suite.
4. *Verify independently* — dispatch the `verifier` agent (`qci-kanban/.claude/agents/verifier.md`) with the task description and changed-file list. It re-runs the full suite + app gate and reviews the diff with explicit criteria. Fix its critical/warning findings and re-verify.

**Tier 2 — large multi-part work:** write a short design doc with a PR plan (a DAG of small, independently reviewable slices), get user buy-in, then implement each slice as a Tier-1 unit — worktree isolation if slices run in parallel. Each slice's implementer owns its tests; each slice gets its own verifier pass.

## Verification culture (non-negotiable, any tier)

- Never claim green without running the commands yourself in this session; report exact command + exit code.
- Full suite before done: `julia --project=. test/runtests.jl` (from the sub-project).
- Run-the-app gate after `src/` changes (see `qci-kanban/.claude/rules/run-the-app-gate.md`).
- Reviewer/verifier findings must quote code verbatim from disk with `file:line`.
- Escalate to adversarial re-verification (independent re-check of the evidence) only for critical findings, not every nit.

## Token discipline

- Prefer targeted reads over whole-file dumps; prefer `git diff` over re-reading everything when reviewing.
- Write durable state to disk (plan files, `agent_logs/`), not into conversation history.
- Subagents are for context isolation (exploration, independent verification) — not for role-play. Every handoff loses context; minimize handoffs.

## Cross-tool note

`.grok/` holds the Grok CLI setup for this repo (AGENTS.md is its entry point) — same tiered workflow, same gates. Keep the two in sync when changing workflow policy; the canonical test-impact map lives at `qci-kanban/.claude/rules/qci-kanban-test-map.md` and is referenced from both.
