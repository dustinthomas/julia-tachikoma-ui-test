---
name: test
description: Run relevant tests and type checks for changes. Provide verbatim results. Use to validate implementation.
when-to-use: After code changes, or when user says "run tests" or "/test".
user-invocable: true
allowed-tools: run_terminal_command, read_file, grep
---

# Test & Validation Skill

Execute tests and static checks with full evidence.

## Process
1. Detect changed areas (use `git diff --name-only` or context).
2. Run type / lint checks first (e.g. `npx tsc --noEmit`, eslint, etc. if applicable).
3. Identify and run **targeted** tests for the modified code.
4. If no targeted tests exist or change is new, write or update tests that cover the behavior.
5. Run full relevant suite only when requested.
6. For every command executed, report:
   - The exact command
   - exit_code
   - Verbatim tail of output (last 15-30 lines)

## Rules
- Never claim "tests pass" without having run the command in this session.
- "No test needed" requires explicit justification in the report.
- If tests fail, provide root cause analysis + suggested fix.

## Typical Commands (adapt to project)
- TypeScript: `cd frontend && npx tsc --noEmit`
- Unit tests: `npm test -- <pattern>` or `julia --project=. test/run_targeted.jl ...`
- Full: follow package.json scripts or test/runtests.jl

## Report Structure
## Validation Report
### Checks Run
- command: ...
  exit: ...
  output: ...

### Failures (if any)
...

### Verdict
PASS / FAIL + next actions
```

Demand real execution evidence.
