# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — production seed controls (PR-M3 / design §4.7, §5.1):
# seed_demo config + ENV, kanban2 respects flag, ops labels after project
# create (app layer), empty-state copy. Driven via update! + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qm = QciKanban
const SeedCfg = Qm.Config
const SeedStores = Qm.Stores

_login_seed(name = "Ops Seed"; seed = false) =
    (m = Qm.AppModel(; token_path = tempname(), secret = "s", seed = seed);
     app_login_new(m; name = name); m)
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))

@testset "FEATURE: seed_demo config + ops labels (PR-M3 BDD)" begin

    @testset "Config: defaults, TOML, ENV QCI_SEED_DEMO" begin
        cfg = SeedCfg.load_config()
        @test cfg.seed_demo === true
        @test cfg.seed_ops_labels === true

        mktempdir() do dir
            path = joinpath(dir, "maint.toml")
            write(path, """
                seed_demo = false
                seed_ops_labels = true
                token_ttl_seconds = 28800
            """)
            cfg2 = SeedCfg.load_config(path; env = Dict{String,String}())
            @test cfg2.seed_demo === false
            @test cfg2.seed_ops_labels === true
            @test cfg2.token_ttl_seconds == 28800
        end

        # ENV always wins over file
        mktempdir() do dir
            path = joinpath(dir, "maint.toml")
            write(path, "seed_demo = true\n")
            cfg3 = SeedCfg.load_config(path; env = Dict("QCI_SEED_DEMO" => "0"))
            @test cfg3.seed_demo === false
            cfg4 = SeedCfg.load_config(nothing; env = Dict("QCI_SEED_DEMO" => "1"))
            @test cfg4.seed_demo === true
            cfg5 = SeedCfg.load_config(nothing; env = Dict("QCI_SEED_DEMO" => "false"))
            @test cfg5.seed_demo === false
        end

        # maintenance.toml.example loads with plant-safe seed
        example = joinpath(@__DIR__, "..", "..", "config", "maintenance.toml.example")
        @test isfile(example)
        cfg_ex = SeedCfg.load_config(example; env = Dict{String,String}())
        @test cfg_ex.seed_demo === false
        @test cfg_ex.seed_ops_labels === true
    end

    @testset "Given seed_demo=false When AppModel builds Then board has zero issues" begin
        m = Qm.AppModel(; token_path = tempname(), secret = "s", seed = false)
        @test isempty(SeedStores.list_issues(m.boardstore))
        # Default project still exists (migration), no software demo titles
        @test !isempty(SeedStores.list_projects(m.boardstore))
        titles = [i.title for i in SeedStores.list_issues(m.boardstore)]
        @test !any(occursin("Set up project board", t) for t in titles)
        @test !any(occursin("Design login screen", t) for t in titles)
    end

    @testset "Given cfg.seed_demo When AppModel(; seed=cfg.seed_demo) Then matches flag" begin
        cfg_off = SeedCfg.AppConfig(; seed_demo = false)
        m_off = Qm.AppModel(; token_path = tempname(), secret = "s",
                            config = cfg_off, seed = cfg_off.seed_demo)
        @test isempty(SeedStores.list_issues(m_off.boardstore))

        cfg_on = SeedCfg.AppConfig(; seed_demo = true)
        m_on = Qm.AppModel(; token_path = tempname(), secret = "s",
                           config = cfg_on, seed = cfg_on.seed_demo)
        @test !isempty(SeedStores.list_issues(m_on.boardstore))
    end

    @testset "Given fresh install seed_demo=false When supervisor logs in Then empty of demo issues" begin
        m = _login_seed("Supervisor"; seed = false)
        @test m.current_user !== nothing
        @test m.active_project_id !== nothing
        issues = SeedStores.list_issues(m.boardstore; project_id = m.active_project_id)
        @test isempty(issues)
        tb = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb, "Set up project board") === nothing
        @test T.find_text(tb, "Design login screen") === nothing
        @test T.find_text(tb, "No work orders — press [n] to create") !== nothing
        @test T.find_text(tb, "BOARD") !== nothing
        @test T.find_text(tb, "PROJECT:") !== nothing
    end

    @testset "create_project! is pure; create_project_with_defaults! seeds ops labels" begin
        bs = SeedStores.SQLiteBoardStore(":memory:")
        pure = SeedStores.create_project!(bs; key = "PURE", name = "Pure Plant")
        pure_labels = SeedStores.list_labels(bs; project_id = pure.id)
        @test isempty(pure_labels)   # store create stays pure — no labels

        cfg = SeedCfg.AppConfig(; seed_ops_labels = true)
        p = Qm.create_project_with_defaults!(bs, cfg; key = "LINEA", name = "Line A")
        names = sort([l.name for l in SeedStores.list_labels(bs; project_id = p.id)])
        @test names == ["CM", "Critical", "PM", "Safety"]
        colors = Dict(l.name => l.color for l in SeedStores.list_labels(bs; project_id = p.id))
        @test colors["PM"] == "red"
        @test colors["CM"] == "orange"
        @test colors["Safety"] == "yellow"
        @test colors["Critical"] == "violet"
        # still no fake issues/sprints from ops template
        @test isempty(SeedStores.list_issues(bs; project_id = p.id))
        @test isempty(SeedStores.list_sprints(bs; project_id = p.id))

        # seed_ops_labels=false → no labels
        cfg_off = SeedCfg.AppConfig(; seed_ops_labels = false)
        p2 = Qm.create_project_with_defaults!(bs, cfg_off; key = "LINEB", name = "Line B")
        @test isempty(SeedStores.list_labels(bs; project_id = p2.id))
    end

    @testset "seed_ops_template! is idempotent by name" begin
        bs = SeedStores.SQLiteBoardStore(":memory:")
        p = SeedStores.create_project!(bs; key = "OPS", name = "Ops")
        SeedStores.seed_ops_template!(bs, p.id)
        n1 = length(SeedStores.list_labels(bs; project_id = p.id))
        SeedStores.seed_ops_template!(bs, p.id)
        @test length(SeedStores.list_labels(bs; project_id = p.id)) == n1 == 4
    end

    @testset "Help overlay includes Ops quickstart blurb" begin
        m = _login_seed("Help Ops"; seed = false)
        u!(m, '?')
        @test m.modal == :help
        tb = app_tb(m; w = 100, h = 30)
        @test T.find_text(tb, "Ops quickstart") !== nothing
        @test T.find_text(tb, "work orders") !== nothing
        u!(m, :escape)
        @test m.modal == :none
    end

    @testset "App gate seed-off: first-run zero users → create → empty board" begin
        # Mirrors the production path: cfg.seed_demo=false, AppModel seed=false.
        cfg = SeedCfg.AppConfig(; seed_demo = false, seed_ops_labels = true)
        m = Qm.AppModel(; token_path = tempname(), secret = "gate-secret",
                        config = cfg, seed = cfg.seed_demo, restore = false)
        @test m.current_user === nothing
        @test m.user_count == 0
        tb0 = app_tb(m; w = 80, h = 20)
        @test T.find_text(tb0, "No users — press [c] to create account") !== nothing
        app_login_new(m; email = "plant@qci.com", name = "Plant Admin", pw = "password")
        @test m.current_user !== nothing
        @test isempty(SeedStores.list_issues(m.boardstore))
        tb1 = app_tb(m; w = 100, h = 28)
        @test T.find_text(tb1, "No work orders — press [n] to create") !== nothing
        @test T.find_text(tb1, "PROJECT:") !== nothing
        # create project with defaults → ops labels, still no demo issues
        p = Qm.create_project_with_defaults!(m.boardstore, m.config;
                                             key = "SITE1", name = "Site One")
        @test length(SeedStores.list_labels(m.boardstore; project_id = p.id)) == 4
        @test isempty(SeedStores.list_issues(m.boardstore; project_id = p.id))
    end
end
