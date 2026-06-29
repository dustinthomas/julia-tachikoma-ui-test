# Particle Life — Terminal TUI

Self-contained CPU-only Particle Life simulator built with Julia + Tachikoma.jl.

Emergent self-organizing patterns from simple pairwise attraction/repulsion forces (no collisions, no GPU).

Beautiful fluid braille-canvas animations, modern artistic clean UI. 100% tested with Tachikoma TestBackend (direct render + update! + find_text/row_text/char_at).

## Run (isolated)

```bash
cd particle-life
julia --project=. -e 'using ParticleLife; ParticleLife.particle_life()'
# or
julia --project=. -e 'using ParticleLife; ParticleLife.run()'
```

Keys (in-app):
- r : reset particles
- x : random rules
- s : symmetrize rules
- p : pause / run
- u : pulse (inject energy)
- space : single step
- q : quit

## Architecture notes

- Pure CPU sim primitives: `create_particles`, `apply_forces!`, `integrate!`, `clamp_bounds!`, `step_particles!` (vector of mutable Particle, N² loops, tuned ~120 particles).
- Ref mechanics: dx = a.x-b.x ; if d<cutoff F=g/d ; vx +=F*dx ; v*=visc ; pos+=v ; bounce.
- Tachikoma Elm: `mutable struct <: Model`, `update!(m, KeyEvent)`, `view(m, Frame)`, `@tachikoma_app`.
- Rendering: multi-style `create_canvas` + `set_point!` + `render_canvas` (braille high-res) layered for vibrant groups + Block/StatusBar chrome.
- Continuous sim advance in `pre_render!` (per-frame substeps when running) for fluid animation even idle/no keys (double-buffer diff safe; view is pure render). pre_render! or equivalent allowed by plan for fluidity.
- All logic + visuals exercised from initial state by real tests.

## Test

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Uses Tachikoma.TestBackend exclusively for visual assertions (no interactive).

## Credits / inspiration

Adapted from hunar4321/particle-life (core <100 LOC algorithm). CPU Julia loops, no external physics/GPU libs. Self-contained subfolder.

## Non-goals (per plan)

No save/load, no evolution, no mouse GUI, no 3D, modest N for real-time fluid CPU.
