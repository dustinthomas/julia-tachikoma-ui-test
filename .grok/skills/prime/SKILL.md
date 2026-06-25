---
name: prime
description: Orient yourself with the current codebase. Use when starting work in a new or unfamiliar project, or to refresh context. Reads project rules, structure, and key files.
when-to-use: Before major work, after switching projects, or when the user says "prime" or "orient yourself".
user-invocable: true
allowed-tools: list_dir, read_file, grep, run_terminal_command
---

# Prime — Orient with the Codebase

Execute the steps below, then give a structured summary of your understanding.

## Step 1: Project structure
- Run `git ls-files` or use list_dir + grep to get an overview of tracked files.
- List top-level directories and key files (README, package.json / Project.toml, src/, test/, etc.).

## Step 2: Read project rules
- Read `AGENTS.md`, `CLAUDE.md`, or any `.grok/rules/` or `.claude/` rule files in the root.
- Note hard rules, coding style, tech stack, and workflow requirements.

## Step 3: Read roadmap / docs if present
- Look for `specs/roadmap.md`, README, docs/, or equivalent.
- Summarize current state and priorities.

## Step 4: Explore key areas
Use Grep and read_file to answer:
- What is the main purpose of this app?
- Tech stack (languages, frameworks, DB)?
- Main directories and responsibilities?
- Build / test / run commands (from package.json, Makefile, scripts/, etc.)?
- Any special conventions (imports, naming, security)?

## Step 5: Summarize
Provide this exact structure:

1. **Project purpose**
2. **Tech stack**
3. **Key conventions** (style, hard rules, architecture)
4. **Current state** (layers complete / in progress)
5. **Project structure** (main dirs)
6. **Development workflow** (how to build, test, run)

Be concise but thorough. End with "Primed and ready."
