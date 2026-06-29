# ═══════════════════════════════════════════════════════════════════════
# ParticleLife — Self-contained CPU-only Particle Life TUI (Tachikoma)
#
# Elm-style: @tachikoma_app, mutable struct <: Model, should_quit, update!, view.
# Pure CPU simulation (no GPU): positions/vels, pairwise signed g forces with cutoff,
# damped integrate (v=(v+F)*visc), pos update, bounce bounds. Emergent self-org.
# Artistic modern UI: vibrant multi-color braille Canvas sim pane + clean controls.
# All paths covered by TDD + direct TestBackend visual tests (char_at/row/find_text).
# Run: julia --project=particle-life -e 'using ParticleLife; ParticleLife.particle_life()'
# ═══════════════════════════════════════════════════════════════════════

module ParticleLife

using Tachikoma
import Random
@tachikoma_app
import Tachikoma: pre_render!

export Particle, create_particles, apply_forces!, integrate!, clamp_bounds!,
       random_rules!, symmetric_rules!, ParticleLifeModel, create_model,
       step_sim!, advance_sim!, reset_particles!, pulse!, particle_life,
       length_particles, set_dt!, set_viscosity!, adjust_n!

# ── Core simulation types and pure CPU primitives (TDD-first) ────────────

"Particle with position, velocity and group id (0-based for matrix indexing)"
@kwdef mutable struct Particle
    x::Float64 = 0.0
    y::Float64 = 0.0
    vx::Float64 = 0.0
    vy::Float64 = 0.0
    group::Int = 0
end

const DEFAULT_WORLD_W = 300.0
const DEFAULT_WORLD_H = 300.0
const DEFAULT_CUTOFF = 80.0
const DEFAULT_VISC = 0.5
const DEFAULT_DT = 1.0
const DEFAULT_N_PER_GROUP = 40   # limited for fluid CPU (total ~160); N^2 ~ 4*40^2 ~6.4k ops/frame + substeps ok
const NUM_GROUPS = 4

"Create initial particles randomly placed, zero vel, balanced groups."
function create_particles(n_per::Int = DEFAULT_N_PER_GROUP;
                          w::Real = DEFAULT_WORLD_W,
                          h::Real = DEFAULT_WORLD_H)
    ps = Particle[]
    for g in 0:(NUM_GROUPS-1)
        for _ in 1:n_per
            push!(ps, Particle(
                x = 10 + Random.rand() * (w - 20),
                y = 10 + Random.rand() * (h - 20),
                vx = 0.0, vy = 0.0,
                group = g
            ))
        end
    end
    ps
end

"""
    apply_forces!(ps, rules::Matrix{Float64}, cutoff=DEFAULT_CUTOFF, dt=DEFAULT_DT)

In-place pairwise force accumulation into velocities (F = g / d ; fx += F*dx ...).
Does NOT integrate or move positions. Pure CPU double loops.
rules[i+1, j+1] is force coefficient that group-i feels from group-j.
dt scales the force impulse for tunable time step.
"""
function apply_forces!(ps::Vector{Particle}, rules::Matrix{Float64}, cutoff::Float64 = DEFAULT_CUTOFF, dt::Float64 = DEFAULT_DT)
    n = length(ps)
    # zero temp accums? we add to existing v later in integrate
    for i in 1:n
        a = ps[i]
        fx = 0.0; fy = 0.0
        gi = a.group + 1
        for j in 1:n
            j == i && continue
            b = ps[j]
            dx = a.x - b.x
            dy = a.y - b.y
            d2 = dx*dx + dy*dy
            d = sqrt(d2)
            if d > 0 && d < cutoff
                g = rules[gi, b.group + 1]
                F = g / d
                fx += F * dx * dt
                fy += F * dy * dt
            end
        end
        # accumulate into v (will be damped in integrate)
        a.vx += fx
        a.vy += fy
        ps[i] = a   # since mutable struct but to be explicit
    end
    ps
end

"""
    integrate!(ps, viscosity=DEFAULT_VISC, dt=DEFAULT_DT)

v = (v + F)*visc ; x += v*dt   (F already added scaled by dt in apply)
"""
function integrate!(ps::Vector{Particle}, viscosity::Float64 = DEFAULT_VISC, dt::Float64 = DEFAULT_DT)
    for i in eachindex(ps)
        p = ps[i]
        p.vx = (p.vx) * viscosity
        p.vy = (p.vy) * viscosity
        p.x += p.vx * dt
        p.y += p.vy * dt
        ps[i] = p
    end
    ps
end

"""
    clamp_bounds!(ps; w=DEFAULT_WORLD_W, h=DEFAULT_WORLD_H)

Bounce: reverse vel component on wall hit, clamp pos inside.
"""
function clamp_bounds!(ps::Vector{Particle};
                       w::Float64 = DEFAULT_WORLD_W,
                       h::Float64 = DEFAULT_WORLD_H)
    for i in eachindex(ps)
        p = ps[i]
        if p.x <= 0
            p.x = 0; p.vx = -p.vx
        elseif p.x >= w
            p.x = w; p.vx = -p.vx
        end
        if p.y <= 0
            p.y = 0; p.vy = -p.vy
        elseif p.y >= h
            p.y = h; p.vy = -p.vy
        end
        ps[i] = p
    end
    ps
end

"Full sim step (more ref-faithful): per (target_group, source_group) pair: accumulate forces for targets then integrate+bound those targets immediately (interleaved visc/pos like original rule() calls)."
function step_particles!(ps::Vector{Particle}, rules::Matrix{Float64};
                         cutoff::Float64=DEFAULT_CUTOFF, viscosity::Float64=DEFAULT_VISC,
                         dt::Float64=DEFAULT_DT,
                         w::Float64=DEFAULT_WORLD_W, h::Float64=DEFAULT_WORLD_H)
    n = length(ps)
    for gi in 0:(NUM_GROUPS-1)
        # accumulate for this gi from all gj (or do per gj + integrate per gj for closer interleaving)
        for gj in 0:(NUM_GROUPS-1)
            g = rules[gi+1, gj+1]
            # temp per-particle for this pair only (to apply visc per pair like ref)
            for i in 1:n
                a = ps[i]
                a.group == gi || continue
                fx = 0.0; fy = 0.0
                for j in 1:n
                    b = ps[j]
                    b.group == gj || continue
                    i==j && continue
                    dx = a.x - b.x; dy = a.y - b.y
                    d = sqrt(dx*dx + dy*dy)
                    if d > 0 && d < cutoff
                        F = g / d
                        fx += F * dx * dt
                        fy += F * dy * dt
                    end
                end
                # per-pair integrate like ref rule()
                a.vx = (a.vx + fx) * viscosity
                a.vy = (a.vy + fy) * viscosity
                a.x += a.vx * dt
                a.y += a.vy * dt
                # immediate bounds per particle (ref style)
                if a.x <= 0; a.x=0; a.vx = -a.vx; end
                if a.x >= w; a.x=w; a.vx = -a.vx; end
                if a.y <= 0; a.y=0; a.vy = -a.vy; end
                if a.y >= h; a.y=h; a.vy = -a.vy; end
                ps[i] = a
            end
        end
    end
    ps
end

"Fast in-place SoA version of the faithful per-pair step (used by model for CPU perf)."
function step_soa!(xs::Vector{Float64}, ys::Vector{Float64}, vxs::Vector{Float64}, vys::Vector{Float64}, grps::Vector{Int},
                   rules::Matrix{Float64}; cutoff::Float64=DEFAULT_CUTOFF, viscosity::Float64=DEFAULT_VISC,
                   dt::Float64=DEFAULT_DT,
                   w::Float64=DEFAULT_WORLD_W, h::Float64=DEFAULT_WORLD_H)
    n = length(xs)
    for gi in 0:(NUM_GROUPS-1)
        for gj in 0:(NUM_GROUPS-1)
            g = rules[gi+1, gj+1]
            for i in 1:n
                grps[i] == gi || continue
                fx = 0.0; fy = 0.0
                for j in 1:n
                    grps[j] == gj || continue
                    i == j && continue
                    dx = xs[i] - xs[j]; dy = ys[i] - ys[j]
                    d = sqrt(dx*dx + dy*dy)
                    if d > 0 && d < cutoff
                        F = g / d
                        fx += F * dx * dt
                        fy += F * dy * dt
                    end
                end
                vxs[i] = (vxs[i] + fx) * viscosity
                vys[i] = (vys[i] + fy) * viscosity
                xs[i] += vxs[i] * dt
                ys[i] += vys[i] * dt
                if xs[i] <= 0; xs[i] = 0; vxs[i] = -vxs[i]; end
                if xs[i] >= w; xs[i] = w; vxs[i] = -vxs[i]; end
                if ys[i] <= 0; ys[i] = 0; vys[i] = -vys[i]; end
                if ys[i] >= h; ys[i] = h; vys[i] = -vys[i]; end
            end
        end
    end
end

# ── Rule matrix helpers ─────────────────────────────────────────────────

function random_rules!()
    rules = Random.rand(NUM_GROUPS, NUM_GROUPS) .* 2.0 .- 1.0   # -1..1
    # bias slightly for life-like (more attraction between some)
    for i in 1:NUM_GROUPS
        rules[i,i] *= 0.6
    end
    rules
end

function symmetric_rules!(base = nothing)
    if base === nothing
        base = Random.rand(NUM_GROUPS, NUM_GROUPS) .* 1.6 .- 0.8
    end
    r = copy(base)
    for i in 1:NUM_GROUPS, j in i+1:NUM_GROUPS
        avg = (r[i,j] + r[j,i]) * 0.5
        r[i,j] = avg; r[j,i] = avg
    end
    # self a bit more negative for clustering
    for i in 1:NUM_GROUPS; r[i,i] = clamp(r[i,i] - 0.1, -0.8, 0.6); end
    r
end

# provide defaults using Random
"Default interesting starting rules (hand tuned for clusters)"
function default_rules()
    r = zeros(NUM_GROUPS, NUM_GROUPS)
    # tuned to produce nice life (from ref patterns)
    r[1,1] = -0.32; r[1,2] = -0.17; r[1,3] =  0.34; r[1,4] = -0.2
    r[2,1] = -0.2 ; r[2,2] = -0.1 ; r[2,3] = -0.34; r[2,4] =  0.15
    r[3,1] =  0.3 ; r[3,2] =  0.2 ; r[3,3] = -0.15; r[3,4] = -0.25
    r[4,1] = -0.25; r[4,2] =  0.25; r[4,3] = -0.1 ; r[4,4] = -0.08
    r
end

# ── Tachikoma Model ─────────────────────────────────────────────────────

@kwdef mutable struct ParticleLifeModel <: Model
    quit::Bool = false
    tick::Int = 0
    # SoA for CPU-optimized in-place simulation (per plan)
    xs::Vector{Float64} = Float64[]
    ys::Vector{Float64} = Float64[]
    vxs::Vector{Float64} = Float64[]
    vys::Vector{Float64} = Float64[]
    grps::Vector{Int} = Int[]
    rules::Matrix{Float64} = default_rules()
    running::Bool = true
    viscosity::Float64 = DEFAULT_VISC
    dt::Float64 = DEFAULT_DT
    cutoff::Float64 = DEFAULT_CUTOFF
    n_per_group::Int = DEFAULT_N_PER_GROUP
    world_w::Float64 = DEFAULT_WORLD_W
    world_h::Float64 = DEFAULT_WORLD_H
    message::String = "Particle Life • fluid CPU"
    substeps::Int = 4   # for fluidity / visible motion per frame when running
    pulse::Int = 0
end

# Convenience for tests / public API (Vector{Particle} view of SoA when needed)
function particles(m::ParticleLifeModel)
    n = length(m.xs)
    [Particle(m.xs[i], m.ys[i], m.vxs[i], m.vys[i], m.grps[i]) for i in 1:n]
end
length_particles(m::ParticleLifeModel) = length(m.xs)

should_quit(m::ParticleLifeModel) = m.quit

function create_model(; kwargs...)
    m = ParticleLifeModel(; kwargs...)
    if isempty(m.xs)
        ps = create_particles(m.n_per_group; w=m.world_w, h=m.world_h)
        resize!(m.xs, length(ps)); resize!(m.ys, length(ps))
        resize!(m.vxs, length(ps)); resize!(m.vys, length(ps)); resize!(m.grps, length(ps))
        for (i,p) in enumerate(ps)
            m.xs[i]=p.x; m.ys[i]=p.y; m.vxs[i]=p.vx; m.vys[i]=p.vy; m.grps[i]=p.group
        end
    end
    m
end

function reset_particles!(m::ParticleLifeModel)
    ps = create_particles(m.n_per_group; w=m.world_w, h=m.world_h)
    n = length(ps)
    resize!(m.xs, n); resize!(m.ys, n); resize!(m.vxs, n); resize!(m.vys, n); resize!(m.grps, n)
    for (i,p) in enumerate(ps)
        m.xs[i]=p.x; m.ys[i]=p.y; m.vxs[i]=p.vx; m.vys[i]=p.vy; m.grps[i]=p.group
    end
    m.tick = 0
    m.pulse = 0
    m.message = "reset"
    m
end

function random_rules_model!(m::ParticleLifeModel)
    m.rules = random_rules!()
    m.message = "random rules"
    m
end

function symmetric_rules_model!(m::ParticleLifeModel)
    m.rules = symmetric_rules!(m.rules)
    m.message = "symmetrized"
    m
end

"Load a few hand-crafted pleasing presets (from ref patterns + tuning)"
function load_preset!(m::ParticleLifeModel, which::Int=1)
    r = zeros(NUM_GROUPS, NUM_GROUPS)
    if which == 1
        # clusters / worms
        r[1,1]=-0.32; r[1,2]=-0.17; r[1,3]=0.34; r[1,4]=-0.20
        r[2,1]=-0.20; r[2,2]=-0.10; r[2,3]=-0.34; r[2,4]=0.15
        r[3,1]=0.30; r[3,2]=0.20; r[3,3]=-0.15; r[3,4]=-0.25
        r[4,1]=-0.25; r[4,2]=0.25; r[4,3]=-0.10; r[4,4]=-0.08
    elseif which == 2
        # more chaotic / orbiting
        r[1,1]= 0.1; r[1,2]=-0.4; r[1,3]= 0.2; r[1,4]=-0.3
        r[2,1]=-0.3; r[2,2]= 0.2; r[2,3]=-0.5; r[2,4]= 0.1
        r[3,1]= 0.4; r[3,2]=-0.1; r[3,3]= 0.0; r[3,4]= 0.3
        r[4,1]=-0.2; r[4,2]= 0.4; r[4,3]=-0.3; r[4,4]=-0.1
    else
        r = default_rules()
    end
    m.rules = r
    m.message = "preset $which"
    m
end

function advance_sim!(m::ParticleLifeModel; steps::Int=1, force::Bool=false)
    if (!m.running && !force) || isempty(m.xs); return m; end
    for _ in 1:steps
        step_soa!(m.xs, m.ys, m.vxs, m.vys, m.grps, m.rules;
                  cutoff = m.cutoff, viscosity = m.viscosity, dt = m.dt,
                  w = m.world_w, h = m.world_h)
    end
    m.tick += 1
    if m.pulse > 0; m.pulse = max(0, m.pulse - 1); end
    m
end

# Back-compat for older call sites / tests; delegates to advance
function step_sim!(m::ParticleLifeModel; steps::Int = m.substeps)
    advance_sim!(m; steps=steps, force=false)
end

function pulse!(m::ParticleLifeModel; strength::Float64 = 0.8)
    n = length(m.xs)
    for i in 1:n
        if Random.rand() < 0.6
            m.vxs[i] += (Random.rand()-0.5) * strength * 1.5
            m.vys[i] += (Random.rand()-0.5) * strength * 1.5
        end
    end
    m.pulse = 8
    m.message = "pulse!"
    m
end

function toggle_pause!(m::ParticleLifeModel)
    m.running = !m.running
    m.message = m.running ? "running" : "paused"
    m
end

function set_dt!(m::ParticleLifeModel, v::Real)
    m.dt = clamp(Float64(v), 0.05, 5.0)
    m.message = "dt=$(round(m.dt, digits=2))"
    m
end

function set_viscosity!(m::ParticleLifeModel, v::Real)
    m.viscosity = clamp(Float64(v), 0.01, 0.99)
    m.message = "visc=$(round(m.viscosity, digits=2))"
    m
end

function adjust_n!(m::ParticleLifeModel, target_total::Int)
    target_per = max(1, round(Int, target_total / NUM_GROUPS))
    target_per = min(target_per, 1000)  # cap ~4000 particles
    current_per = isempty(m.xs) ? 0 : length(m.xs) ÷ NUM_GROUPS
    if target_per == current_per
        m.n_per_group = target_per
        return m
    end
    if target_per > current_per
        delta = target_per - current_per
        for g in 0:(NUM_GROUPS-1)
            for _ in 1:delta
                push!(m.xs, 10 + Random.rand() * (m.world_w - 20))
                push!(m.ys, 10 + Random.rand() * (m.world_h - 20))
                push!(m.vxs, 0.0)
                push!(m.vys, 0.0)
                push!(m.grps, g)
            end
        end
    else
        # trim keeping first target_per of each original group block (balanced)
        new_xs = Float64[]; new_ys = Float64[]; new_vxs = Float64[]; new_vys = Float64[]; new_grps = Int[]
        per_counts = zeros(Int, NUM_GROUPS)
        for i in eachindex(m.xs)
            g = m.grps[i]
            gi = g + 1
            if per_counts[gi] < target_per
                push!(new_xs, m.xs[i]); push!(new_ys, m.ys[i])
                push!(new_vxs, m.vxs[i]); push!(new_vys, m.vys[i]); push!(new_grps, g)
                per_counts[gi] += 1
            end
        end
        m.xs = new_xs; m.ys = new_ys; m.vxs = new_vxs; m.vys = new_vys; m.grps = new_grps
    end
    m.n_per_group = target_per
    m.message = "N=$(target_per * NUM_GROUPS)"
    m
end

function update!(m::ParticleLifeModel, evt::KeyEvent)
    if evt.key == :char && evt.char == 'q'
        m.quit = true
        return
    end
    if evt.key == :char && evt.char == 'r'
        reset_particles!(m)
        return
    end
    if evt.key == :char && evt.char == 'p'
        toggle_pause!(m)
        return
    end
    if evt.key == :char && evt.char == 'x'
        random_rules_model!(m)
        return
    end
    if evt.key == :char && evt.char == 's'
        symmetric_rules_model!(m)
        return
    end
    if evt.key == :char && evt.char == '1'
        load_preset!(m, 1); return
    end
    if evt.key == :char && evt.char == '2'
        load_preset!(m, 2); return
    end
    if evt.key == :char && evt.char == 'u'
        pulse!(m)
        return
    end
    if evt.key == :char && evt.char == '['
        set_dt!(m, m.dt - 0.1)
        return
    end
    if evt.key == :char && evt.char == ']'
        set_dt!(m, m.dt + 0.1)
        return
    end
    if evt.key == :char && evt.char == '-'
        set_viscosity!(m, m.viscosity - 0.05)
        return
    end
    if evt.key == :char && (evt.char == '=' || evt.char == '+')
        set_viscosity!(m, m.viscosity + 0.05)
        return
    end
    if evt.key == :char && (evt.char == ',' || evt.char == '<')
        cur = length(m.xs)
        newt = max(NUM_GROUPS, cur - 40)
        adjust_n!(m, newt)
        return
    end
    if evt.key == :char && (evt.char == '.' || evt.char == '>')
        cur = length(m.xs)
        newt = min(4000, cur + 40)
        adjust_n!(m, newt)
        return
    end

    # Input only here; continuous substeps for fluid animation driven by pre_render! (called per frame by app).
    # pre_render! handles advance ONLY when running. Unhandled keys when paused do NOTHING (no tick, no state change).
    # (Fixes idle key tick advance when paused.)
end

# pre_render! drives fixed-timestep substeps every frame for fluid idle animation (even with no KeyEvents).
# Called by Tachikoma app loop before view (per plan + architecture). View remains pure render.
# Delegates to advance_sim! (with force) for single source of truth on sim advance + tick/pulse.
function pre_render!(m::ParticleLifeModel)
    if m.running
        advance_sim!(m; steps=max(1, m.substeps), force=true)
    end
end

# ── Artistic rendering: clean modern UI with colored Canvas particles ────

# Vibrant artistic palette (RGB chosen for terminal contrast + beauty)
const GROUP_COLORS = [
    ColorRGB(0xff, 0x5e, 0x5b),  # coral red
    ColorRGB(0x5b, 0xe2, 0xff),  # cyan
    ColorRGB(0xff, 0xe1, 0x5b),  # gold yellow
    ColorRGB(0xc4, 0x5b, 0xff),  # magenta violet
]

function view(m::ParticleLifeModel, f::Frame)
    buf = f.buffer
    area = f.area

    # Pure render only. All sim state mutations (advance, tick, pulse) happen in update! via pure helpers.
    # Small guard
    if area.width < 30 || area.height < 10
        set_string!(buf, area.x, area.y, "Particle Life (too small)", Style(; fg = GROUP_COLORS[1], dim=true))
        return
    end

    # Outer artistic block - modern minimal border with title
    outer = Block(
        title = "✧ PARTICLE LIFE ✧",
        border_style = Style(; fg = ColorRGB(0x88, 0x88, 0x99)),
        title_style = Style(; fg = ColorRGB(0xaa, 0xaa, 0xcc), bold = true),
    )
    main = render(outer, area, buf)

    # Layout: main content Fill + status (1)
    layout = Layout(Vertical, [Fill(), Fixed(1)])
    rows = split_layout(layout, main)
    if length(rows) < 2; return; end

    sim_area = rows[1]
    status_area = rows[2]

    # Split sim + right artistic control panel (more breathing room)
    ctrl_w = max(18, min(24, sim_area.width ÷ 4))
    sim_w = max(18, sim_area.width - ctrl_w - 1)
    split = split_layout(Layout(Horizontal, [Fixed(sim_w), Fixed(ctrl_w)]), sim_area)
    canvas_area = split[1]
    ctrl_area = length(split) > 1 ? split[2] : sim_area

    # --- SIM PANE: artistic canvas field (single style for texture) + reliable per-group colored glyphs (no last-wins overwrite) ---
    if canvas_area.width >= 6 && canvas_area.height >= 4
        # IMPORTANT: fully clear the sim area each frame.
        # Without this, old particle glyphs ('●' etc) and braille from previous
        # frames linger (render_canvas skips 0-bit cells; we only draw current stamps).
        # This makes the animation appear frozen even though state advances.
        for dy in 0:(canvas_area.height-1)
            yy = canvas_area.y + dy
            set_string!(buf, canvas_area.x, yy, " "^canvas_area.width)
        end

        # Subtle high-res field texture (one canvas, neutral style)
        c = create_canvas(canvas_area.width, canvas_area.height; style=Style(; fg=ColorRGB(0x55,0x55,0x66), dim=true))
        clear!(c)
        dw, dh = canvas_area.width*2, canvas_area.height*4
        # light procedural field points (stable look, differential safe)
        for i in 1:2:length(m.xs)
            x = m.xs[i]; y = m.ys[i]
            dx = clamp(round(Int, (x / m.world_w)*(dw-1)), 0, dw-1)
            dy = clamp(round(Int, (y / m.world_h)*(dh-1)), 0, dh-1)
            set_point!(c, dx, dy)
            if (i & 3) == 0 && dx+1 < dw; set_point!(c, dx+1, dy); end
        end
        render_canvas(c, canvas_area, f)

        # Now stamp vibrant colored particle glyphs directly on buffer (per-group color guaranteed)
        cw = canvas_area.width
        ch = canvas_area.height
        n = length(m.xs)
        for i in 1:n
            x = m.xs[i]; y = m.ys[i]; g = m.grps[i]
            cx = canvas_area.x + clamp( floor(Int, (x / m.world_w) * cw ), 0, cw-1 )
            cy = canvas_area.y + clamp( floor(Int, (y / m.world_h) * ch ), 0, ch-1 )
            gg = clamp(g + 1, 1, NUM_GROUPS)
            glyph = (g == 0) ? '●' : (g == 1 ? '◆' : (g == 2 ? '▲' : '■'))
            sty = Style(; fg = GROUP_COLORS[gg], bold = (m.pulse > 0))
            set_char!(buf, cx, cy, glyph, sty)
            if cx+1 <= canvas_area.x + cw - 1
                set_char!(buf, cx+1, cy, '•', Style(; fg=GROUP_COLORS[gg], dim=true))
            end
        end
    else
        set_string!(buf, canvas_area.x+1, canvas_area.y+1, "sim", Style(;fg=GROUP_COLORS[2]))
    end

    # --- Right artistic clean controls pane ---
    cx = ctrl_area.x + 1
    cy = ctrl_area.y + 1
    maxcy = bottom(ctrl_area) - 1
    if cy <= maxcy
        set_string!(buf, cx, cy, "CONTROLS", Style(; fg = ColorRGB(0x99,0x99,0xaa), bold=true)); cy += 1
    end
    for h in ["r reset", "x rand", "s sym", "1/2 preset", "p pause/play", "u pulse", "[ ] dt", "- = visc", ", . N", "q quit"]
        cy <= maxcy || break
        set_string!(buf, cx, cy, h, Style(; fg = ColorRGB(0x66,0x66,0x77), dim = !m.running ))
        cy += 1
    end
    cy += 1
    if cy <= maxcy
        set_string!(buf, cx, cy, "N=$(length(m.xs))", Style(; fg = ColorRGB(0x88,0x88,0x99)))
    end
    cy += 1
    if cy <= maxcy
        runsty = m.running ? Style(; fg=ColorRGB(0x5b,0xe2,0x5b), bold=true) : Style(; fg=ColorRGB(0xff,0x88,0x55), bold=true)
        set_string!(buf, cx, cy, m.running ? "RUNNING" : "PAUSED", runsty)
    end
    cy += 1
    if cy <= maxcy
        set_string!(buf, cx, cy, "dt=$(round(m.dt,digits=2))", Style(; fg=ColorRGB(0x88,0x88,0x99)))
    end
    cy += 1
    if cy <= maxcy
        set_string!(buf, cx, cy, "visc=$(round(m.viscosity,digits=2))", Style(; fg=ColorRGB(0x88,0x88,0x99)))
    end

    # Status bar artistic, modern
    if status_area.width >= 10
        left = [Span(" particle life ", Style(; fg=ColorRGB(0xaa,0xaa,0xcc), dim=true))]
        state = m.running ? "RUNNING" : "PAUSED"
        right_str = "$(state)  $(m.message)  tick=$(m.tick)  dt=$(round(m.dt,digits=2))  visc=$(round(m.viscosity,digits=2))"
        right = [Span(right_str, Style(; fg = ColorRGB(0x77,0x77,0x88), dim=true))]
        render(StatusBar(left=left, right=right), status_area, buf)
    end

    # pulse indicator
    if m.pulse > 0 && canvas_area.width > 8
        set_string!(buf, canvas_area.x + 1, canvas_area.y + 1, "✧", Style(; fg=ColorRGB(0xff,0xff,0xff), bold=true))
    end
end

# ── Public runner ───────────────────────────────────────────────────────

"""
    particle_life(; kwargs...)

Launch the interactive Particle Life app. Self-contained.
"""
function particle_life(; kwargs...)
    m = create_model(; kwargs...)
    app(m)
end

const run = particle_life

end # module ParticleLife
