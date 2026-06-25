# Detailed Benchmark Plan: Token Efficiency & Correctness Before vs After Optimizations

**Date**: 2026-06-22  
**Goal**: Quantitatively measure the impact of the token-efficiency improvements on a realistic coding pipeline while keeping quality (correctness of delivered app) high.  
**Key Constraint**: Keep `reasoning_effort = "high"` for mercury-2 in the coder persona for both runs.

## 1. Benchmark Task (identical for both runs)

**App Name**: Simple Personal Journal Web App

**Required Features** (must be implemented in both runs):
- User registration and login (username + hashed password, SQLite)
- Create, view, edit, delete journal entries
  - Each entry: title + body (markdown or plain text) + timestamp
- List all entries for the logged-in user (newest first)
- Search entries by title
- Basic tagging: add 0-N tags to an entry, filter list by tag
- Simple per-user stats (total entries, entries this month, number of unique tags)
- Clean, usable UI (list + editor view, no heavy frameworks)
- All data persisted in SQLite per user
- Proper session-based auth (protected routes)

**Non-goals** (to keep scope small and comparable):
- No rich text editor
- No export/import
- No images or attachments
- No advanced search or full-text
- Minimal styling (Tailwind CDN is acceptable for both)

**Tech Stack** (fixed for fairness):
- Backend: Python + Flask + sqlite3 (stdlib)
- Auth: Werkzeug password hashing + Flask sessions
- Frontend: Single HTML page + vanilla JS + minimal CSS (Tailwind via CDN allowed)
- No Node, no build step, no external Python packages beyond Flask

**Target Directory Structure** (same for both):
```
journal-app/
├── app.py
├── requirements.txt
├── templates/index.html
├── static/
│   ├── css/styles.css
│   └── js/app.js
├── instance/journal.db   (created at runtime)
├── README.md
└── .gitignore
```

## 2. Two Runs

### Run A: "Before" (Old Patterns)
Use the prompt style and practices that existed before the 2026-06-22 token optimizations:
- Paste full plan text into subagent prompts when relevant
- Paste full scout report into coder prompt
- Use verbose validator instruction ("report EVERY command ... verbatim tail of ~last 20 lines")
- Pass full previous code or full context to reviewers
- No mandatory phase summaries or artifact files in prompts
- No explicit "read plan.md from disk" instructions
- Normal rich context passing as in the original Tetris run

### Run B: "After" (New Optimized Patterns)
Use the patterns documented in `.grok/docs/token-efficiency.md`:
- Lead writes `plan.md`, `scout-report.md`, and short phase summaries after each major stage
- Subagent prompts reference summaries + "read plan.md / scout-report.md from the working directory"
- Minimal context: only relevant plan sections + summary, not full previous outputs
- Validator uses concise evidence (last 5-8 lines or errors; full tail only on failures or "all pass")
- Reviewers receive `git diff` (or list of changed files) + targeted plan excerpt instead of full code
- Heavy use of `todo_write` + passing current todos
- Recommended spawn flags and `isolation`/`cwd` where helpful

**Important**: The *same* model routing remains:
- Planner + Validator + Lead: grok-build
- Scout + Reviewers: grok-composer-2.5-fast
- Coder: mercury-2 with `reasoning_effort = "high"`

## 3. Execution Protocol (same structure for both runs)

Use a completely fresh, isolated directory for each run:
- Run A: `/home/dustin/Git/Projects/benchmark-before-journal`
- Run B: `/home/dustin/Git/Projects/benchmark-after-journal`

Both start with `git init` and no other files.

**Exact Phase Sequence** (no skipping):
1. **Plan** (planner persona, read-only) → write `plan.md` + short plan summary
2. **Scout** (scout persona, read-only) → write `scout-report.md` + short summary
3. **Implement/Validate Loop** (max 3 attempts)
   - Coder (mercury-2 high) implements the current attempt
   - Validator runs checks and reports (using the style for that run)
   - Lead decides next action or success
4. **Review** (3 parallel reviewers)
   - Security, Correctness, Conventions
   - For "After" run: pass diff + plan excerpts
   - For "Before" run: pass full context as before
5. **Lead Summary**

**After each run**:
- Verify the app actually runs (`python app.py` + manual smoke test: register, login, create entry, search, tag, stats)
- Capture final `git diff --stat` and list of files
- Extract token data from `~/.grok/logs/unified.jsonl` using the subagent sids for that run
- Record any review findings (verbatim where possible)

## 4. Token Measurement Method

For both runs, after completion:

1. Identify the session / subagent sids used during that specific benchmark run (via timestamps or explicit logging).
2. Parse `~/.grok/logs/unified.jsonl` for `shell.turn.inference_done` events containing those sids.
3. Aggregate per model:
   - Total prompt_tokens (input)
   - Total completion_tokens (output)
   - Total reasoning_tokens (especially important for mercury high)
   - Number of inference turns per role (Plan, Scout, Coder attempts, Validator, each Reviewer)
4. Also capture:
   - Peak context size in lead turns (if available in signals)
   - How often full plan or full scout report text appeared in prompts (approximate count)
5. Present in tables:
   - By Role / Model
   - By Phase
   - Before vs After side-by-side

Use the same parsing approach previously used (python script on unified.jsonl).

## 5. Correctness / Outcome Evaluation Criteria

For each delivered app:
- Does it meet the feature list above? (binary per feature)
- Does it run without errors on first try?
- Quality notes from the Review phase (number of critical/warning/nit findings, especially correctness and security)
- Code cleanliness and adherence to plan (qualitative + count of "deviations from plan" noted in reviews)
- How completely the final app matches the plan produced in Phase 1

**Overall Correctness Score** (simple):
- Features working / total required
- Critical issues found in review (lower is better)
- Whether the app was usable after the pipeline without further fixes

## 6. Controls for Fair Comparison

- Identical task description
- Identical tech stack and constraints
- Same model assignment (mercury high for coder)
- Same max attempts (3)
- Fresh directories (no carry-over files or .grok state in target dirs)
- Same lead behavior except for the deliberate prompt/context differences being measured
- Same method of extracting tokens and evaluating the final app
- Reviewers will use the style appropriate to the run (diffs for After, fuller context for Before)

## 7. Expected Observations (hypothesis)

- **Token Efficiency**: Significant reduction in lead context size and per-coder prompt size in the "After" run due to summaries + file references instead of full pastes. Lower validator output size.
- **Reasoning Tokens on Mercury**: Should remain similar or slightly lower because high effort is unchanged, but overall input context is smaller → potentially cheaper total run.
- **Correctness**: Should be similar or better in "After" because focused context may reduce noise and hallucinations. Any degradation would be a signal that the optimizations went too far.
- **Lead Overhead**: Much lower context bloat in After.

## 8. Output Deliverable

After both runs and analysis, produce a report containing:
- Side-by-side tables of token usage (by model and by phase)
- Correctness comparison table
- Key excerpts from prompts (example of "Before" vs "After" coder prompt)
- Qualitative observations
- Recommendations for further tuning if any

## 9. Next Steps After This Document

1. User confirms plan.
2. Clear any carry-over context/todos related to previous Tetris work for the benchmark.
3. Create the two clean directories.
4. Execute **Before** run completely (old prompt style).
5. Extract stats for Before.
6. Execute **After** run (new optimized patterns).
7. Extract stats for After.
8. Write the final detailed comparison report.

This experiment will give concrete numbers on whether the changes we made to the pipeline skill, personas, and lead practices deliver measurable token savings while preserving (or improving) the quality of the delivered software.

---
End of Plan Document. Ready to begin when confirmed.