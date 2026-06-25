# julia-tachikoma-ui-test

Agentic coding environment for Julia + UI experiments/tests. Replicated from `test-grok-cli`.

This workspace is set up with the full Grok-native multi-agent pipeline:

- `.grok/` — personas (planner, scout, coder, validator, reviewer), skills (pipeline, prime, review, test, commit, caveman), config, safety hooks
- Structured workflow: Plan → Scout → Implement/Validate loop → Review
- Token efficiency practices and verbatim evidence requirements
- Containerized Node policy support (Dockerfile + compose)
- Safety hooks + .env support for custom models (BYOM like Mercury-2)

## Quick Start (Agentic Workflow)

```bash
# In a fresh grok session:
# 1. Prime context
/prime

# 2. For non-trivial work use the full pipeline
/pipeline Add X feature to the Julia UI

# Or trivial mechanical change:
/pipeline trivial: true Fix typo in README
```

Available skills (slash or direct):
- `/pipeline`
- `/prime`
- `/review`
- `/test`
- `/commit`
- caveman mode for terse output

## Environment Replication

Replicated files from `test-grok-cli`:
- `.grok/config.toml`, `personas/*.toml`, `skills/*/SKILL.md`, `hooks/`
- `AGENTS.md`
- `.gitignore`, `.dockerignore`, `.env`
- Docker + compose (adapt for your Julia/UI stack)
- Helper scripts

See `AGENTS.md` for full model routing, BYOM instructions, and workflow rules.

## Project Goals (example)

- Test Julia backend + modern UI/ frontend agentically
- Exercise full Grok pipeline on real Julia + web UI code
- Measure token efficiency, correctness, iteration quality in Tachikoma-themed experiments

## Container Notes

Node.js/TS harness (if any) must run inside Docker per common security policies.

```bash
docker build -t grok-benchmark .
docker run --rm grok-benchmark npm test
```

For Julia parts: adapt `docker-compose.yml` and scripts as needed (see original test-grok-cli particle-life example).

## Next

Edit `.grok/personas/*.toml` to tune models per role if desired.

Start by running `/prime` in your Grok session to orient the agent.

---

Replicated: 2026-06-24 from test-grok-cli agentic setup.
