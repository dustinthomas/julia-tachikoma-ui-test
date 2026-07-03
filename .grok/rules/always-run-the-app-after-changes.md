# Agentic Workflow Rule: Always run / verify the app after changes

**See also**: `.grok/docs/tachikoma-ui-testing.md` for the complete UI visual verification methodology (TestBackend + visual_rows + gate rules).

**Mandatory after edits to src/, test/, models, login/gate, db seeding, or anything affecting startup:**

1. Run verification of first-time / login gate using real entry points:
   - `julia --project=. -e 'using QciKanban, Tachikoma as T; m=QciKanban.KanbanModel(); m.db_path = QciKanban.DB.DEFAULT_DB_PATH; QciKanban.load_users!(m); if m.db_path == QciKanban.DB.DEFAULT_DB_PATH; QciKanban.wipe_test_users!(m); end; println("USERS=", length(m.users)); T.update!(m, T.KeyEvent('\''c'\'')); ... full create flow + TestBackend gate checks ...'`
   - Or simply: run `QciKanban.record_demo(...)` 
   - Exercise: raw KanbanModel + load_users! + TestBackend render of gate + 'c' create path.

2. Start the actual app (TUI) to validate the user experience:
   - In a real terminal: `julia --project=. -e 'using QciKanban; QciKanban.kanban()'`
   - Confirm you land on LOGIN screen with **no pre-seeded users** and the prompt: "No users — press [c] to create account"
   - Test the create flow end-to-end interactively at least once.

3. Capture evidence (stdout + any .tach recordings) in your scratch or session logs. Never claim "done" for UI/login/startup changes without this.

This ensures the "first time login / create account" experience and prevents regressions after seeding or gate changes.
