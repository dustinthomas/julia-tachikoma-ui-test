# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance — project switcher polish + create-project + CSV export
# (PR-M7 / design §4.2 switcher UX, §4.9 export):
#   P opens switcher (even with one project); n → create modal; last_project
#   remember file; uppercase E on backlog writes CSV; help documents keys.
# Driven via update!(m, KeyEvent(...)) + TestBackend.
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates

Qm = QciKanban
# Isolated session dir so last_project + CSV exports never collide in /tmp.
_login_pe(name = "Ops Lead") = begin
    tok = joinpath(mktempdir(), "session.jwt")
    m = Qm.AppModel(; token_path = tok, secret = "s")
    app_login_new(m; name = name)
    m
end
u!(m, x) = T.update!(m, x isa Tuple ? T.KeyEvent(x...) : T.KeyEvent(x))

@testset "FEATURE: project switcher + create + CSV export (PR-M7 BDD)" begin

    @testset "Given one project When P then n Then create-project modal opens" begin
        m = _login_pe("Create From Switcher")
        @test length(m.projects_cache) == 1
        u!(m, 'P')
        @test m.modal == :project_switch
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "SWITCH PROJECT") !== nothing
        @test T.find_text(tb, "n new") !== nothing || T.find_text(tb, "new") !== nothing
        u!(m, 'n')
        @test m.modal == :project_create
        tb2 = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb2, "NEW PROJECT") !== nothing
        @test T.find_text(tb2, "Name:") !== nothing
        @test T.find_text(tb2, "Key:") !== nothing
    end

    @testset "Given create modal When name+key Enter Then project active and last_project saved" begin
        m = _login_pe("Create Submit")
        u!(m, 'P'); u!(m, 'n')
        @test m.modal == :project_create
        for ch in collect("Line Alpha"); u!(m, ch); end
        u!(m, :tab)
        for ch in collect("linea"); u!(m, ch); end  # lowercased → uppercased on submit
        u!(m, :enter)
        @test m.modal == :none
        p = Qm.Stores.get_project(m.boardstore, m.active_project_id)
        @test p !== nothing && p.key == "LINEA" && p.name == "Line Alpha"
        @test occursin("Created project", m.message)
        # last_project file written next to session token
        lp = Qm._last_project_path(m)
        @test isfile(lp)
        @test strip(read(lp, String)) == p.id
        # ops labels seeded by default (seed_ops_labels=true)
        labels = Qm.Stores.list_labels(m.boardstore; project_id = p.id)
        @test any(l -> l.name == "PM", labels)
        tb = app_tb(m; w = 100, h = 24)
        @test T.find_text(tb, "PROJECT:") !== nothing
        @test T.find_text(tb, "Line Alpha") !== nothing || T.find_text(tb, "LINEA") !== nothing
    end

    @testset "Given create modal When invalid fields Then stay open with message" begin
        m = _login_pe("Create Invalid")
        u!(m, 'P'); u!(m, 'n')
        # empty name
        u!(m, :enter)
        @test m.modal == :project_create
        @test occursin("name", lowercase(m.message))
        for ch in collect("Ok Name"); u!(m, ch); end
        u!(m, :enter)  # still no key
        @test occursin("key", lowercase(m.message))
        u!(m, :tab)
        for ch in collect("bad-key"); u!(m, ch); end
        u!(m, :enter)
        @test m.modal == :project_create
        @test occursin("Key", m.message) || occursin("key", m.message)
        # Esc cancels when projects exist
        u!(m, :escape)
        @test m.modal == :none
    end

    @testset "Given last_project file When login Then active project restored" begin
        dir = mktempdir()
        tok = joinpath(dir, "session.jwt")
        m1 = Qm.AppModel(; token_path = tok, secret = "s")
        app_login_new(m1; name = "Restore User", email = "restore@qci.com")
        la = Qm.Stores.create_project!(m1.boardstore; key = "SITE9", name = "Site Nine")
        Qm._set_active_project!(m1, la.id)
        @test strip(read(Qm._last_project_path(m1), String)) == la.id
        # Same session dir, fresh board: restore via last_project file.
        m2 = Qm.AppModel(; token_path = tok, secret = "s", restore = false, seed = true)
        def = only(filter(p -> p.key == "QCI", Qm.Stores.list_projects(m2.boardstore)))
        Qm.Config._atomic_write_0600(Qm._last_project_path(m2), def.id * "\n")
        m2.active_project_id = nothing
        Qm._load_projects!(m2)
        @test m2.active_project_id == def.id
        # missing/archived id falls back to first project
        Qm.Config._atomic_write_0600(Qm._last_project_path(m2), "missing-id\n")
        m2.active_project_id = nothing
        Qm._load_projects!(m2)
        @test m2.active_project_id == m2.projects_cache[1].id
    end

    @testset "Given backlog When E Then CSV file written for active project" begin
        m = _login_pe("CSV Export")
        # ensure at least one WO-ish issue in Default
        Qm.Stores.create_issue!(m.boardstore; title = "Export me", project_id = m.active_project_id,
                                status = "Backlog", asset_tag = "PUMP-1", work_type = "CM")
        # K → backlog from board (no longer shadowed by rank).
        u!(m, 'K')
        @test m.view === :backlog
        # lowercase e should NOT export (edit card)
        before = readdir(dirname(m.session.token_path); join = true)
        u!(m, 'e')
        after_e = readdir(dirname(m.session.token_path); join = true)
        @test length(filter(p -> occursin("export-", basename(p)), after_e)) ==
              length(filter(p -> occursin("export-", basename(p)), before))
        # close any edit modal that opened
        m.modal !== :none && u!(m, :escape)
        # uppercase E exports
        u!(m, 'E')
        @test occursin("Exported", m.message)
        exports = filter(p -> startswith(basename(p), "export-") && endswith(p, ".csv"),
                         readdir(dirname(m.session.token_path); join = true))
        @test length(exports) == 1
        path = exports[1]
        content = read(path, String)
        @test startswith(content, "key,title,status,")
        @test occursin("Export me", content)
        @test occursin("PUMP-1", content)
        # Help table (generated from KEYMAP) documents Export CSV + Switch project.
        # Full help overlay may truncate long lists ("▾ N more"), so assert data.
        @test any(s -> occursin("Export CSV", s), Qm.help_lines([:backlog]))
        @test any(s -> occursin("Switch project", s), Qm.help_lines([:global]))
        @test occursin("Export CSV", Qm.status_hints([:backlog, :global]))
        @test occursin("Switch project", Qm.status_hints([:global]))
        # Rendered help still opens without crash and shows the ops blurb
        u!(m, '?')
        tb = app_tb(m; w = 100, h = 36)
        @test T.find_text(tb, "HELP") !== nothing
        @test T.find_text(tb, "Switch project") !== nothing  # global is listed first
        u!(m, :escape)
    end

    @testset "Given no active project When E Then message and no crash" begin
        m = _login_pe("No Proj Export")
        m.active_project_id = nothing
        u!(m, 'K'); u!(m, 'E')
        @test occursin("No active project", m.message)
    end

    @testset "Given duplicate project key When create Then error stays on modal" begin
        m = _login_pe("Dup Key")
        u!(m, 'P'); u!(m, 'n')
        for ch in collect("Another"); u!(m, ch); end
        u!(m, :tab)
        for ch in collect("QCI"); u!(m, ch); end  # Default key already exists
        u!(m, :enter)
        @test m.modal == :project_create
        @test occursin("Could not create", m.message) || occursin("already", m.message)
    end

    @testset "Given zero projects When login completes Then forced create modal" begin
        m = _login_pe("Forced Create")
        u = m.current_user
        # Archive every project so the post-login empty-cache path runs.
        for p in Qm.Stores.list_projects(m.boardstore; include_archived = false)
            Qm.Stores.archive_project!(m.boardstore, p.id)
        end
        m.active_project_id = nothing
        empty!(m.projects_cache)
        Qm._complete_login!(m, u)
        @test m.modal == :project_create
        @test occursin("create a project", lowercase(m.message))
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "NEW PROJECT") !== nothing
        # Completing create after forced path works end-to-end
        for ch in collect("Rescue"); u!(m, ch); end
        u!(m, :tab)
        for ch in collect("RSC"); u!(m, ch); end
        u!(m, :enter)
        @test m.modal == :none
        @test m.active_project_id !== nothing
        p = Qm.Stores.get_project(m.boardstore, m.active_project_id)
        @test p !== nothing && p.key == "RSC"
    end
end
