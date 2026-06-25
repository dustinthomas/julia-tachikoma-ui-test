---
name: commit
description: Generate a well-formatted git commit following conventional commits. Stages specific files and creates the commit. Use after completing a change.
when-to-use: User asks to commit, or after finishing implementation and validation.
user-invocable: true
allowed-tools: run_terminal_command, read_file
---

# Git Commit Skill

Create a clean conventional commit for the current changes.

## Instructions
1. Inspect changes:
   - `git status`
   - `git diff HEAD` (or `git diff --staged` if needed)
2. Determine type:
   - `feat:` new feature
   - `fix:` bug fix
   - `chore:` maintenance / deps / config
   - `refactor:`, `test:`, `docs:`, etc.
3. Write description:
   - Present tense ("add", "fix", "update")
   - ≤50 chars
   - Descriptive of the actual change
   - No trailing period
4. Stage **specific** files by name (never `git add .` or `git add -A` unless intentional).
5. Commit with the message.
   - Optionally add body with more detail or "Co-Authored-By" if relevant.
6. Report ONLY the final commit message used (or the full `git log -1` output on success).

## Example good messages
- `feat: add equipment status filter dropdown`
- `fix: prevent SQL injection in user search`
- `chore: update dependencies`

## Output
Return the exact commit message that was committed (nothing else).
