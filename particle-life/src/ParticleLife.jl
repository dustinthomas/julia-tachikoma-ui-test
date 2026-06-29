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

export Particle, create_particles, apply_forces!, integrate!, clamp_bounds!,
       random_rules!, symmetric_rules!, ParticleLifeModel, create_model,
       step_sim!, reset_particles!, pulse!, particle_life

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
const DEFAULT_N_PER_GROUP = 60   # tuned for fluid CPU N^2 ~ 4*60^2 ~14k ops/frame ok
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
    apply_forces!(ps, rules::Matrix{Float64}, cutoff=DEFAULT_CUTOFF)

In-place pairwise force accumulation into velocities (F = g / d ; fx += F*dx ...).
Does NOT integrate or move positions. Pure CPU double loops.
rules[i+1, j+1] is force coefficient that group-i feels from group-j.
"""
function apply_forces!(ps::Vector{Particle}, rules::Matrix{Float64}, cutoff::Float64 = DEFAULT_CUTOFF)
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
                fx += F * dx
                fy += F * dy
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
    integrate!(ps, viscosity=DEFAULT_VISC)

v = (v + F)*visc ; x += v   (F already added to v by apply)
"""
function integrate!(ps::Vector{Particle}, viscosity::Float64 = DEFAULT_VISC)
    for i in eachindex(ps)
        p = ps[i]
        p.vx = (p.vx) * viscosity
        p.vy = (p.vy) * viscosity
        p.x += p.vx
        p.y += p.vy
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

"Full sim step: forces -> integrate -> bounds. Returns ps for chaining."
function step_particles!(ps::Vector{Particle}, rules::Matrix{Float64};
                         cutoff::Float64=DEFAULT_CUTOFF, viscosity::Float64=DEFAULT_VISC,
                         w::Float64=DEFAULT_WORLD_W, h::Float64=DEFAULT_WORLD_H)
    apply_forces!(ps, rules, cutoff)
    integrate!(ps, viscosity)
    clamp_bounds!(ps; w=w, h=h)
    ps
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
    particles::Vector{Particle} = Particle[]
    rules::Matrix{Float64} = default_rules()
    running::Bool = true
    viscosity::Float64 = DEFAULT_VISC
    cutoff::Float64 = DEFAULT_CUTOFF
    n_per_group::Int = DEFAULT_N_PER_GROUP
    world_w::Float64 = DEFAULT_WORLD_W
    world_h::Float64 = DEFAULT_WORLD_H
    message::String = "Particle Life • fluid CPU"
    substeps::Int = 2   # for fluidity
    pulse::Int = 0
end

should_quit(m::ParticleLifeModel) = m.quit

function create_model(; kwargs...)
    m = ParticleLifeModel(; kwargs...)
    if isempty(m.particles)
        m.particles = create_particles(m.n_per_group; w=m.world_w, h=m.world_h)
    end
    m
end

function reset_particles!(m::ParticleLifeModel)
    m.particles = create_particles(m.n_per_group; w=m.world_w, h=m.world_h)
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

function step_sim!(m::ParticleLifeModel; steps::Int = m.substeps)
    if !m.running || isempty(m.particles); return m; end
    for _ in 1:steps
        step_particles!(m.particles, m.rules;
                        cutoff = m.cutoff, viscosity = m.viscosity,
                        w = m.world_w, h = m.world_h)
    end
    m.tick += 1
    if m.pulse > 0; m.pulse -= 1; end
    m
end

function pulse!(m::ParticleLifeModel; strength::Float64 = 0.8)
    # inject kinetic energy / small outward-ish perturbation on some
    n = length(m.particles)
    for i in 1:n
        if Random.rand() < 0.6
            p = m.particles[i]
            p.vx += (Random.rand()-0.5) * strength * 1.5
            p.vy += (Random.rand()-0.5) * strength * 1.5
            m.particles[i] = p
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

function update!(m::ParticleLifeModel, evt::KeyEvent)
    if evt.key == :char && evt.char == 'q'
        m.quit = true
        return
    end
    if evt.key == :char && evt.char == ' '
        step_sim!(m; steps=1)
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
    # arrows / vim for minor nudge later; for now tick
    if evt.key == :left || evt.key == :right || evt.key == :up || evt.key == :down ||
       (evt.key == :char && evt.char in ('h','j','k','l'))
        m.tick += 1
    end
    m.tick += 1   # always advance visual tick for subtle anim
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

    # Drive fluid animation in view (substeps) when running -- per plan and Tachikoma examples
    if m.running && !isempty(m.particles)
        for _ in 1:max(1, m.substeps)
            step_particles!(m.particles, m.rules; cutoff=m.cutoff, viscosity=m.viscosity,
                            w=m.world_w, h=m.world_h)
        end
        m.tick += 1
        if m.pulse > 0; m.pulse -= 1; end
    end

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

    # --- SIM PANE: multi-color Canvas braille for fluid beautiful particles (diff render = no flicker) ---
    if canvas_area.width >= 6 && canvas_area.height >= 4
        dw, dh = canvas_area.width * 2, canvas_area.height * 4
        for g in 0:(NUM_GROUPS-1)
            col = GROUP_COLORS[clamp(g+1, 1, length(GROUP_COLORS))]
            c = create_canvas(canvas_area.width, canvas_area.height; style = Style(; fg = col, bold = (m.pulse > 0)))
            clear!(c)
            for p in m.particles
                p.group == g || continue
                dx = clamp( round(Int, (p.x / m.world_w) * (dw - 1)) , 0, dw-1)
                dy = clamp( round(Int, (p.y / m.world_h) * (dh - 1)) , 0, dh-1)
                set_point!(c, dx, dy)
                dx < dw-1 && set_point!(c, dx+1, dy)
                dy < dh-1 && set_point!(c, dx, dy+1)
            end
            render_canvas(c, canvas_area, f)
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
    for h in ["r reset", "x rand", "s sym", "1/2 preset", "p pause", "u pulse", "␣ step", "q quit"]
        cy <= maxcy || break
        set_string!(buf, cx, cy, h, Style(; fg = ColorRGB(0x66,0x66,0x77), dim = !m.running ))
        cy += 1
    end
    cy += 1
    if cy <= maxcy
        set_string!(buf, cx, cy, "N=$(length(m.particles))", Style(; fg = ColorRGB(0x88,0x88,0x99)))
    end
    cy += 1
    if cy <= maxcy
        runsty = m.running ? Style(; fg=ColorRGB(0x5b,0xe2,0x5b), bold=true) : Style(; fg=ColorRGB(0xff,0x88,0x55), bold=true)
        set_string!(buf, cx, cy, m.running ? "RUNNING" : "PAUSED", runsty)
    end

    # Status bar artistic, modern
    if status_area.width >= 10
        left = [Span(" particle life ", Style(; fg=ColorRGB(0xaa,0xaa,0xcc), dim=true))]
        right_str = "$(m.message)  tick=$(m.tick)  visc=$(round(m.viscosity,digits=2))"
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
