---
name: review
description: Perform a strict code review of the current changes (diff + files). Covers security, correctness, conventions, tests. Use after implementation or before PR.
when-to-use: User asks for review, or at the end of the pipeline before committing.
user-invocable: true
allowed-tools: run_terminal_command, read_file, grep
---

# Code Review Skill

Review the current working tree changes against high standards.

## Steps
1. Get the diff:
   - `git diff` (or `git diff origin/main...HEAD`)
   - `git status`
   - List changed files: `git diff --name-only`
2. Read every changed file (and relevant context).
3. Review through multiple lenses (report separately):
   - **Security**: SQL parameterization, permission checks, no secrets, input sanitization, authz.
   - **Correctness**: logic bugs, edge cases, error handling, contracts (e.g. return tuples), state issues.
   - **Conventions**: style (indent, naming), project patterns from AGENTS.md, imports, structure.
   - **Tests**: Are there tests? Do they cover the change? Both success + error paths?
4. For **every finding**:
   - Quote the offending code **verbatim** from the file (open it and copy exact lines).
   - Include file:line.
   - Assign severity: critical (must fix), warning (should fix), nit (optional).
5. Overall verdict: APPROVE or REQUEST CHANGES (list required fixes).

## Output Format
```
## Code Review

### Security
- ...

### Correctness
- ...

### Conventions
- ...

### Tests
- ...

### Verdict
[APPROVE / REQUEST CHANGES]
Summary of required actions.
```
Be extremely rigorous. Do not approve if critical issues exist. Demand evidence.
