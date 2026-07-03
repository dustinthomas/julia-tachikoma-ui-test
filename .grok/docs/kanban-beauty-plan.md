# QCI Kanban — Beautiful Jira-Inspired TUI Feature Plan

**Status**: Ready (0 open issues from design review, 2026-07-02)  
**Source**: Derived from full `/tmp/grok-design-doc-388ef071.md` (see that file for full details, Mermaid diagrams, and code sketches).

**For all agents (Grok Build, subagents, etc.)**:
- Before touching anything in this plan, **read**:
  1. `.grok/docs/tachikoma-core.md`
  2. `.grok/docs/tachikoma-ui-testing.md`
  3. `AGENTS.md` (especially Julia + Tachikoma rules and always-run-the-app)
  4. This file

All work **must** follow strict project invariants:
- UI changes = 100% `TestBackend` coverage (`find_text` / `row_text` / `char_at` / `visual_rows` + re-render after every `update!`).
- Gate tests always start from raw `KanbanModel() + :memory: + load_users!` (USERS=0 + exact "No users — press [c] to create account").
- After **any** change to `src/`, models, gate, view, or layout: run the mandatory live verification + capture evidence (see `.grok/rules/always-run-the-app-after-changes.md`).

---

## Current State (High-Level)

Solid foundation built incrementally:
- 5-column board (Backlog / To Do / In Progress / Review / Done)
- Keyboard navigation + moves (`h/l/j/k`, `< >`)
- Card create/edit/delete via modal (title + desc + priority)
- Calendar view
- Login gate + create account + admin wipe + fake JWT
- SQLite persistence + seeding
- Excellent TestBackend discipline + `visual_rows` helper
- QCI navy + cyan branding + retro terminal logo

**Current limitations (sparse)**:
- Cards are single-line truncated text with very little visual encoding.
- No search/filters (the `search` field is dead).
- No WIP limits, swimlanes, labels, rich detail, bulk actions, etc.
- Limited use of Tachikoma widgets/Canvas for beauty.

---

## Vision

A **beautiful**, information-dense but scannable Jira-inspired Kanban TUI that feels native and delightful in the terminal, while staying 100% testable and following Elm + Tachikoma best practices.

Key beauty elements:
- Rich cards (priority glyphs/badges/colors, due indicators, labels, avatars)
- Powerful yet simple navigation (search + quick filters)
- Structure (WIP limits with visual feedback)
- Depth (card detail modal with desc, comments stub, history)
- Polish (responsive layouts, no-bleed overlays, QCI-consistent styling, selective Canvas accents)

---

## Key Decisions (Summary)

1. **Strict gate + TestBackend first** — every relevant PR must re-verify raw gate + live `kanban()` + `.tach` evidence.
2. **Incremental on existing patterns** — enhance the current manual render loop + `split_layout` rather than big rewrites initially.
3. **Additive DB only** — labels/comments as extensions (JSON TEXT for labels in phase 1).
4. **Responsive + small-terminal first** — rich features degrade gracefully.
5. **Very small PR slices** — one focused beauty increment per PR so they are independently reviewable.
6. **Canvas for accents only** (badges, highlights) — text + `char_at` remains the primary verification path.
7. **Modal detail first**, sidebar only on very wide terminals.

Full rationale and layout risk analysis are in the main design doc.

---

## PR Roadmap (8 Incremental Slices)

**Every PR must contain this verification checklist** (and actually execute it + attach evidence):
- Raw gate TestBackend from `KanbanModel() + :memory: + load_users!` (USERS=0 + exact prompt via `find_text`/`row_text` + `visual_rows`).
- Full `Pkg.test()` + 100% on changed UI paths.
- Live: `julia --project=. -e 'using QciKanban; QciKanban.kanban()'` (confirm gate + 'c' create flow).
- `record_demo` / `record_app` producing `.tach` + before/after evidence.
- Targeted no-bleed + responsive checks.
- Evidence bundle in PR/agent_logs.

### 1. Activate dead `search` + pure filter helper
- [x] Wire the existing unused `search` field.
- [x] Add '/' handler + `apply_filters_and_sort`.
- [x] No visual change yet.
- **Deps**: none

**Status**: DONE (2026-07-02, TDD gate passed, all checklist evidence)

### 2. Rich card foundation (1-line badges/colors/due/avatars)
- On the *existing* 1-line render path.
- Add priority glyph (▌ etc.), color prefixes, better due suffix, avatar improvement.
- Use `char_at` for glyphs in tests.
- **Deps**: PR1

### 3. Rich card multi-line + responsive contract
- [x] Extract `render_rich_card!`.
- [x] 2-line support when column width allows.
- [x] Full "Rich Card Render Contract" (y-step rules, overflow guards, small-terminal fallback to 1-line).
- **Deps**: PR2

**Status (2026-07-02)**: DONE via TDD (PR3) - TestBackend raw gate + 19/19 contract tests green, helper + responsive impl, live/record evidence.

### 4. Search bar + quick filters UI + header polish
- Top search input + chips (High / Due Soon / Mine).
- Live filtering + dimming.
- WIP hints in headers.
- **Deps**: PR1 + PR3
- **Status**: [x] DONE (verified 2026-07-02: explicit bar_area split layout, chips ○/●High etc visible via TestBackend row after login, Pkg green, raw gate, .tach)

### 5. Column WIP limits + visuals
- [x] Model + light DB config for limits.
- [x] Header "(3/5)" + over-limit border styling.
- **Deps**: PR3

**Status**: DONE (2026-07-02, TDD gate passed with TestBackend raw gate + headers + over red styling + full checklist)

### 6. Card detail modal (rich view)
- New modal state for viewing (not just editing).
- Full description, comments stub, labels, due editor.
- Integrate existing `due_date` data.
- Strong no-bleed over rich board.
- **Deps**: PR3
- **Status**: DONE via strict TDD (2026-07-02): raw gate + TestBackend 'v'/'e'/esc, populate, no-bleed, desc/due/prio shown, full Pkg+coverage+record+live verif.

### 7. Swimlanes + basic bulk multi-select (scoped)
- Toggle swimlane grouping (assignee or priority in phase 1).
- Space to multi-select + simple bulk actions.
- **Deps**: PR4 + PR6
- **Status**: [x] VERIFIED + APPROVED by user (2026-07-02). Raw gate + TestBackend + 's'/' ' bulk evidence. Sequential presentation followed.

### 8. Polish, list/reports, settings, integration + full verification
- Upgrade list view.
- BarChart reports stub.
- Settings / config.
- Final responsive polish, help updates, end-to-end evidence.
- QCI logo polish: fix overlap with UI elements (header/board), improve visual quality (better scaling, positioning or Canvas variant), ensure no-bleed and TestBackend verifiable (rows/char_at) on various terminal sizes. Add to header constraints if needed.
- Resolve remaining Open Questions.
- **Deps**: all previous
- **Status**: [x] VERIFIED post-PR7 approval (2026-07-02): logo compact (h=2 on board) + early return no-bleed render; TestBackend checks pass (QCI in logo rows, Backlog in content); raw gate preserved; PR8 stubs upgraded. Full checklist + record + targeted green. Sequential after PR7 user approval. Logo addressed.

---

## How to Choose & Execute

The user (you) will pick which PR(s) to do next.

When a PR is chosen:
1. Read this file + the core Tachikoma docs again.
2. Start with failing TestBackend tests (TDD style) where possible.
3. Implement the minimal slice.
4. Run the full verification checklist (raw gate + live + .tach + Pkg.test).
5. Capture evidence in `agent_logs/` or the PR.

Full detailed sketches (Mermaid, render loop diffs, DB migration helper, "Rich Card Render Contract" assertions, scaffolding appendix) live in the original design document at `/tmp/grok-design-doc-388ef071.md`.

---

**Ready for selection.** Tell me which PR number(s) or feature area you want to tackle first (or if you want me to expand any section here).