# TDD / BDD / coverage gates (mandatory, v2 work)

These three disciplines are non-negotiable for changes under `qci-kanban/src/`.
The headless Tachikoma methodology (see `julia-tachikoma.md`) is how every test
is written; this rule is about *which* tests must exist and *when*.

## 1. Red-first TDD (behavioral changes)

For any behavioral change — bug fix with a reproducible symptom, new or changed
`update!`/`view` behavior, contract change:

1. Write the failing test FIRST, in the correct existing test file per the
   test-impact map (`qci-kanban-test-map.md`).
2. Run it and **confirm it fails for the expected reason** (a test failing for
   the wrong reason proves nothing). Record the failure output — this red
   evidence must appear in your report and is handed to the verifier.
3. Implement the minimal change to green; refactor only after green.

Presentation-only tweaks (colors, spacing, glyphs) may write tests alongside
the change, but the tests must land in the same change — the implementer owns
them; never defer to "a later testing pass".

## 2. BDD acceptance specs (user-facing features)

Every user-facing feature must be covered by Given/When/Then acceptance tests
in `test/features/` (extend the relevant `phaseN_*.jl`, or add a new feature
file and wire it into `runtests.jl` in the same change). Acceptance specs
assert the user-visible story end to end, driven purely through
`update!(m, KeyEvent(...))` + TestBackend renders — from the real login gate to
the observable outcome. Unit/view tests in `test/test_*.jl` do not substitute
for the acceptance spec; both are required.

## 3. 100% coverage gate (before done)

After ANY change under `src/`, the coverage gate must PASS before the change
is claimed done:

```bash
julia --project=. test/coverage_gate.jl     # runs the suite under coverage + gates
```

- Gated v2 files must be at **100% line coverage**; the gate exits nonzero
  otherwise and prints the uncovered lines.
- Exclusions only via auditable in-source `# COV_EXCL_*` markers, each
  justified in `COVERAGE.md` — never by weakening the gate script.
- Report the exact command + exit code, like every other gate.

## Enforcement

The verifier (`.claude/agents/verifier.md`) re-runs the coverage gate,
checks that behavioral changes came with red-first evidence, and checks that
user-facing features extended `test/features/`. A missing gate run, missing
red evidence, or missing acceptance coverage is a **warning-level finding at
minimum** — the verdict cannot be APPROVED with any of the three absent.
