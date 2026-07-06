# Pipeline Token Usage and Better Architectures for Robustly Tested + Reviewed Software

> **Historical evidence doc** — cited by `agentic-workflow-2026-07.md`. The pipeline personas and `token-efficiency.md` it references were removed 2026-07-05 (git history); current policy lives in `AGENTS.md`.

**Date:** 2026-06-26  
**Project:** julia-tachikoma-ui-test  
**Source:** Conversation with Grok in this workspace

---

## Part 1: The 25 Million Token Pipeline Run

**User question:**  
"So I used 25 M tokens with just 1 or pipeline request. Should this be expected or is this usage high?"

### Analysis from Logs

Analysis of `~/.grok/logs/unified.jsonl` showed:

- **Largest recent session**: ~24.1 million tokens  
  - Prompt: 23,963,032  
  - Completion: 79,138  
  - Reasoning: 73,806  
  - **166 inference turns**  
  - Peak prompt context: **406,436 tokens**

- Other large historical sessions: 14M–20M tokens (120–145 turns).

Prompt sizes in the big run started ~20k and climbed relentlessly to 200k–400k+.

This matches the user's 25M report almost exactly (the run occurred on 2026-06-26).

### Why This Happens with `/pipeline`

The current pipeline skill (`.grok/skills/pipeline/SKILL.md`) runs:

1. Plan (planner persona, `grok-build`)
2. Scout (scout persona)
3. Implement ↔ Validate loop (default max 4 attempts: coder + validator each time)
4. 3 parallel reviewers (security / correctness / conventions)
5. Evidence audits / re-runs on "all pass" claims
6. Lead orchestration between every step

**Root cause**: Single long-running **lead orchestrator** session. All subagent outputs are folded back into the lead's conversation history. Even with token-efficiency improvements, the lead's own context keeps growing.

### Relation to Existing Docs

- `.grok/docs/token-efficiency.md` (2026-06-22) was written because the team was already seeing lead context hit "**140k+ prompt tokens**" as a problem. The optimizations (phase summaries, disk artifacts, concise validator output, "read plan.md from disk", scoped reviewer prompts) were created to fight this.
- The benchmark plan (`.grok/docs/benchmark-token-efficiency-plan.md`) aimed to measure before/after.
- Observed reality (406k peak, 24M total for one pipeline invocation) is still well beyond the "problem we were solving."

**Conclusion from analysis**: 25M for a single `/pipeline` request is **high**, not merely "expected for complex work."

---

## Part 2: Is There a Better Architecture?

**User question:**  
"Is there better architecture to achieve the same goal of robustly tested and reviewed software?"

### Current Pipeline Strengths (to preserve)

- Structured Plan → Scout → Implement/Validate → Review
- High-signal evidence requirements
- Verbatim quoting by reviewers
- Re-audits on success claims
- Multiple lenses
- Strong Julia + Tachikoma rules (TestBackend coverage for UI, `julia --project=.`, etc.)
- `todo_write`, artifacts on disk, git diff preference

### Problems with the Monolithic Lead-Orchestrator Model

- Lead context explosion (the 24M symptom)
- Mostly serial execution even when work could be parallel
- Subagents often start "cold" (full context re-supplied)
- Hard to resume partial runs
- One big task = one giant context

### Better Architectures Already Present in the System

The bundled skills in `~/.grok/bundled/skills/` implement improved patterns that achieve the **same robustness goals** with far better isolation and context management.

#### 1. `/implement [--effort N]`

- Focused `implementer` ↔ reviewer(s) loop.
- Effort scaling (1–5 reviewers) with automatic specialization:
  - General reviewers
  - Tests specialist
  - Security specialist (`security-auditor` persona)
  - Plan Alignment specialist
- Uses `resume_from` heavily — the same subagent keeps its working memory across fix/re-review rounds.
- External threaded files for summaries and reviews (`/tmp/grok-*-{ID}.md`).
- Workspace-scoped memory system (`memory.py`) that learns recurring patterns across runs and injects "Past Issues to Avoid" briefings.
- Loops until **0 open issues** of any severity (same contract).

**Good for**: Medium features/bugfixes.

#### 2. `/design` + `/execute-plan` (Recommended for larger work)

This is the clearest evolution:

**`/design <task>`**
- Writer ↔ reviewer loop (dedicated `design-doc-writer` / `design-doc-reviewer` personas).
- Uses `resume_from`.
- Produces a polished design document that **must** include:
  - Key Decisions section
  - `## PR Plan` (a DAG of incremental, independently reviewable PRs with titles, affected files, dependencies, descriptions)

**`/execute-plan <design-doc-path> [--concurrency N] [--effort ...] [--resume <PLAN_ID>]`**
- Parses the PR Plan DAG, topologically sorts it, computes levels.
- **Per-PR worktree isolation** (`isolation: "worktree"` for implementers).
- Independent PRs at the same level can run in parallel (up to `--concurrency`, default 4).
- For each PR:
  - Dedicated implementer subagent (with design context + past-issues briefing).
  - **Mandatory** independent reviewer.
  - Review-fix loop using `resume_from` until that reviewer reports 0 issues.
- Orchestrator owns git coordination, branch creation (just-in-time for dependents), object fetch, cherry-pick for stack assembly, conflict resolution, and final stack (Graphite or plain-git + optional PR creation).
- Full resumability with state file (`/tmp/grok-exec-plan-*.json`).
- Cascade-skip on failures (only dependents affected; independent work continues).
- Same robustness guarantees:
  - 0 issues required (bugs/suggestions/nits)
  - Implementer can push back with `wontfix` + technical justification
  - Stalemates escalate to user
  - Memory flush at the end (shared with `/implement`)
  - Explicit design context passed to every subagent

**Key architectural wins for token usage**:
- **Scoping**: Each subagent works on a small, focused slice instead of the whole accumulated history.
- **`resume_from`**: Subagents carry state; orchestrator doesn't re-transmit everything.
- **Externalized truth**: Plan, per-PR summaries, review files, state JSON, git state.
- **Parallelism + natural decomposition**: Big task → many smaller agents.
- **Orchestrator is thin coordinator**, not the holder of all context.

#### How Robustness Goals Are Preserved or Strengthened

- Plan fidelity via design doc + per-PR scope.
- Thorough review until clean (per-PR reviewer loops + overall memory).
- Evidence culture via personas.
- Test requirements can be explicitly called out in the design doc, PR plan, or `--instructions`.
- For Tachikoma UI: You can require TestBackend + specific assertions per widget/view in the plan.

### Comparison

| Aspect                    | Current `/pipeline`          | `/implement`                  | `/design` + `/execute-plan`              |
|---------------------------|------------------------------|-------------------------------|------------------------------------------|
| Context model             | One growing lead session     | Resumable subagents           | Worktree-isolated + resumable per PR     |
| Parallelism               | Limited (reviews only)       | Limited (reviewers)           | High (across PR levels)                  |
| Resumability              | Poor                         | Good (via memory + files)     | Excellent (`--resume`, state file)       |
| Token scaling on big work | Poor (24M+ observed)         | Better                        | Best                                     |
| Upfront structure         | Low                          | Medium                        | Higher (design doc first)                |
| Output                    | Changes in working tree      | Changes in working tree       | Stack of reviewable PRs (Graphite or git)|
| Best for                  | Quick full-flow runs         | Medium tasks                  | Non-trivial / ambitious work             |

### Recommendations

- **Trivial changes**: `trivial: true` in `/pipeline`, or just direct edits + `/review` / test run.
- **Medium changes**: `/implement --effort 2` or `--effort 3`.
- **Anything that would have been a big pipeline run** (new features, major UI work, complex logic): 
  1. `/design "..."` (get reviewed PR plan + buy-in)
  2. `/execute-plan path/to/design.md --concurrency 4`
- Mandate Tachikoma testing rules in the design doc or via `--instructions`.
- Continue using the practices from `token-efficiency.md` and `AGENTS.md` (artifacts, summaries, `todo_write`, read from disk, `git diff`, concise evidence) inside whichever skill you choose.

The newer skills were built precisely to solve the class of problem that produced the 24–25M token run while keeping (and in some ways strengthening) the quality bar.

---

## References in This Repo

- `.grok/skills/pipeline/SKILL.md`
- `.grok/docs/token-efficiency.md`
- `.grok/docs/benchmark-token-efficiency-plan.md`
- `.grok/personas/*.toml`
- `~/.grok/bundled/skills/implement/SKILL.md`
- `~/.grok/bundled/skills/execute-plan/SKILL.md`
- `~/.grok/bundled/skills/design/SKILL.md`
- `~/.grok/bundled/skills/shared/personas/`
- `AGENTS.md`

---

## Notes for Later Use

- To reproduce the token analysis: the Python snippets used to parse `unified.jsonl` for `shell.turn.inference_done` events (per-SID aggregation, peak prompt size).
- The 24M+ run was a full pipeline-style effort (large scope with multiple subagents: plan/explore/general-purpose).
- Future work could further reduce lead overhead by making even the top-level orchestration more checkpointed/stateless between major phases.

This document captures the key facts, numbers, and architectural discussion for reference at home or for committing to the repo.