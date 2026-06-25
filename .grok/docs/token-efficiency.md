# Token Efficiency Improvements for the Pipeline

**Status**: Implemented 2026-06-22
**Core Constraint**: Keep `reasoning_effort = "high"` on mercury-2 for coder persona (highest quality first pass).

## Goals
- Dramatically reduce lead context size (was hitting 140k+ prompt tokens)
- Reduce input size to subagents (especially coder)
- Reduce output size from validator
- Improve focus and signal-to-noise
- Preserve all quality guarantees: verbatim evidence on critical claims, re-audits, file-quoting by reviewers, plan fidelity

## Implemented Changes

### 1. Phase Summary Protocol (mandatory)
After every major phase (Plan, Scout, each Implement attempt, Validate), the **lead** produces a concise summary:

**Required sections** (keep under ~800 tokens):
- What was accomplished
- Key decisions / tradeoffs
- Files created or changed (list only)
- Open risks or follow-ups
- Relevant todo status

**Artifacts**:
- Lead writes `phase-N-summary.md` (or `plan-summary.md`, `scout-summary.md`, `implement-attempt-N-summary.md`) into the target directory.
- Future subagent prompts reference the summary + specific sections of the original plan.

### 2. Validator Evidence Discipline
**Before**: "Report EVERY command with: exact command, exit_code, verbatim tail (~last 20 lines)."

**After**:
- "Report: exact command, exit_code, and **concise evidence** (the last 5-8 lines or the lines containing errors/warnings only).
- Full tail only required when:
  - The command failed, or
  - You are claiming 'all pass' (for the evidence audit step)
- For successful non-critical commands, one-line summary + exit code is acceptable.
- Always still execute the command yourself."

This was the single biggest output bloat source.

### 3. Structured Minimal Context to Subagents
Standard prompt skeleton for coder (and similar for others):

```
You are the Coder persona (mercury-2, high reasoning).

Task: <short task>
Relevant Plan sections: Phase X + Y (see plan.md)
Phase Summary (previous): <short text or reference to summary.md>
Scout highlights (key patterns only): <bullet list from scout-report.md>

Instructions:
- Implement ONLY the scope in the referenced plan phases.
- Read plan.md and phase summaries from the working directory.
- Do NOT paste or re-explain the full previous plan/scout report/code in your thinking unless you are directly modifying it.
- When you modify existing files, provide clear before/after context for the changed sections only.
- End with "Implementation Complete" + list of files touched.
```

Similar tightening applied to reviewer prompts (now primarily `git diff` + targeted files + plan excerpt).

### 4. Artifact-First Passing
After each phase the lead (or the subagent when instructed) writes persistent artifacts in the target cwd:
- `plan.md`
- `scout-report.md`
- `implementation-notes.md` or per-attempt `changes-attempt-N.diff`
- `validation-evidence.md` (concise version)

Subagents are told: "Prefer reading these files from disk over relying on pasted text."

### 5. todo_write as Primary State
- Lead maintains a living todo list that tracks phases + current sub-task.
- Every subagent prompt includes the **current relevant todos** (not the entire history).
- Subagents are expected to call `todo_write` to mark progress.

### 6. Reviewer Scope Tightening
- Pass the actual `git diff` (or list of changed files + excerpts) + the specific plan section.
- "Review ONLY the diff against the plan for your lens. Quote verbatim only from the modified lines + the plan."

### 7. Recommended Spawn Flags & Isolation
In pipeline skill examples and lead practice:
- Coder attempts: `isolation: "worktree"` (or explicit `cwd` to isolated dir)
- Light roles (scout, some reviews): `--no-memory --no-leader --disable-web-search` where safe
- Validator: `capability_mode: execute`

### 8. Other Patterns
- Scout reports must stay concise (file:line + short snippets).
- Lead summarizes long validator outputs before feeding to next coder or reviewer.
- For follow-on work on the same project, consider reusing `scout-report.md` + `plan.md` unless the architecture or stack changed.

## What Was NOT Changed
- `reasoning_effort = "high"` on mercury-2 coder persona (user requirement for highest first-pass quality).
- Core evidence rules (execute yourself, re-audit on "all pass", reviewers must open files and quote exactly).
- The overall Plan → Scout → Implement/Validate ↔ Review loop.

## Expected Impact (based on Tetris run analysis)
- Lead prompt tokens: major reduction (no more full 20k+ scout reports or 50-line command logs pasted repeatedly)
- Coder input: significantly smaller and more focused
- Validator output: ~50-70% smaller on average
- Reviewers: much smaller focused diffs instead of entire codebases
- Overall session context: much healthier, fewer cache misses on repeated context

## How to Use Going Forward
When invoking the pipeline:
- The lead will now automatically produce summaries and artifacts.
- When manually spawning subagents for pipeline work, copy the tightened prompt skeletons from this document + the updated pipeline skill.

See also:
- Updated `.grok/skills/pipeline/SKILL.md`
- Updated personas in `.grok/personas/`
- AGENTS.md (new section)

---
Last updated: 2026-06-22
