# Agentic Workflow — 2026-07 Revision (rationale & evidence)

**Date:** 2026-07-05
**Supersedes:** the persona pipeline (`/pipeline`) and 3-agent TDD choreography (`/tdd` v1) as defaults.
**Applies to both** `.claude/` (Claude Code) and `.grok/` (Grok CLI) setups in this repo.

## Why we changed

Our own logs showed a single `/pipeline` run consuming ~24.1M tokens (166 turns, 406k peak prompt) — see `pipeline-token-usage-and-better-architectures.md`. A deep-research pass (2026-07-05, 104 agents, 3-vote adversarial verification of every claim against primary sources) confirmed this is the architecture, not the tuning:

1. **Default to a single agent; add multi-agent only under genuine constraint** (context limits, true parallelizability, tool specialization). Coding has few truly parallelizable subtasks. — Anthropic (claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them), Cognition (cognition.com/blog/dont-build-multi-agents). *Verified 3-0.*
2. **Multi-agent costs 3–10× the tokens of single-agent** for equivalent tasks (~15× vs chat; independent measurement 4–220×). — anthropic.com/engineering/multi-agent-research-system. *Verified 3-0.*
3. **Persona/role pipelines (planner→coder→tester→reviewer) are deprecated** in favor of context-centric decomposition: split by what context each agent needs, never by type of work. In Anthropic's internal experiment, role-split subagents spent more tokens on coordination than on actual work. The agent that builds a feature should also write its tests. *Verified 3-0.*
4. **The one role split that works is verification** — an independent verifier needs minimal context transfer and dodges self-confirmation bias, but MUST have explicit criteria ("run the complete test suite") or it rubber-stamps. *Verified 3-0.*
5. **Orchestrator-subagent is the right shape when multi-agent is needed**: the lead does primary work itself; ephemeral subagents explore extensively but return ~1–2k-token summaries. *Verified.*
6. **TDD: contextual test-impact information beats procedural TDD instructions.** TDAD (arXiv 2603.17973): a static code→tests dependency map cut regressions ~70% (6.08%→1.82%); procedural TDD prompting WITHOUT that context increased regressions to 9.94% — worse than no intervention. *Verified 3-0 (preprint caveat).*
7. **Context hygiene**: always-loaded instruction files under ~200 lines; savings come from path-scoped rules and on-demand skills, not file splitting; don't starve the coder of context to save tokens (a measured 42% input cut cost 12 points of SWE-bench resolution). *Verified.*

## The tiered workflow

- **Tier 0 (trivial)**: direct edit + targeted tests from the test-impact map. No subagents.
- **Tier 1 (default — normal feature/bugfix)**: one agent end-to-end: optional read-only scout subagent (summary only) → short inline plan → implement + write tests in the same context → run targeted tests then full suite → **independent verifier subagent** with explicit criteria (full suite + run-the-app gate + diff review with verbatim quotes). Fix findings, re-verify.
- **Tier 2 (large)**: design doc with a PR-plan DAG of small independently reviewable slices → each slice implemented as a Tier-1 unit (worktree isolation when parallel), each with its own verifier. This is context-centric decomposition — the only justified parallel multi-agent shape.

## What we kept (validated by the research)

- Evidence culture: exact command + exit code, re-audit "all pass" claims, verbatim quotes from disk.
- Tachikoma TestBackend methodology + the run-the-app gate — deterministic end-to-end verification.
- Artifact-first state (plan files, `agent_logs/`) instead of conversation history.
- Adversarial 2-of-3 verification — scoped to critical findings only.

## What we dropped, and why

- **Persona pipeline as default** (`/pipeline`): role handoffs lose context; coordination cost exceeded work (findings 1–3). Kept on disk, marked deprecated.
- **3-agent TDD choreography** (test-writer → coder → validator): procedural TDD prompting measurably increases regressions without targeted test context (finding 6). Replaced by red-first discipline *inside one agent* + the test-impact map (`qci-kanban/.claude/rules/qci-kanban-test-map.md`, canonical for both tools).
- **100% coverage gate**: no evidence it pays; the validated gate is full-suite green + app runs. Coverage remains a diagnostic, not a gate.
  - **Superseded 2026-07-05 (owner decision)**: in `qci-kanban` the coverage gate is REINSTATED as mandatory — `julia --project=. test/coverage_gate.jl` must pass (100% line coverage on gated v2 files) alongside the full suite and the app gate, and user-facing features require BDD acceptance specs in `test/features/`. Policy: `qci-kanban/.claude/rules/tdd-bdd-coverage-gates.md` (canonical for both tools). The research point above stands as literature context; the repo policy overrides it.
- **3 parallel single-lens reviewers**: one verifier covering all lenses with explicit criteria; escalate only critical findings to adversarial re-check.

## Measurement

The before/after benchmark (`benchmark-token-efficiency-plan.md`) was never run. Going forward, log per-run token totals for pipeline-class tasks so the next revision argues from our own numbers, not just the field's.
