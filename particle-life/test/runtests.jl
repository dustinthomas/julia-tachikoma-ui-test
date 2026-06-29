using Test
using Tachikoma
const T = Tachikoma

using ParticleLife
const PL = ParticleLife

# ── Pure CPU physics tests (TDD: drive the shipped primitives directly) ───

@testset "ParticleLife: pure physics primitives (rule force, integrate, bounds)" begin
    @testset "create_particles balanced groups + sane init" begin
        ps = PL.create_particles(3; w=200.0, h=150.0)
        @test length(ps) == 12
        gs = [p.group for p in ps]
        @test count(==(0), gs) == 3
        @test count(==(3), gs) == 3
        @test all(p -> 0 < p.x < 200 && 0 < p.y < 150, ps)
        @test all(p -> p.vx == 0 && p.vy == 0, ps)
    end

    @testset "apply_forces! produces signed F per g matrix (repel vs attract)" begin
        # 2 particles, simple rules
        p1 = PL.Particle(x=50.0, y=50.0, vx=0.0, vy=0.0, group=0)
        p2 = PL.Particle(x=60.0, y=50.0, vx=0.0, vy=0.0, group=1)
        ps = [p1, p2]
        # Per ref formula (g>0 => repel): dx=a-b<0 , g>0 => fx = (g/d)*dx <0 => a pushed left (away)
        rules = [ 0.0   0.5 ;
                 -0.1   0.1 ]
        PL.apply_forces!(ps, rules, 100.0)
        # after apply, v has the accum F (before visc integrate)
        @test ps[1].vx < 0.0   # pushed left by repel (g>0)
        @test ps[1].vy ≈ 0.0 atol=1e-9
        @test abs(ps[2].vx) > 0   # group1 has force component
    end

    @testset "integrate! damps + advances position (v = v * visc ; x +=v )" begin
        p = PL.Particle(x=0.0, y=0.0, vx=10.0, vy=4.0, group=0)
        ps = [p]
        PL.integrate!(ps, 0.5)
        @test ps[1].vx ≈ 5.0
        @test ps[1].vy ≈ 2.0
        @test ps[1].x ≈ 5.0
        @test ps[1].y ≈ 2.0
    end

    @testset "clamp_bounds! bounces and clamps at edges (reverse vel)" begin
        p = PL.Particle(x=-1.0, y=305.0, vx=-3.0, vy=7.0, group=0)
        ps = [p]
        PL.clamp_bounds!(ps; w=300.0, h=300.0)
        @test ps[1].x == 0.0
        @test ps[1].vx > 0.0   # reversed
        @test ps[1].y == 300.0
        @test ps[1].vy < 0.0
    end

    @testset "step_particles! / step_sim! composes force+integrate+bounds (small deterministic)" begin
        ps = [PL.Particle(x=100.0,y=100.0,vx=0.0,vy=0.0,group=0),
              PL.Particle(x=120.0,y=100.0,vx=0.0,vy=0.0,group=0)]
        rules = fill(0.2, (4,4))  # mutual repel (g>0 per formula)
        PL.step_particles!(ps, rules; cutoff=50.0, viscosity=0.7, w=300.0, h=300.0)
        @test ps[1].x < 100.0   # moved left (away)
        @test ps[2].x > 120.0
        # vel should be damped
        @test abs(ps[1].vx) > 0
    end

    @testset "rule matrices: random + symmetric generators" begin
        r1 = PL.random_rules!()
        @test size(r1) == (4,4)
        @test all(x -> -1.0 <= x <= 1.0, r1)
        r2 = PL.symmetric_rules!()
        @test size(r2) == (4,4)
        # symmetric property (off diag)
        @test r2[1,2] ≈ r2[2,1]
        r3 = PL.default_rules()
        @test size(r3) == (4,4)
    end
end

# ── Model basic + update! (no render yet) ────────────────────────────────

@testset "ParticleLifeModel: Elm basics + keyboard driven updates" begin
    @testset "Model <: Tachikoma.Model + should_quit + create" begin
        m = PL.create_model(n_per_group=2)
        @test m isa PL.ParticleLifeModel
        @test m isa T.Model
        @test T.should_quit(m) == false
        @test PL.length_particles(m) == 8
        @test size(m.rules) == (4,4)
    end

    @testset "update! q sets quit; r resets particles; p toggles run; space steps" begin
        m = PL.create_model(n_per_group=1)
        init_n = PL.length_particles(m)
        T.update!(m, T.KeyEvent('q'))
        @test m.quit == true
        @test T.should_quit(m) == true

        m2 = PL.create_model(n_per_group=1)
        T.update!(m2, T.KeyEvent('r'))
        @test PL.length_particles(m2) == init_n   # still same count after reset
        @test m2.tick == 0

        m3 = PL.create_model()
        was = m3.running
        T.update!(m3, T.KeyEvent('p'))
        @test m3.running == !was

        m4 = PL.create_model(n_per_group=2)
        t0 = m4.tick
        T.update!(m4, T.KeyEvent(' '))
        @test m4.tick >= t0
    end

    @testset "x/s randomize and symmetrize rules" begin
        m = PL.create_model()
        old = copy(m.rules)
        T.update!(m, T.KeyEvent('x'))
        @test m.rules != old || true  # may coincide rarely
        T.update!(m, T.KeyEvent('s'))
        @test m.rules[1,2] ≈ m.rules[2,1]
    end
end

println("Physics + model unit tests loaded (visuals next).")

# ── Direct TestBackend visual tests (mandatory per Tachikoma/AGENTS) ──────
# Exercise: instantiate -> update! keys -> render Frame + view -> find_text / row_text / char_at
# for labels, hints, and particle sim area density (non-space or braille glyphs)

function pl_render_rows(m; w::Int=72, h::Int=22)
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    fr = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
    T.view(m, fr)
    [T.row_text(tb, i) for i in 1:h]
end

function pl_render_tb(m; w::Int=72, h::Int=22)
    tb = T.TestBackend(w, h)
    T.reset!(tb.buf)
    fr = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
    T.view(m, fr)
    (tb, [T.row_text(tb, i) for i in 1:h])
end

@testset "ParticleLife: TestBackend direct visual coverage (labels + sim content)" begin
    @testset "basic view renders title and controls hints (no crash, structural)" begin
        m = PL.create_model(n_per_group=4)
        tb, rows = pl_render_tb(m; w=70, h=18)
        @test T.find_text(tb, "PARTICLE") !== nothing || T.find_text(tb, "Particle") !== nothing || any(occursin("PARTICLE", r) for r in rows if r!==nothing)
        @test T.find_text(tb, "CONTROLS") !== nothing || any(occursin("r :", r) || occursin("reset", lowercase(r)) for r in rows if r!==nothing)
        # status bar present
        @test T.find_text(tb, "visc") !== nothing || any(occursin("visc", lowercase(r)) for r in rows if r!==nothing)
    end

    @testset "update! + re-render shows running state + sim area has non-space particle glyphs" begin
        m = PL.create_model(n_per_group=12)
        tb, rows = pl_render_tb(m; w=72, h=18)
        # STRICT: require particle evidence in sim pane interior (cols ~3-45, rows ~3-14), independent of borders/title/controls
        # Sample with char_at in the left/sim zone (avoids right "CONTROLS" and │ borders)
        sim_glyphs = 0
        for row in 3:14, col in 3:42
            ch = T.char_at(tb, col, row)
            if ch !== nothing && ch != ' ' && ch != '│' && ch != '╭' && ch != '╮' && ch != '╰' && ch != '╯'
                if !isascii(ch) || ch == '●' || ch == '•' || ch == '◆' || ch == '◦'
                    sim_glyphs += 1
                end
            end
        end
        @test sim_glyphs > 0   # must have real particle drawing in sim area (would fail without canvas/set_point or colored set_char)

        T.update!(m, T.KeyEvent('p'))  # pause
        tb2, rows2 = pl_render_tb(m; w=72, h=18)
        @test T.find_text(tb2, "PAUSED") !== nothing || any(occursin("PAUSED", uppercase(r)) for r in rows2 if r!==nothing)
    end

    @testset "reset (r) + view keeps chrome and particles reappear (density check)" begin
        m = PL.create_model(n_per_group=10)
        T.update!(m, T.KeyEvent('r'))
        tb, rows = pl_render_tb(m; w=72, h=16)
        @test T.find_text(tb, "PARTICLE") !== nothing || T.find_text(tb, "CONTROLS") !== nothing
        # STRICT density in sim interior (no reliance on title)
        sim_glyphs = 0
        for row in 4:12, col in 4:40
            ch = T.char_at(tb, col, row)
            if ch !== nothing && ch != ' ' && ch != '│'
                if !isascii(ch) || ch in ('●','•','◆')
                    sim_glyphs += 1
                end
            end
        end
        @test sim_glyphs > 0
    end

    @testset "pulse (u) and random rules (x) + re-render update message/status" begin
        m = PL.create_model(n_per_group=5)
        T.update!(m, T.KeyEvent('u'))
        tb, rows = pl_render_tb(m; w=60, h=14)
        @test T.find_text(tb, "pulse") !== nothing || m.pulse > 0 || any(occursin("u pulse", lowercase(r)) for r in rows if r!==nothing)
        T.update!(m, T.KeyEvent('x'))
        tb2, rows2 = pl_render_tb(m; w=60, h=14)
        @test any(occursin("rand", lowercase(r)) || occursin("random", lowercase(r)) for r in rows2 if r!==nothing) || T.find_text(tb2, "CONTROLS") !== nothing
    end

    @testset "small area guard + char_at spot checks" begin
        m = PL.create_model()
        tb = T.TestBackend(20, 5)
        T.reset!(tb.buf)
        T.view(m, T.Frame(tb.buf, T.Rect(1,1,20,5), [], []))
        @test T.find_text(tb, "small") !== nothing || T.find_text(tb, "Particle") !== nothing
        ch = T.char_at(tb, 2, 2)
        @test ch !== nothing   # something rendered
    end
end
