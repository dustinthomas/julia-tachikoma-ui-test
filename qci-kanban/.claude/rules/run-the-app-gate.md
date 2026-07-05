---
paths:
  - "src/**"
  - "test/**"
  - "qci-kanban/src/**"
  - "qci-kanban/test/**"
---

# Run-the-app gate (mandatory)

After ANY change to `qci-kanban/src/`, DB seeding, the login gate, `KanbanModel`/`AppModel`, or `update!`/`view`, tests alone are not sufficient. You must also verify the real app starts correctly:

- Headless (preferred for agents): `julia --project=. -e 'using QciKanban; QciKanban.record_demo2("verify.tach")'` (v2) or `record_demo` (v1), then confirm it completed without error.
- Or a scripted check exercising default DB load + gate render + create-account `'c'` flow via `update!` + TestBackend.
- Confirm the first-time login screen shows "No users — press [c] to create account" with ZERO pre-seeded users (`Stores.seed_demo!` seeds issues/epics/sprints/labels — never users).

Never claim a change is done without this. Report the exact command you ran and its outcome. Delete throwaway `.tach` files afterwards.
