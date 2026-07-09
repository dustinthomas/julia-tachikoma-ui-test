# Unit tests for QciKanban.Config, QciKanban.Stores (SQLite + Remote/fake exec).
using Test
using Dates
using SQLite
using DBInterface
const S = QciKanban.Stores
const C = QciKanban.Config
const P = QciKanban.Passwords
const Dm = QciKanban.Domain

@testset "Config: AppConfig from TOML + ENV + jwt secret" begin
    @testset "defaults" begin
        cfg = C.load_config()
        @test cfg.backend == :sqlite
        @test cfg.smtp.enabled == false
        @test cfg.token_ttl_seconds > 0
        @test cfg.postgres.port == 5432
        @test cfg.seed_demo === true
        @test cfg.seed_ops_labels === true
    end

    @testset "TOML file" begin
        mktempdir() do dir
            path = joinpath(dir, "cfg.toml")
            write(path, """
                backend = "remote"
                users_db_path = "/tmp/u.db"
                board_db_path = "/tmp/b.db"
                jwt_secret = "filesecret-0123456789abcdef-0123456789"
                jwt_secret_path = "/tmp/jwt.secret"
                session_token_path = "/tmp/s.jwt"
                token_ttl_seconds = 42
                seed_demo = false
                seed_ops_labels = false
                [smtp]
                enabled = true
                host = "mail.example.com"
                port = 587
                user = "u"
                password = "p"
                from = "from@example.com"
                [postgres]
                host = "pg"
                port = 6000
                dbname = "d"
                user = "pu"
                password = "pp"
            """)
            cfg = C.load_config(path; env = Dict{String,String}())
            @test cfg.backend == :remote
            @test cfg.users_db_path == "/tmp/u.db"
            @test cfg.jwt_secret == "filesecret-0123456789abcdef-0123456789"
            @test cfg.token_ttl_seconds == 42
            @test cfg.seed_demo === false
            @test cfg.seed_ops_labels === false
            @test cfg.smtp.enabled && cfg.smtp.port == 587 && cfg.smtp.from == "from@example.com"
            @test cfg.postgres.host == "pg" && cfg.postgres.port == 6000 && cfg.postgres.password == "pp"
        end
    end

    @testset "missing file → defaults; ENV overrides win" begin
        cfg = C.load_config(joinpath(tempdir(), "does-not-exist-xyz.toml"))
        @test cfg.backend == :sqlite
        env = Dict("QCI_BACKEND" => "remote", "QCI_USERS_DB" => "/e/u.db", "QCI_BOARD_DB" => "/e/b.db",
                   "QCI_JWT_SECRET" => "envsecret-0123456789abcdef-0123456789", "QCI_JWT_SECRET_PATH" => "/e/j", "QCI_SESSION_TOKEN_PATH" => "/e/s",
                   "QCI_TOKEN_TTL" => "99", "QCI_SEED_DEMO" => "0", "QCI_SMTP_ENABLED" => "true", "QCI_SMTP_HOST" => "eh",
                   "QCI_SMTP_PORT" => "2525", "QCI_SMTP_USER" => "eu", "QCI_SMTP_PASSWORD" => "ep",
                   "QCI_SMTP_FROM" => "ef@x.co", "QCI_PG_HOST" => "eph", "QCI_PG_PORT" => "7000",
                   "QCI_PG_DBNAME" => "epd", "QCI_PG_USER" => "epu", "QCI_PG_PASSWORD" => "epp")
        cfg2 = C.load_config(nothing; env = env)
        @test cfg2.backend == :remote && cfg2.users_db_path == "/e/u.db"
        @test cfg2.jwt_secret == "envsecret-0123456789abcdef-0123456789" && cfg2.token_ttl_seconds == 99
        @test cfg2.seed_demo === false
        @test cfg2.smtp.enabled && cfg2.smtp.port == 2525 && cfg2.smtp.from == "ef@x.co"
        @test cfg2.postgres.host == "eph" && cfg2.postgres.port == 7000
    end

    @testset "bool coercion variants" begin
        for (v, exp) in (("1", true), ("yes", true), ("on", true), ("0", false), ("no", false))
            cfg = C.load_config(nothing; env = Dict("QCI_SMTP_ENABLED" => v))
            @test cfg.smtp.enabled == exp
        end
    end

    @testset "ensure_jwt_secret! generates + persists 0600, reads back" begin
        mktempdir() do dir
            spath = joinpath(dir, "sub", "jwt.secret")
            cfg = C.AppConfig(; jwt_secret_path = spath)
            @test cfg.jwt_secret === nothing
            secret = C.ensure_jwt_secret!(cfg)
            @test !isempty(secret) && cfg.jwt_secret == secret
            @test isfile(spath)
            @test (filemode(spath) & 0o777) == 0o600
            # idempotent within config
            @test C.ensure_jwt_secret!(cfg) == secret
            # fresh config reads existing file rather than regenerating
            cfg2 = C.AppConfig(; jwt_secret_path = spath)
            @test C.ensure_jwt_secret!(cfg2) == secret
        end
    end
end

@testset "Stores: SQLite user store" begin
    us = S.SQLiteUserStore(":memory:")
    u = S.create_user!(us; email = "alex@qci.co", name = "Alex", password = "hunter2pw")
    @test u isa Dm.User && u.name == "Alex"
    @test S.authenticate(us, "alex@qci.co", "hunter2pw") !== nothing
    @test S.authenticate(us, "alex@qci.co", "wrong") === nothing
    @test S.authenticate(us, "nobody@qci.co", "x") === nothing
    @test_throws ArgumentError S.create_user!(us; email = "alex@qci.co", name = "Dup", password = "pw123456")
    @test_throws ArgumentError S.create_user!(us; email = "bad", name = "X", password = "pw123456")
    @test S.get_user(us, u.id).email == "alex@qci.co"
    @test S.get_user(us, "missing") === nothing
    S.create_user!(us; email = "sam@qci.co", name = "Sam", password = "pw123456")
    @test length(S.list_users(us)) == 2
    @test S.deactivate_user!(us, u.id)
    @test S.authenticate(us, "alex@qci.co", "hunter2pw") === nothing  # inactive can't auth
    @test S.get_user(us, u.id).active == false
end

@testset "Stores: SQLite board store CRUD" begin
    bs = S.SQLiteBoardStore(":memory:")
    @test S.board_schema_version(bs) == 6
    @testset "issues" begin
        i = S.create_issue!(bs; title = "First", status = "Backlog", priority = "High")
        @test startswith(i.key, "QCI-") && i.position == 0
        @test !isempty(i.project_id)  # defaults to Default project
        @test i.asset_tag === nothing && i.location === nothing && i.work_type === nothing
        def = only(S.list_projects(bs))
        @test def.key == "QCI" && i.project_id == def.id
        i2 = S.create_issue!(bs; title = "Second", status = "Backlog")
        @test i2.position == 1  # dense append
        @test i2.key != i.key
        @test S.get_issue(bs, i.id).title == "First"
        @test S.get_issue(bs, "nope") === nothing
        @test length(S.list_issues(bs)) == 2
        @test length(S.list_issues(bs; status = "Backlog")) == 2
        @test isempty(S.list_issues(bs; status = "Done"))
        @test length(S.list_issues(bs; project_id = def.id)) == 2
        @test isempty(S.list_issues(bs; project_id = "missing-proj"))
        upd = S.update_issue!(bs, i.id; title = "First!", priority = "Low", due_date = Date(2026, 5, 1), story_points = 8)
        @test upd.title == "First!" && upd.priority == "Low" && upd.due_date == Date(2026, 5, 1) && upd.story_points == 8
        @test S.update_issue!(bs, i.id).title == "First!"          # empty kwargs no-op
        @test S.update_issue!(bs, i.id; bogus = 1).title == "First!"  # unknown field ignored
        @test_throws ArgumentError S.update_issue!(bs, i.id; status = "Nope")
        @test_throws ArgumentError S.update_issue!(bs, i.id; priority = "Nope")
        @test_throws ArgumentError S.create_issue!(bs; title = "x", status = "Nope")
        @test_throws ArgumentError S.create_issue!(bs; title = "x", priority = "Nope")
    end

    @testset "work-order fields (asset_tag / location / work_type)" begin
        bw = S.SQLiteBoardStore(":memory:")
        wo = S.create_issue!(bw; title = "PM pump", asset_tag = "PMP-12",
                             location = "Line A Bay 3", work_type = "PM", story_points = 4)
        @test wo.asset_tag == "PMP-12" && wo.location == "Line A Bay 3" && wo.work_type == "PM"
        got = S.get_issue(bw, wo.id)
        @test got.asset_tag == "PMP-12" && got.work_type == "PM"
        upd = S.update_issue!(bw, wo.id; work_type = "CM", asset_tag = "  ", location = "Bay 4")
        @test upd.work_type == "CM" && upd.asset_tag === nothing && upd.location == "Bay 4"
        @test_throws ArgumentError S.create_issue!(bw; title = "bad", work_type = "Emergency")
        @test_throws ArgumentError S.update_issue!(bw, wo.id; work_type = "bogus")
        # blank work_type clears
        cleared = S.update_issue!(bw, wo.id; work_type = nothing)
        @test cleared.work_type === nothing
    end

    @testset "C4: update_issue! routes status/position through move (stays dense)" begin
        bc = S.SQLiteBoardStore(":memory:")
        x = S.create_issue!(bc; title = "X", status = "Backlog")
        y = S.create_issue!(bc; title = "Y", status = "Backlog")
        z = S.create_issue!(bc; title = "Z", status = "Backlog")
        # valid status via update_issue! → moved + both columns reindexed dense
        moved = S.update_issue!(bc, x.id; title = "X!", status = "To Do")
        @test moved.status == "To Do" && moved.title == "X!"
        @test [i.position for i in S.list_issues(bc; status = "Backlog")] == [0, 1]
        @test [i.position for i in S.list_issues(bc; status = "To Do")] == [0]
        # position via update_issue! → dense reorder
        S.update_issue!(bc, z.id; position = 0)
        bl = S.list_issues(bc; status = "Backlog")
        @test bl[1].id == z.id && [i.position for i in bl] == [0, 1]
    end

    @testset "move / rank keep dense" begin
        b2 = S.SQLiteBoardStore(":memory:")
        a = S.create_issue!(b2; title = "A", status = "Backlog")
        b = S.create_issue!(b2; title = "B", status = "Backlog")
        c = S.create_issue!(b2; title = "C", status = "Backlog")
        # move A to To Do
        S.move_issue!(b2, a.id; status = "To Do")
        bl = S.list_issues(b2; status = "Backlog")
        @test [x.position for x in bl] == [0, 1]                 # reindexed dense
        @test S.get_issue(b2, a.id).status == "To Do" && S.get_issue(b2, a.id).position == 0
        # rank C to front of Backlog
        S.rank_issue!(b2, c.id; position = 0)
        bl = S.list_issues(b2; status = "Backlog")
        @test bl[1].id == c.id && [x.position for x in bl] == [0, 1]
        # clamp beyond end
        S.rank_issue!(b2, c.id; position = 99)
        @test S.list_issues(b2; status = "Backlog")[end].id == c.id
        # default position appends
        d = S.create_issue!(b2; title = "D", status = "To Do")
        S.move_issue!(b2, d.id; status = "Backlog")
        @test S.list_issues(b2; status = "Backlog")[end].id == d.id
        # same-status no-op-ish still dense
        @test S.move_issue!(b2, b.id; position = 0).id == b.id
        @test S.move_issue!(b2, "missing") === nothing
        @test_throws ArgumentError S.move_issue!(b2, b.id; status = "Nope")
        # delete reindexes
        @test S.delete_issue!(b2, b.id)
        @test !S.delete_issue!(b2, "missing")
        @test [x.position for x in S.list_issues(b2; status = "Backlog")] == collect(0:length(S.list_issues(b2; status = "Backlog")) - 1)
    end

    @testset "epics" begin
        e = S.create_epic!(bs; name = "Onboarding", color = "teal")
        @test startswith(e.key, "QCI-E-")   # multi-project format {KEY}-E-{n}
        @test !isempty(e.project_id)
        @test S.get_epic(bs, e.id).name == "Onboarding"
        @test S.get_epic(bs, "nope") === nothing
        S.create_epic!(bs; name = "Core")
        @test length(S.list_epics(bs)) == 2
        @test S.update_epic!(bs, e.id; name = "Onboard", color = "violet").name == "Onboard"
        @test S.update_epic!(bs, e.id).name == "Onboard"  # no-op
        @test S.delete_epic!(bs, e.id)
        @test S.get_epic(bs, e.id) === nothing
    end

    @testset "sprints + single active" begin
        b3 = S.SQLiteBoardStore(":memory:")
        s1 = S.create_sprint!(b3; name = "S1", goal = "g", start_date = Date(2026, 1, 1), end_date = Date(2026, 1, 14))
        s2 = S.create_sprint!(b3; name = "S2")
        @test s1.state == :future
        @test S.get_sprint(b3, s1.id).goal == "g"
        @test S.get_sprint(b3, "nope") === nothing
        @test length(S.list_sprints(b3)) == 2
        @test S.active_sprint(b3) === nothing
        started = S.start_sprint!(b3, s1.id)
        @test started.state == :active && S.active_sprint(b3).id == s1.id
        @test_throws ArgumentError S.start_sprint!(b3, s2.id)  # single-active
        @test_throws ArgumentError S.start_sprint!(b3, "nope")
        @test_throws ArgumentError S.close_sprint!(b3, "nope")
        closed = S.close_sprint!(b3, s1.id)
        @test closed.state == :closed && S.active_sprint(b3) === nothing
        upd = S.update_sprint!(b3, s2.id; name = "S2!", goal = "gg", start_date = Date(2026, 2, 1), end_date = Date(2026, 2, 14))
        @test upd.name == "S2!" && upd.goal == "gg" && upd.start_date == Date(2026, 2, 1)
        @test S.update_sprint!(b3, s2.id).name == "S2!"  # no-op
    end

    @testset "labels + comments + activity" begin
        b4 = S.SQLiteBoardStore(":memory:")
        i = S.create_issue!(b4; title = "Labeled")
        l1 = S.create_label!(b4; name = "bug", color = "red")
        l2 = S.create_label!(b4; name = "ui")
        @test length(S.list_labels(b4)) == 2
        S.set_labels!(b4, i.id, [l1.id, l2.id])
        @test Set(S.labels_for_issue(b4, i.id)) == Set([l1.id, l2.id])
        @test Set(S.get_issue(b4, i.id).labels) == Set([l1.id, l2.id])
        S.set_labels!(b4, i.id, [l1.id])  # replace
        @test S.labels_for_issue(b4, i.id) == [l1.id]

        c = S.add_comment!(b4; issue_id = i.id, author_id = "u1", body = "looks good")
        @test c.body == "looks good"
        @test length(S.list_comments(b4, i.id)) == 1

        a1 = S.log_activity!(b4; issue_id = i.id, kind = :created)
        @test a1.actor_id === nothing
        S.log_activity!(b4; issue_id = i.id, actor_id = "u1", kind = :moved, detail = "→ Done")
        acts = S.list_activity(b4, i.id)
        @test length(acts) == 2 && acts[end].detail == "→ Done"
    end

    @testset "sprint/backlog membership + outbox" begin
        b5 = S.SQLiteBoardStore(":memory:")
        sp = S.create_sprint!(b5; name = "Sp")
        i_in = S.create_issue!(b5; title = "in-sprint", sprint_id = sp.id)
        i_out = S.create_issue!(b5; title = "backlog")
        @test [x.id for x in S.issues_for_sprint(b5, sp.id)] == [i_in.id]
        @test i_out.id in [x.id for x in S.backlog_issues(b5)]
        @test !(i_in.id in [x.id for x in S.backlog_issues(b5)])

        oid = S.enqueue_outbox!(b5; event_kind = :assigned, recipient_email = "a@b.co", subject = "s", body = "b")
        pend = S.pending_outbox(b5)
        @test length(pend) == 1 && pend[1]["id"] == oid && pend[1]["subject"] == "s"
        @test S.mark_sent!(b5, oid)
        @test isempty(S.pending_outbox(b5))
    end
end

@testset "Stores: parse helpers + file-backed store + missing mapping" begin
    @test S.parse_date(Date(2026, 1, 1)) == Date(2026, 1, 1)
    @test S.parse_date("not-a-date") === nothing
    @test S.parse_dt(nothing) isa DateTime
    @test S.parse_dt(missing) isa DateTime
    @test S.parse_dt(DateTime(2026, 1, 1)) == DateTime(2026, 1, 1)
    @test S.parse_dt("2026-01-01T12:00:00") == DateTime(2026, 1, 1, 12)
    @test S.parse_dt("2026-01-01T12:00:00.999999") == DateTime(2026, 1, 1, 12)  # fractional fallback
    @test S.parse_dt("garbage") isa DateTime                                     # total fallback
    @test S.parse_points(nothing) === nothing
    @test S.parse_points(missing) === nothing
    @test S.parse_points(5) == 5
    @test S.parse_points("7") == 7
    @test S.parse_points("") === nothing

    # file-backed SQLite stores (exercise non-":memory:" open path, creating dirs)
    mktempdir() do dir
        us = S.SQLiteUserStore(joinpath(dir, "sub", "users.db"))
        bs = S.SQLiteBoardStore(joinpath(dir, "sub", "board.db"))
        @test S.create_user!(us; email = "f@b.co", name = "F", password = "pw123456") isa Dm.User
        @test S.create_issue!(bs; title = "file issue") isa Dm.Issue
        S.close!(us); S.close!(bs)
    end

    # remote mapper handling missing values (NULL columns)
    iss = S.remote_row_to_issue(Dict{String,Any}("id" => "i", "key" => "QCI-1", "title" => "T",
        "status" => "Backlog", "priority" => "Low", "description" => missing, "assignee_id" => missing))
    @test iss.description == "" && iss.assignee_id === nothing
end

@testset "Stores: seed_demo! (issues+epics+sprints+labels, ZERO users)" begin
    bs = S.SQLiteBoardStore(":memory:")
    us = S.SQLiteUserStore(":memory:")
    S.seed_demo!(bs)
    @test !isempty(S.list_issues(bs))
    @test !isempty(S.list_epics(bs))
    @test !isempty(S.list_sprints(bs))
    @test !isempty(S.list_labels(bs))
    @test isempty(S.list_users(us))         # first-run gate contract
    n = length(S.list_issues(bs))
    S.seed_demo!(bs)                         # idempotent
    @test length(S.list_issues(bs)) == n
end

@testset "Stores: seed_ops_template! (labels only, no issues)" begin
    bs = S.SQLiteBoardStore(":memory:")
    def = only(S.list_projects(bs))
    S.seed_ops_template!(bs, def.id)
    labels = S.list_labels(bs; project_id = def.id)
    @test sort([l.name for l in labels]) == ["CM", "Critical", "PM", "Safety"]
    @test isempty(S.list_issues(bs; project_id = def.id))
    @test isempty(S.list_sprints(bs; project_id = def.id))
    # pure create_project! still adds no labels
    p = S.create_project!(bs; key = "X1", name = "X")
    @test isempty(S.list_labels(bs; project_id = p.id))
end

@testset "Stores: open_sqlite_stores + close!" begin
    cfg = C.AppConfig(; users_db_path = ":memory:", board_db_path = ":memory:")
    us, bs = S.open_sqlite_stores(cfg)
    @test us isa S.SQLiteUserStore && bs isa S.SQLiteBoardStore
    S.close!(us); S.close!(bs)
    @test true
end

@testset "Stores: project CRUD + optional project_id + keys" begin
    bs = S.SQLiteBoardStore(":memory:")
    def = only(S.list_projects(bs))
    @test def.key == "QCI" && def.name == "Default" && !def.archived
    @test S.get_project(bs, def.id).key == "QCI"
    @test S.get_project(bs, "nope") === nothing

    la = S.create_project!(bs; key = "LA", name = "Line A", description = "site", color = "teal")
    @test la.key == "LA" && la.name == "Line A" && la.color == "teal"
    @test length(S.list_projects(bs)) == 2
    @test_throws ArgumentError S.create_project!(bs; key = "LA", name = "Dup")
    @test_throws ArgumentError S.create_project!(bs; key = "bad", name = "X")
    @test_throws ArgumentError S.create_project!(bs; key = "OK", name = "  ")

    # creates without project_id → Default; with project_id → that project
    i_def = S.create_issue!(bs; title = "On default")
    @test i_def.project_id == def.id && startswith(i_def.key, "QCI-")
    i_la = S.create_issue!(bs; title = "On LA", project_id = la.id)
    @test i_la.project_id == la.id && startswith(i_la.key, "LA-")
    @test length(S.list_issues(bs)) == 2
    @test length(S.list_issues(bs; project_id = la.id)) == 1
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = "missing")

    e_def = S.create_epic!(bs; name = "DefEpic")
    @test startswith(e_def.key, "QCI-E-") && e_def.project_id == def.id
    e_la = S.create_epic!(bs; name = "LA Epic", project_id = la.id)
    @test startswith(e_la.key, "LA-E-") && e_la.project_id == la.id
    @test length(S.list_epics(bs; project_id = la.id)) == 1

    sp = S.create_sprint!(bs; name = "Win", project_id = la.id)
    @test sp.project_id == la.id
    @test length(S.list_sprints(bs; project_id = la.id)) == 1
    lbl = S.create_label!(bs; name = "PM", project_id = la.id)
    @test lbl.project_id == la.id
    @test length(S.list_labels(bs; project_id = la.id)) == 1

    # key generator: MAX then _next_seq!; deleted numbers never recycled
    k1 = S.create_issue!(bs; title = "k1", project_id = la.id).key
    k2 = S.create_issue!(bs; title = "k2", project_id = la.id).key
    n1 = parse(Int, split(k1, '-')[end]); n2 = parse(Int, split(k2, '-')[end])
    @test n2 == n1 + 1

    # empty-string list filter ≡ unfiltered (same footgun as something(id, ""))
    @test length(S.list_issues(bs; project_id = "")) == length(S.list_issues(bs))
    @test length(S.list_epics(bs; project_id = "")) == length(S.list_epics(bs))
    @test length(S.list_sprints(bs; project_id = "")) == length(S.list_sprints(bs))
    @test length(S.list_labels(bs; project_id = "")) == length(S.list_labels(bs))
    @test length(S.backlog_issues(bs; project_id = "")) == length(S.backlog_issues(bs))

    # archive
    @test_throws ArgumentError S.archive_project!(bs, "missing")
    S.start_sprint!(bs, sp.id)
    @test_throws ArgumentError S.archive_project!(bs, la.id)  # active sprint blocks
    S.close_sprint!(bs, sp.id)
    # create entities on LA before archive for write-guard tests
    sp2 = S.create_sprint!(bs; name = "Win2", project_id = la.id)
    i_la_upd = S.create_issue!(bs; title = "upd target", project_id = la.id)
    e_la_upd = S.create_epic!(bs; name = "ArchEpic", project_id = la.id)
    lbl_la = S.create_label!(bs; name = "LArch", project_id = la.id)
    arch = S.archive_project!(bs, la.id)
    @test arch.archived
    @test length(S.list_projects(bs)) == 1  # Default only
    @test length(S.list_projects(bs; include_archived = true)) == 2
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id)  # archived
    # update_issue! / start_sprint! blocked on archived project (Issue 2)
    @test_throws ArgumentError S.update_issue!(bs, i_la_upd.id; title = "nope")
    @test_throws ArgumentError S.start_sprint!(bs, sp2.id)
    # move / rank / delete / set_labels / update epic+sprint (Issue 8)
    @test_throws ArgumentError S.move_issue!(bs, i_la_upd.id; status = "To Do")
    @test_throws ArgumentError S.rank_issue!(bs, i_la_upd.id; position = 0)
    @test_throws ArgumentError S.delete_issue!(bs, i_la_upd.id)
    @test_throws ArgumentError S.set_labels!(bs, i_la_upd.id, [lbl_la.id])
    @test_throws ArgumentError S.update_epic!(bs, e_la_upd.id; name = "nope")
    @test_throws ArgumentError S.update_sprint!(bs, sp2.id; name = "nope")

    # Default path also respects archive (Issue 1): omit project_id after archiving Default
    # Keep LA archived; create a replacement writable project first, then archive Default.
    other = S.create_project!(bs; key = "LINE2", name = "Line 2")
    S.archive_project!(bs, def.id)
    @test_throws ArgumentError S.create_issue!(bs; title = "into archived default")
    @test_throws ArgumentError S.create_issue!(bs; title = "empty str", project_id = "")
    # explicit other still works
    ok = S.create_issue!(bs; title = "on LINE2", project_id = other.id)
    @test ok.project_id == other.id && startswith(ok.key, "LINE2-")
end

@testset "Stores: PR-M2 per-project active sprint + rank isolation + FK guards" begin
    bs = S.SQLiteBoardStore(":memory:")
    def = only(S.list_projects(bs))
    la = S.create_project!(bs; key = "LA", name = "Line A")
    lb = S.create_project!(bs; key = "LB", name = "Line B")

    # Dual active sprint: Project A + Project B can each have an active window.
    sa = S.create_sprint!(bs; name = "A-win", project_id = la.id,
                          start_date = Date(2026, 1, 1), end_date = Date(2026, 1, 14))
    sb = S.create_sprint!(bs; name = "B-win", project_id = lb.id,
                          start_date = Date(2026, 1, 1), end_date = Date(2026, 1, 14))
    sa2 = S.create_sprint!(bs; name = "A-win2", project_id = la.id)
    S.start_sprint!(bs, sa.id)
    @test S.active_sprint(bs; project_id = la.id).id == sa.id
    @test S.active_sprint(bs; project_id = lb.id) === nothing
    S.start_sprint!(bs, sb.id)   # independent of A's active sprint
    @test S.active_sprint(bs; project_id = lb.id).id == sb.id
    @test S.active_sprint(bs; project_id = la.id).id == sa.id
    err = try
        S.start_sprint!(bs, sa2.id); ""
    catch e
        e isa ArgumentError ? e.msg : string(e)
    end
    @test occursin("this project", err)  # same project still one-active

    # Ranking isolation: rank in LA must not touch LB positions.
    a1 = S.create_issue!(bs; title = "A1", status = "Backlog", project_id = la.id)
    a2 = S.create_issue!(bs; title = "A2", status = "Backlog", project_id = la.id)
    a3 = S.create_issue!(bs; title = "A3", status = "Backlog", project_id = la.id)
    b1 = S.create_issue!(bs; title = "B1", status = "Backlog", project_id = lb.id)
    b2 = S.create_issue!(bs; title = "B2", status = "Backlog", project_id = lb.id)
    @test a1.position == 0 && a2.position == 1 && a3.position == 2
    @test b1.position == 0 && b2.position == 1
    S.rank_issue!(bs, a3.id; position = 0)
    la_bl = S.list_issues(bs; status = "Backlog", project_id = la.id)
    @test [i.id for i in la_bl] == [a3.id, a1.id, a2.id]
    @test [i.position for i in la_bl] == [0, 1, 2]
    lb_bl = S.list_issues(bs; status = "Backlog", project_id = lb.id)
    @test [i.id for i in lb_bl] == [b1.id, b2.id]
    @test [i.position for i in lb_bl] == [0, 1]
    # move A across columns — LB unchanged
    S.move_issue!(bs, a1.id; status = "To Do")
    @test [i.position for i in S.list_issues(bs; status = "Backlog", project_id = la.id)] == [0, 1]
    @test [i.position for i in S.list_issues(bs; status = "Backlog", project_id = lb.id)] == [0, 1]
    @test S.get_issue(bs, a1.id).position == 0

    # Cross-project epic / sprint / label → ArgumentError
    e_la = S.create_epic!(bs; name = "LA-epic", project_id = la.id)
    e_lb = S.create_epic!(bs; name = "LB-epic", project_id = lb.id)
    lbl_la = S.create_label!(bs; name = "pm-la", project_id = la.id)
    lbl_lb = S.create_label!(bs; name = "pm-lb", project_id = lb.id)
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id, epic_id = e_lb.id)
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id, sprint_id = sb.id)
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id, labels = [lbl_lb.id])
    ok_iss = S.create_issue!(bs; title = "ok", project_id = la.id, epic_id = e_la.id, sprint_id = sa.id)
    @test ok_iss.epic_id == e_la.id && ok_iss.sprint_id == sa.id
    @test_throws ArgumentError S.update_issue!(bs, ok_iss.id; epic_id = e_lb.id)
    @test_throws ArgumentError S.update_issue!(bs, ok_iss.id; sprint_id = sb.id)
    @test_throws ArgumentError S.set_labels!(bs, ok_iss.id, [lbl_lb.id])
    S.set_labels!(bs, ok_iss.id, [lbl_la.id])
    @test S.labels_for_issue(bs, ok_iss.id) == [lbl_la.id]
    # missing refs
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id, epic_id = "no-epic")
    @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id, sprint_id = "no-sprint")
    @test_throws ArgumentError S.set_labels!(bs, ok_iss.id, ["no-label"])
end

@testset "Stores: _next_seq! honours row MAX over stale key_seq" begin
    bs = S.SQLiteBoardStore(":memory:")
    def = only(S.list_projects(bs))
    # Insert a high-numbered legacy-style issue and seed key_seq artificially low.
    now = string(Dates.now(UTC))
    DBInterface.execute(bs.db,
        "INSERT INTO issues (id, key, title, description, status, priority, position, created, updated, project_id)
         VALUES ('hi', 'QCI-250', 'High', '', 'Backlog', 'Medium', 0, ?, ?, ?)",
        [now, now, def.id])
    DBInterface.execute(bs.db,
        "INSERT INTO key_seq (prefix, last) VALUES ('QCI', 50)
         ON CONFLICT(prefix) DO UPDATE SET last = 50")
    nxt = S.create_issue!(bs; title = "after stale seq")
    @test nxt.key == "QCI-251"  # max(stored=50, row_max=250, 99)+1
end

@testset "Stores: on-disk pre-v1 migration fixture → v6" begin
    # Build a board.db with the *old* CREATE (no project_id, no migrations),
    # seed rows, then open via SQLiteBoardStore so migrate_board_schema! runs.
    mktempdir() do dir
        path = joinpath(dir, "board.db")
        raw = SQLite.DB(path)
        DBInterface.execute(raw, """
            CREATE TABLE issues (
                id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
                description TEXT, status TEXT NOT NULL, priority TEXT NOT NULL DEFAULT 'Medium',
                story_points INTEGER, epic_id TEXT, sprint_id TEXT, assignee_id TEXT,
                reporter_id TEXT, start_date TEXT, due_date TEXT, position INTEGER NOT NULL DEFAULT 0,
                created TEXT NOT NULL, updated TEXT NOT NULL
            )
        """)
        DBInterface.execute(raw, "CREATE INDEX idx_issues_status_pos ON issues(status, position)")
        DBInterface.execute(raw, "CREATE TABLE key_seq (prefix TEXT PRIMARY KEY, last INTEGER NOT NULL)")
        DBInterface.execute(raw, """
            CREATE TABLE epics (
                id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL, color TEXT NOT NULL, created TEXT NOT NULL
            )
        """)
        DBInterface.execute(raw, """
            CREATE TABLE sprints (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, goal TEXT,
                start_date TEXT, end_date TEXT, state TEXT NOT NULL
            )
        """)
        DBInterface.execute(raw, "CREATE TABLE labels (id TEXT PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL)")
        DBInterface.execute(raw, """
            CREATE TABLE issue_labels (
                issue_id TEXT NOT NULL, label_id TEXT NOT NULL, PRIMARY KEY (issue_id, label_id)
            )
        """)
        DBInterface.execute(raw, """
            CREATE TABLE comments (
                id TEXT PRIMARY KEY, issue_id TEXT NOT NULL,
                author_id TEXT NOT NULL, body TEXT NOT NULL, created TEXT NOT NULL
            )
        """)
        DBInterface.execute(raw, """
            CREATE TABLE activity (
                id TEXT PRIMARY KEY, issue_id TEXT NOT NULL, actor_id TEXT,
                kind TEXT NOT NULL, detail TEXT, created TEXT NOT NULL
            )
        """)
        DBInterface.execute(raw, """
            CREATE TABLE outbox (
                id TEXT PRIMARY KEY, event_kind TEXT NOT NULL,
                recipient_email TEXT NOT NULL, subject TEXT NOT NULL,
                body TEXT NOT NULL, created TEXT NOT NULL, sent_at TEXT
            )
        """)
        now = string(Dates.now(UTC))
        DBInterface.execute(raw,
            "INSERT INTO issues (id, key, title, description, status, priority, position, created, updated)
             VALUES ('iss1', 'QCI-100', 'Legacy', '', 'Backlog', 'Medium', 0, ?, ?)",
            [now, now])
        DBInterface.execute(raw,
            "INSERT INTO epics (id, key, name, color, created) VALUES ('ep1', 'EPIC-100', 'OldEpic', 'violet', ?)",
            [now])
        DBInterface.execute(raw,
            "INSERT INTO sprints (id, name, goal, start_date, end_date, state)
             VALUES ('sp1', 'S1', '', NULL, NULL, 'future')")
        # Closed sprint + Done issues still attached → v6 approximate metrics row.
        DBInterface.execute(raw,
            "INSERT INTO sprints (id, name, goal, start_date, end_date, state)
             VALUES ('sp-closed', 'Old Closed', '', NULL, NULL, 'closed')")
        DBInterface.execute(raw,
            "INSERT INTO issues (id, key, title, description, status, priority, story_points,
             sprint_id, position, created, updated)
             VALUES ('iss-done', 'QCI-101', 'Done WO', '', 'Done', 'Medium', 5,
             'sp-closed', 0, ?, ?)",
            [now, now])
        DBInterface.execute(raw,
            "INSERT INTO issues (id, key, title, description, status, priority, story_points,
             sprint_id, position, created, updated)
             VALUES ('iss-done2', 'QCI-102', 'Done WO2', '', 'Done', 'High', 3,
             'sp-closed', 1, ?, ?)",
            [now, now])
        DBInterface.execute(raw,
            "INSERT INTO labels (id, name, color) VALUES ('lb1', 'bug', 'red')")
        SQLite.close(raw)

        bs = S.SQLiteBoardStore(path)
        @test S.board_schema_version(bs) == 6
        projs = S.list_projects(bs)
        @test length(projs) == 1 && projs[1].key == "QCI" && projs[1].name == "Default"
        pid = projs[1].id
        iss = S.get_issue(bs, "iss1")
        @test iss !== nothing && iss.project_id == pid && iss.key == "QCI-100"
        @test iss.asset_tag === nothing && iss.location === nothing && iss.work_type === nothing
        @test S.get_epic(bs, "ep1").project_id == pid
        @test S.get_sprint(bs, "sp1").project_id == pid
        @test only(S.list_labels(bs)).project_id == pid
        # v6 backfill: one approximate metrics row for the closed sprint
        mets = S.list_sprint_metrics(bs; project_id = pid, limit = 8)
        @test length(mets) == 1
        m0 = only(mets)
        @test m0.sprint_id == "sp-closed"
        @test m0.project_id == pid
        @test m0.planned_units == 8 && m0.completed_units == 8
        @test m0.completed_count == 2 && m0.incomplete_count == 0
        @test m0.unit_kind == :points
        # re-open store: v6 is idempotent (still one metrics row)
        S.close!(bs)
        bs2 = S.SQLiteBoardStore(path)
        @test S.board_schema_version(bs2) == 6
        @test length(S.list_sprint_metrics(bs2; project_id = pid)) == 1
        # create under a new project after migrate
        p2 = S.create_project!(bs2; key = "CAPEX", name = "Capex")
        ni = S.create_issue!(bs2; title = "Post-migrate", project_id = p2.id)
        @test startswith(ni.key, "CAPEX-") && ni.project_id == p2.id
        # Default project continues QCI-n past legacy max
        n2 = S.create_issue!(bs2; title = "Next QCI")
        @test startswith(n2.key, "QCI-")
        @test parse(Int, split(n2.key, '-')[end]) >= 103
        S.close!(bs2)
    end
end

# Shared FakeExec helpers for remote project parity (PR-M1b).
_def_project_row(; id = "proj-default", key = "QCI", name = "Default", archived = 0) =
    Dict{String,Any}("id" => id, "key" => key, "name" => name, "description" => "",
                     "color" => "blue", "archived" => archived, "created" => string(now(UTC)))

"""Route project SELECTs to Default (or `projects` map); otherwise call `inner`."""
function _with_projects(inner = (s, p) -> Dict{String,Any}[];
                        projects = Dict{String,Dict{String,Any}}(
                            "proj-default" => _def_project_row()))
    (sql, params) -> begin
        s = String(sql)
        if occursin("FROM projects WHERE key =", s)
            k = String(params[1])
            for d in values(projects)
                String(d["key"]) == k && return [copy(d)]
            end
            return Dict{String,Any}[]
        elseif occursin("FROM projects WHERE id =", s)
            pid = String(params[1])
            return haskey(projects, pid) ? [copy(projects[pid])] : Dict{String,Any}[]
        elseif occursin("FROM projects WHERE archived = 0", s)
            # Match production `ORDER BY key` (include-archived path already sorted).
            rows = [copy(d) for d in values(projects) if !(d["archived"] in (1, true))]
            return sort(rows; by = d -> String(d["key"]))
        elseif occursin("FROM projects ORDER BY key", s)
            return [copy(d) for d in sort(collect(values(projects)); by = d -> String(d["key"]))]
        elseif occursin("INSERT INTO projects", s)
            d = Dict{String,Any}("id" => params[1], "key" => params[2], "name" => params[3],
                "description" => params[4], "color" => params[5], "archived" => params[6],
                "created" => params[7])
            projects[String(params[1])] = d
            return Dict{String,Any}[]
        elseif occursin("UPDATE projects SET archived", s)
            pid = String(params[1])
            haskey(projects, pid) && (projects[pid]["archived"] = 1)
            return Dict{String,Any}[]
        else
            return inner(sql, params)
        end
    end
@testset "Stores: record_sprint_metrics! + list_sprint_metrics" begin
    bs = S.SQLiteBoardStore(":memory:")
    def = only(S.list_projects(bs))
    t0 = DateTime(2026, 1, 1, 12)
    t1 = DateTime(2026, 1, 8, 12)
    m1 = Dm.SprintMetrics(; sprint_id = "sa", project_id = def.id,
                          planned_units = 10, completed_units = 8,
                          completed_count = 3, incomplete_count = 1,
                          unit_kind = :points, closed_at = t0)
    m2 = Dm.SprintMetrics(; sprint_id = "sb", project_id = def.id,
                          planned_units = 12, completed_units = 12,
                          completed_count = 4, incomplete_count = 0,
                          unit_kind = :points, closed_at = t1)
    S.record_sprint_metrics!(bs, m1)
    S.record_sprint_metrics!(bs, m2)
    listed = S.list_sprint_metrics(bs; project_id = def.id, limit = 8)
    @test length(listed) == 2
    @test listed[1].sprint_id == "sa" && listed[2].sprint_id == "sb"  # chronological
    @test listed[1].completed_units == 8 && listed[2].completed_count == 4
    # limit trims oldest
    @test length(S.list_sprint_metrics(bs; project_id = def.id, limit = 1)) == 1
    @test only(S.list_sprint_metrics(bs; project_id = def.id, limit = 1)).sprint_id == "sb"
    # other project is empty
    other = S.create_project!(bs; key = "OTH", name = "Other")
    @test isempty(S.list_sprint_metrics(bs; project_id = other.id))
    # close_sprint! does NOT write metrics (app path owns snapshots)
    sp = S.create_sprint!(bs; name = "Live")
    S.start_sprint!(bs, sp.id)
    S.close_sprint!(bs, sp.id)
    @test isempty(filter(x -> x.sprint_id == sp.id,
                         S.list_sprint_metrics(bs; project_id = def.id, limit = 20)))
end

@testset "Stores: Remote (Postgres) via FakeExec" begin
    @testset "pg_placeholders + row mappers" begin
        @test S.pg_placeholders(3) == "\$1, \$2, \$3"
        @test S.pg_placeholders(1) == "\$1"
        u = S.remote_row_to_user(Dict("id" => "u", "email" => "a@b.co", "name" => "A", "active" => 1, "created" => string(now(UTC))))
        @test u.name == "A" && u.active
        u2 = S.remote_row_to_user(Dict("id" => "u", "email" => "a@b.co", "name" => "A"))  # missing active/created
        @test u2.active
        iss = S.remote_row_to_issue(Dict("id" => "i", "key" => "QCI-1", "title" => "T", "status" => "Backlog",
            "priority" => "Medium", "story_points" => 3, "epic_id" => "e", "sprint_id" => "s",
            "assignee_id" => "a", "reporter_id" => "r", "start_date" => "2026-01-01",
            "due_date" => "2026-01-02", "position" => 2, "description" => "d",
            "created" => string(now(UTC)), "updated" => string(now(UTC)), "project_id" => "p1"))
        @test iss.story_points == 3 && iss.due_date == Date(2026, 1, 2) && iss.position == 2
        @test iss.project_id == "p1"
        iss2 = S.remote_row_to_issue(Dict("id" => "i", "key" => "k", "title" => "T", "status" => "Backlog", "priority" => "Low"))
        @test iss2.description == "" && iss2.epic_id === nothing && iss2.story_points === nothing
        @test iss2.project_id == ""
        ep = S.remote_row_to_epic(Dict("id" => "e", "key" => "EPIC-1", "name" => "N", "color" => "teal", "project_id" => "p1"))
        @test ep.name == "N" && ep.project_id == "p1"
        sp = S.remote_row_to_sprint(Dict("id" => "s", "name" => "S", "state" => "future", "project_id" => "p1"))
        @test sp.state == :future && sp.goal == "" && sp.project_id == "p1"
        cm = S.remote_row_to_comment(Dict("id" => "c", "issue_id" => "i", "author_id" => "u", "body" => "b"))
        @test cm.body == "b"
        lb = S.remote_row_to_label(Dict("id" => "l", "name" => "bug", "color" => "red", "project_id" => "p1"))
        @test lb.color == "red" && lb.project_id == "p1"
        ac = S.remote_row_to_activity(Dict("id" => "a", "issue_id" => "i", "kind" => "moved"))
        @test ac.kind == :moved && ac.actor_id === nothing && ac.detail == ""
        pr = S.remote_row_to_project(_def_project_row())
        @test pr.key == "QCI" && pr.name == "Default" && !pr.archived
        pr2 = S.remote_row_to_project(Dict("id" => "p", "key" => "LA", "name" => "Line", "archived" => 1))
        @test pr2.archived && pr2.color == "blue" && pr2.description == ""
    end

    @testset "remote user store" begin
        fx = S.FakeExec()
        us = S.RemoteUserStore(fx)
        u = S.create_user!(us; email = "a@b.co", name = "A", password = "pw123456")
        @test u.email == "a@b.co"
        @test occursin("INSERT INTO users", fx.calls[end][1])
        @test_throws ArgumentError S.create_user!(us; email = "bad", name = "A", password = "pw123456")

        ph = P.hash_password("pw123456")
        row = Dict{String,Any}("id" => "u", "email" => "a@b.co", "name" => "A",
            "password_hash" => ph.hash_hex, "salt" => ph.salt_hex, "iterations" => ph.iterations, "active" => 1)
        fx_auth = S.FakeExec((sql, p) -> [row])
        @test S.authenticate(S.RemoteUserStore(fx_auth), "a@b.co", "pw123456") !== nothing
        @test S.authenticate(S.RemoteUserStore(fx_auth), "a@b.co", "wrong") === nothing
        @test S.authenticate(S.RemoteUserStore(S.FakeExec()), "a@b.co", "pw") === nothing  # no rows
        inactive = merge(row, Dict("active" => 0))
        @test S.authenticate(S.RemoteUserStore(S.FakeExec((s, p) -> [inactive])), "a@b.co", "pw123456") === nothing

        @test S.get_user(S.RemoteUserStore(S.FakeExec((s, p) -> [Dict("id" => "u", "email" => "a@b.co", "name" => "A", "active" => 1)])), "u").name == "A"
        @test S.get_user(us, "missing") === nothing
        @test length(S.list_users(S.RemoteUserStore(S.FakeExec((s, p) -> [Dict("id" => "u", "email" => "a@b.co", "name" => "A", "active" => 1)])))) == 1
        @test S.deactivate_user!(us, "u")
    end

    @testset "remote board store" begin
        issue_row(; id = "i", key = "QCI-1", status = "Backlog", pos = 0, project_id = "") = Dict{String,Any}(
            "id" => id, "key" => key, "title" => "T", "status" => status, "priority" => "Medium",
            "description" => "d", "position" => pos, "project_id" => project_id)
        # create with explicit + default key (resolves Default project)
        fx = S.FakeExec(_with_projects())
        bs = S.RemoteBoardStore(fx)
        i = S.create_issue!(bs; title = "T", key = "QCI-9", status = "To Do", priority = "High",
                            story_points = 2, epic_id = "e", sprint_id = "s", assignee_id = "a",
                            reporter_id = "r", start_date = Date(2026, 1, 1), due_date = Date(2026, 1, 2), position = 4)
        @test i.key == "QCI-9" && i.position == 4 && i.story_points == 2
        @test i.project_id == "proj-default"
        @test occursin("INSERT INTO issues", fx.calls[end][1])
        @test occursin("project_id", fx.calls[end][1])
        idflt = S.create_issue!(bs; title = "T2")
        @test startswith(idflt.key, "QCI-") && idflt.project_id == "proj-default"
        @test_throws ArgumentError S.create_issue!(bs; title = "x", status = "Nope")
        @test_throws ArgumentError S.create_issue!(bs; title = "x", priority = "Nope")

        @test S.get_issue(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row()])), "i").title == "T"
        @test S.get_issue(bs, "missing") === nothing
        @test length(S.list_issues(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row(), issue_row(id = "i2")])))) == 2
        @test length(S.list_issues(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row()])); status = "Backlog")) == 1
        @test length(S.list_issues(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row()]));
                                   project_id = "proj-default")) == 1
        @test length(S.list_issues(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row()]));
                                   project_id = "proj-default", status = "Backlog")) == 1
        @test length(S.list_issues(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row()])); project_id = "")) == 1

        fx_u = S.FakeExec((s, p) -> [issue_row()])
        bs_u = S.RemoteBoardStore(fx_u)
        @test S.update_issue!(bs_u, "i"; title = "New", status = "Done", due_date = Date(2026, 3, 3)).title == "T"
        @test any(occursin("UPDATE issues SET", c[1]) for c in fx_u.calls)
        @test S.update_issue!(bs_u, "i").title == "T"  # empty kwargs
        # PR-M6 work-order fields on remote create/update
        iwo = S.create_issue!(bs; title = "WO", asset_tag = "CNC-1", location = "Bay", work_type = "PM")
        @test iwo.asset_tag == "CNC-1" && iwo.location == "Bay" && iwo.work_type == "PM"
        @test_throws ArgumentError S.create_issue!(bs; title = "x", work_type = "nope")
        fx_wo = S.FakeExec((s, p) -> [merge(issue_row(), Dict("asset_tag" => "CNC-1", "work_type" => "CM",
                                                              "location" => "Bay 2"))])
        bs_wo = S.RemoteBoardStore(fx_wo)
        @test S.update_issue!(bs_wo, "i"; asset_tag = "  ", location = "Bay 2", work_type = "CM").work_type == "CM"
        @test any(occursin("work_type", c[1]) for c in fx_wo.calls)
        @test_throws ArgumentError S.update_issue!(bs_wo, "i"; work_type = "bogus")
        mapped = S.remote_row_to_issue(Dict("id" => "i", "key" => "k", "title" => "T", "status" => "Backlog",
                                            "priority" => "Low", "asset_tag" => "A1", "location" => "",
                                            "work_type" => "Safety"))
        @test mapped.asset_tag == "A1" && mapped.location === nothing && mapped.work_type == "Safety"
        @test S.delete_issue!(S.RemoteBoardStore(S.FakeExec((s, p) -> [issue_row()])), "i")
        @test !S.delete_issue!(bs, "i")  # no row → false

        fx_m = S.FakeExec((s, p) -> [issue_row(status = "To Do", pos = 1)])
        bs_m = S.RemoteBoardStore(fx_m)
        @test S.move_issue!(bs_m, "i"; status = "To Do", position = 1).status == "To Do"
        @test S.move_issue!(bs_m, "i"; status = "Review").status == "To Do"
        @test S.move_issue!(bs_m, "i"; position = 3) !== nothing
        @test S.move_issue!(bs_m, "i") !== nothing  # neither → get_issue
        @test_throws ArgumentError S.move_issue!(bs_m, "i"; status = "Nope")
        @test S.rank_issue!(bs_m, "i"; position = 0) !== nothing

        # epics (Default project + {KEY}-E-n keys)
        fx_e = S.FakeExec(_with_projects((s, p) -> [Dict("id" => "e", "key" => "QCI-E-1", "name" => "N",
                                                        "color" => "teal", "project_id" => "proj-default")]))
        bs_e = S.RemoteBoardStore(fx_e)
        @test S.create_epic!(bs_e; name = "N", key = "QCI-E-3").key == "QCI-E-3"
        @test startswith(S.create_epic!(bs_e; name = "N").key, "QCI-E-")
        @test S.get_epic(bs_e, "e").name == "N"
        @test S.get_epic(bs, "missing") === nothing
        @test length(S.list_epics(bs_e)) == 1
        @test length(S.list_epics(bs_e; project_id = "proj-default")) == 1
        @test S.update_epic!(bs_e, "e"; name = "M", color = "red").name == "N"
        @test S.update_epic!(bs_e, "e").name == "N"  # no-op
        @test S.delete_epic!(bs_e, "e")

        # sprints — stateful responder so start/close reflect UPDATEs
        sprint_row(state; project_id = "proj-default") =
            [Dict{String,Any}("id" => "s", "name" => "S", "goal" => "g", "state" => state,
                              "project_id" => project_id)]
        sprint_state = Ref("future")
        fx_s = S.FakeExec(_with_projects((sql, p) -> begin
            if occursin("UPDATE sprints SET state", sql)
                sprint_state[] = String(p[1]); Dict{String,Any}[]
            elseif occursin("state = 'active'", sql)
                sprint_state[] == "active" ? sprint_row("active") : Dict{String,Any}[]
            else
                sprint_row(sprint_state[])
            end
        end))
        bs_s = S.RemoteBoardStore(fx_s)
        @test S.create_sprint!(bs_s; name = "S", start_date = Date(2026, 1, 1), end_date = Date(2026, 1, 14)).state == :future
        @test S.get_sprint(bs_s, "s").name == "S"
        @test S.get_sprint(bs, "missing") === nothing
        @test length(S.list_sprints(bs_s)) == 1
        @test length(S.list_sprints(bs_s; project_id = "proj-default")) == 1
        @test S.active_sprint(bs_s) === nothing
        @test S.start_sprint!(bs_s, "s").state == :active
        @test S.active_sprint(bs_s) !== nothing
        @test S.active_sprint(bs_s; project_id = "proj-default") !== nothing
        @test_throws ArgumentError S.start_sprint!(bs, "missing")
        @test_throws ArgumentError S.close_sprint!(bs, "missing")
        @test S.close_sprint!(bs_s, "s").state == :closed
        @test S.update_sprint!(bs_s, "s"; name = "S!", goal = "g2", start_date = Date(2026, 2, 1), end_date = Date(2026, 2, 2)).name == "S"
        @test S.update_sprint!(bs_s, "s").name == "S"  # no-op
        # single-active rejection when an active exists
        fx_active = S.FakeExec(_with_projects((sql, p) ->
            sprint_row(occursin("state = 'active'", sql) ? "active" : "future")))
        @test_throws ArgumentError S.start_sprint!(S.RemoteBoardStore(fx_active), "s")

        # labels
        fx_l = S.FakeExec(_with_projects((s, p) -> begin
            # set_labels! probes the issue for archive guard — missing issue → no assert.
            occursin("FROM issues", String(s)) && return Dict{String,Any}[]
            [Dict{String,Any}("id" => "l", "name" => "bug", "color" => "red",
                              "project_id" => "proj-default")]
        end))
        bs_l = S.RemoteBoardStore(fx_l)
        @test S.create_label!(bs_l; name = "bug").name == "bug"
        @test length(S.list_labels(bs_l)) == 1
        @test length(S.list_labels(bs_l; project_id = "proj-default")) == 1
        @test S.set_labels!(bs_l, "i", ["l1", "l2"]) == ["l1", "l2"]
        fx_lf = S.FakeExec((s, p) -> [Dict("label_id" => "l1"), Dict("label_id" => "l2")])
        @test S.labels_for_issue(S.RemoteBoardStore(fx_lf), "i") == ["l1", "l2"]

        # comments + activity
        fx_c = S.FakeExec((s, p) -> [Dict("id" => "c", "issue_id" => "i", "author_id" => "u", "body" => "b", "created" => string(now(UTC)))])
        bs_c = S.RemoteBoardStore(fx_c)
        @test S.add_comment!(bs_c; issue_id = "i", author_id = "u", body = "b").body == "b"
        @test length(S.list_comments(bs_c, "i")) == 1
        fx_a = S.FakeExec((s, p) -> [Dict("id" => "a", "issue_id" => "i", "kind" => "moved", "detail" => "x")])
        bs_a = S.RemoteBoardStore(fx_a)
        @test S.log_activity!(bs_a; issue_id = "i", actor_id = "u", kind = :moved, detail = "x").kind == :moved
        @test S.log_activity!(bs_a; issue_id = "i", kind = :created).actor_id === nothing
        @test length(S.list_activity(bs_a, "i")) == 1

        # membership queries
        fx_mem = S.FakeExec((s, p) -> [issue_row()])
        bs_mem = S.RemoteBoardStore(fx_mem)
        @test length(S.issues_for_sprint(bs_mem, "s")) == 1
        @test length(S.backlog_issues(bs_mem)) == 1
        @test length(S.backlog_issues(bs_mem; project_id = "proj-default")) == 1

        # outbox
        obrow = [Dict{String,Any}("id" => "o", "event_kind" => "assigned", "recipient_email" => "a@b.co",
            "subject" => "s", "body" => "b", "created" => string(now(UTC)))]
        fx_o = S.FakeExec((s, p) -> obrow)
        bs_o = S.RemoteBoardStore(fx_o)
        @test !isempty(S.enqueue_outbox!(bs_o; event_kind = :assigned, recipient_email = "a@b.co", subject = "s", body = "b"))
        @test S.pending_outbox(bs_o)[1]["id"] == "o"
        @test S.mark_sent!(bs_o, "o")
    end

    @testset "remote project CRUD + optional project_id" begin
        projects = Dict{String,Dict{String,Any}}("proj-default" => _def_project_row())
        sprints = Dict{String,Dict{String,Any}}()
        issues = Dict{String,Dict{String,Any}}()
        epics = Dict{String,Dict{String,Any}}()
        labels = Dict{String,Dict{String,Any}}()
        seq = Dict{Any,Int}()
        fx = S.FakeExec(_with_projects((sql, p) -> begin
            s = String(sql)
            if occursin("INSERT INTO sprints", s)
                d = Dict{String,Any}("id" => p[1], "name" => p[2], "goal" => p[3],
                    "start_date" => p[4], "end_date" => p[5], "state" => p[6], "project_id" => p[7])
                sprints[String(p[1])] = d
                return Dict{String,Any}[]
            elseif occursin("INSERT INTO issues", s)
                d = Dict{String,Any}("id" => p[1], "key" => p[2], "title" => p[3], "description" => p[4],
                    "status" => p[5], "priority" => p[6], "story_points" => p[7], "epic_id" => p[8],
                    "sprint_id" => p[9], "assignee_id" => p[10], "reporter_id" => p[11],
                    "start_date" => p[12], "due_date" => p[13], "position" => p[14],
                    "created" => p[15], "updated" => p[16], "project_id" => p[17])
                issues[String(p[1])] = d
                return Dict{String,Any}[]
            elseif occursin("INSERT INTO epics", s)
                d = Dict{String,Any}("id" => p[1], "key" => p[2], "name" => p[3], "color" => p[4],
                    "created" => p[5], "project_id" => p[6])
                epics[String(p[1])] = d
                return Dict{String,Any}[]
            elseif occursin("INSERT INTO labels", s)
                d = Dict{String,Any}("id" => p[1], "name" => p[2], "color" => p[3], "project_id" => p[4])
                labels[String(p[1])] = d
                return Dict{String,Any}[]
            elseif occursin("SELECT last FROM key_seq", s)
                return haskey(seq, p[1]) ? [Dict{String,Any}("last" => seq[p[1]])] : Dict{String,Any}[]
            elseif occursin("INSERT INTO key_seq", s)
                seq[p[1]] = p[2]; return Dict{String,Any}[]
            elseif occursin("SELECT key FROM issues WHERE key LIKE", s)
                return [Dict{String,Any}("key" => d["key"]) for d in values(issues)]
            elseif occursin("SELECT key FROM epics WHERE key LIKE", s)
                return [Dict{String,Any}("key" => d["key"]) for d in values(epics)]
            elseif occursin("COUNT(*) AS c FROM issues", s)
                return [Dict{String,Any}("c" => count(d -> d["status"] == p[1], values(issues)))]
            # Filtered active: production uses `state = 'active' AND project_id = $1`
            # (archive check uses `project_id = $1 AND state = 'active'`). Both put
            # project_id as $1. Match before the bare unfiltered active query.
            elseif occursin("state = 'active'", s) && occursin("project_id", s)
                rows = [copy(d) for d in values(sprints) if d["project_id"] == p[1] && d["state"] == "active"]
                return isempty(rows) ? Dict{String,Any}[] : [first(rows)]
            elseif occursin("FROM sprints WHERE state = 'active'", s) ||
                   (occursin("state = 'active'", s) && occursin("FROM sprints", s))
                rows = [copy(d) for d in values(sprints) if d["state"] == "active"]
                return isempty(rows) ? Dict{String,Any}[] : [first(rows)]
            elseif occursin("SELECT * FROM sprints WHERE id", s)
                return haskey(sprints, String(p[1])) ? [copy(sprints[String(p[1])])] : Dict{String,Any}[]
            elseif occursin("SELECT * FROM sprints", s) && occursin("project_id", s)
                return [copy(d) for d in values(sprints) if d["project_id"] == p[1]]
            elseif occursin("SELECT * FROM sprints", s)
                return [copy(d) for d in values(sprints)]
            elseif occursin("UPDATE sprints SET state", s)
                sid = String(p[2])
                haskey(sprints, sid) && (sprints[sid]["state"] = p[1])
                return Dict{String,Any}[]
            elseif occursin("SELECT * FROM issues WHERE id", s)
                return haskey(issues, String(p[1])) ? [copy(issues[String(p[1])])] : Dict{String,Any}[]
            elseif occursin("SELECT * FROM issues WHERE project_id", s) && occursin("AND status", s)
                return [copy(d) for d in values(issues) if d["project_id"] == p[1] && d["status"] == p[2]]
            elseif occursin("SELECT * FROM issues WHERE project_id", s)
                return [copy(d) for d in values(issues) if d["project_id"] == p[1]]
            elseif occursin("SELECT * FROM issues", s)
                return [copy(d) for d in values(issues)]
            elseif occursin("SELECT * FROM epics WHERE id", s)
                return haskey(epics, String(p[1])) ? [copy(epics[String(p[1])])] : Dict{String,Any}[]
            elseif occursin("SELECT * FROM epics WHERE project_id", s)
                return [copy(d) for d in values(epics) if d["project_id"] == p[1]]
            elseif occursin("SELECT * FROM epics", s)
                return [copy(d) for d in values(epics)]
            elseif occursin("SELECT * FROM labels WHERE project_id", s)
                return [copy(d) for d in values(labels) if d["project_id"] == p[1]]
            elseif occursin("SELECT * FROM labels", s)
                return [copy(d) for d in values(labels)]
            elseif occursin("MAX(version)", s)
                return [Dict{String,Any}("v" => 5)]
            end
            return Dict{String,Any}[]
        end; projects = projects))
        bs = S.RemoteBoardStore(fx)

        def = only(S.list_projects(bs))
        @test def.key == "QCI" && def.id == "proj-default"
        @test S.get_project(bs, def.id).key == "QCI"
        @test S.get_project(bs, "nope") === nothing
        @test S.board_schema_version(bs) == 5

        la = S.create_project!(bs; key = "LA", name = "Line A", description = "site", color = "teal")
        @test la.key == "LA" && la.name == "Line A" && !la.archived
        @test length(S.list_projects(bs)) == 2
        # list_projects ORDER BY key (non-archived harness sorts)
        @test [p.key for p in S.list_projects(bs)] == ["LA", "QCI"]
        @test_throws ArgumentError S.create_project!(bs; key = "LA", name = "Dup")
        @test_throws ArgumentError S.create_project!(bs; key = "bad", name = "X")
        @test_throws ArgumentError S.create_project!(bs; key = "OK", name = "  ")

        i_def = S.create_issue!(bs; title = "On Default")
        @test i_def.project_id == def.id && startswith(i_def.key, "QCI-")
        i_la = S.create_issue!(bs; title = "On LA", project_id = la.id)
        @test i_la.project_id == la.id && startswith(i_la.key, "LA-")
        @test length(S.list_issues(bs; project_id = la.id)) == 1
        @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = "missing")

        e_def = S.create_epic!(bs; name = "Def Epic")
        @test startswith(e_def.key, "QCI-E-") && e_def.project_id == def.id
        e_la = S.create_epic!(bs; name = "LA Epic", project_id = la.id)
        @test startswith(e_la.key, "LA-E-") && e_la.project_id == la.id
        @test length(S.list_epics(bs; project_id = la.id)) == 1

        sp = S.create_sprint!(bs; name = "Win", project_id = la.id)
        @test sp.project_id == la.id
        @test length(S.list_sprints(bs; project_id = la.id)) == 1
        lbl = S.create_label!(bs; name = "PM", project_id = la.id)
        @test lbl.project_id == la.id
        @test length(S.list_labels(bs; project_id = la.id)) == 1

        k1 = S.create_issue!(bs; title = "k1", project_id = la.id).key
        k2 = S.create_issue!(bs; title = "k2", project_id = la.id).key
        @test startswith(k1, "LA-") && startswith(k2, "LA-")
        @test parse(Int, split(k2, '-')[end]) == parse(Int, split(k1, '-')[end]) + 1

        # filtered active_sprint: production SQL is
        # `WHERE state = 'active' AND project_id = $1` — harness must not fall through
        # to the unfiltered active branch. Seed two actives directly (PR-M1 still
        # enforces global single-active via start_sprint!, so API can't dual-start).
        sprints["s-def-act"] = Dict{String,Any}("id" => "s-def-act", "name" => "DefWin",
            "goal" => "", "state" => "active", "project_id" => def.id)
        sprints["s-la-act"] = Dict{String,Any}("id" => "s-la-act", "name" => "LAWin",
            "goal" => "", "state" => "active", "project_id" => la.id)
        @test S.active_sprint(bs; project_id = la.id).id == "s-la-act"
        @test S.active_sprint(bs; project_id = def.id).id == "s-def-act"
        # cleanup seeded actives so archive_project! on LA is not blocked by s-la-act
        delete!(sprints, "s-def-act"); delete!(sprints, "s-la-act")

        S.start_sprint!(bs, sp.id)
        @test_throws ArgumentError S.archive_project!(bs, la.id)  # active sprint blocks
        S.close_sprint!(bs, sp.id)
        # create entities on LA before archive for write-guard tests (SQLite parity)
        sp2 = S.create_sprint!(bs; name = "Win2", project_id = la.id)
        i_la_upd = S.create_issue!(bs; title = "upd target", project_id = la.id)
        e_la_upd = S.create_epic!(bs; name = "ArchEpic", project_id = la.id)
        lbl_la = S.create_label!(bs; name = "LArch", project_id = la.id)
        arch = S.archive_project!(bs, la.id)
        @test arch.archived
        @test length(S.list_projects(bs)) == 1
        @test length(S.list_projects(bs; include_archived = true)) == 2
        @test_throws ArgumentError S.create_issue!(bs; title = "x", project_id = la.id)
        @test_throws ArgumentError S.archive_project!(bs, "missing")
        # archive write guards (mirror SQLite Issue 2 / Issue 8)
        @test_throws ArgumentError S.update_issue!(bs, i_la_upd.id; title = "nope")
        @test_throws ArgumentError S.start_sprint!(bs, sp2.id)
        @test_throws ArgumentError S.move_issue!(bs, i_la_upd.id; status = "To Do")
        @test_throws ArgumentError S.rank_issue!(bs, i_la_upd.id; position = 0)
        @test_throws ArgumentError S.delete_issue!(bs, i_la_upd.id)
        @test_throws ArgumentError S.set_labels!(bs, i_la_upd.id, [lbl_la.id])
        @test_throws ArgumentError S.update_epic!(bs, e_la_upd.id; name = "nope")
        @test_throws ArgumentError S.update_sprint!(bs, sp2.id; name = "nope")
        @test_throws ArgumentError S.delete_epic!(bs, e_la_upd.id)

        # Default archived: omit / empty project_id creates throw; other project works
        other = S.create_project!(bs; key = "LINE2", name = "Line 2")
        S.archive_project!(bs, def.id)
        @test_throws ArgumentError S.create_issue!(bs; title = "into archived default")
        @test_throws ArgumentError S.create_issue!(bs; title = "empty str", project_id = "")
        @test_throws ArgumentError S.create_epic!(bs; name = "into archived default")
        @test_throws ArgumentError S.create_sprint!(bs; name = "into archived default")
        ok = S.create_issue!(bs; title = "on LINE2", project_id = other.id)
        @test ok.project_id == other.id && startswith(ok.key, "LINE2-")
    end
end

@testset "S9: short configured JWT secret rejected (TOML + ENV); 32 chars ok" begin
    @test_throws ArgumentError C.load_config(nothing; env = Dict("QCI_JWT_SECRET" => "tooshort"))
    mktempdir() do dir
        path = joinpath(dir, "c.toml"); write(path, "jwt_secret = \"short\"\n")
        @test_throws ArgumentError C.load_config(path; env = Dict{String,String}())
    end
    ok = C.load_config(nothing; env = Dict("QCI_JWT_SECRET" => "a"^32))
    @test ok.jwt_secret == "a"^32
end

@testset "S6: jwt secret written atomically 0600; symlinked path rejected" begin
    mktempdir() do dir
        spath = joinpath(dir, "jwt.secret")
        cfg = C.AppConfig(; jwt_secret_path = spath)
        s = C.ensure_jwt_secret!(cfg)
        @test (filemode(spath) & 0o777) == 0o600 && length(s) == 64
        link = joinpath(dir, "link.secret")
        symlink(spath, link)
        @test_throws ArgumentError C.ensure_jwt_secret!(C.AppConfig(; jwt_secret_path = link))
    end
end

@testset "S10: pg_conninfo single-quotes + escapes every value" begin
    pc = C.PostgresConfig(; host = "h", port = 5432, dbname = "d", user = "u",
                          password = "p' OR '1'='1")
    ci = S.pg_conninfo(pc)
    @test occursin("host='h'", ci) && occursin("port='5432'", ci) && occursin("dbname='d'", ci)
    @test occursin("\\'", ci)                       # embedded quote is escaped
    @test !occursin("password='p' OR", ci)          # not left unescaped
    @test occursin("\\\\", S.pg_conninfo(C.PostgresConfig(; password = "a\\b")))  # backslash escaped
end

@testset "SQLite: C10 monotonic keys + token_version" begin
    bs = S.SQLiteBoardStore(":memory:")
    a = S.create_issue!(bs; title = "A")
    @test a.key == "QCI-100"
    hi = S.create_issue!(bs; title = "B")
    @test hi.key == "QCI-101"
    S.delete_issue!(bs, hi.id)                       # delete the highest-numbered
    nxt = S.create_issue!(bs; title = "C")
    @test nxt.key == "QCI-102"                        # NOT recycled to 101

    us = S.SQLiteUserStore(":memory:")
    u = S.create_user!(us; email = "tv@b.co", name = "Tv", password = "pw123456")
    @test S.get_token_version(us, u.id) == 0
    @test S.bump_token_version!(us, u.id) == 1
    S.deactivate_user!(us, u.id)                      # deactivate bumps too
    @test S.get_token_version(us, u.id) == 2
end

@testset "Remote: token_version + deactivate bump (FakeExec)" begin
    tv = Ref(0)
    fx = S.FakeExec((sql, p) -> begin
        if occursin("token_version = token_version + 1", sql)
            tv[] += 1; Dict{String,Any}[]
        elseif occursin("SELECT token_version", sql)
            [Dict{String,Any}("token_version" => tv[])]
        else
            Dict{String,Any}[]
        end
    end)
    us = S.RemoteUserStore(fx)
    @test S.get_token_version(us, "u") == 0
    @test S.bump_token_version!(us, "u") == 1
    @test S.deactivate_user!(us, "u")
    @test tv[] == 2
end

# ── Minimal in-memory Postgres model: interprets exactly the SQL the remote
# board store emits, so C2/C3/C4/C10 semantics are verified (not string-matched).
mutable struct InMemPG
    issues::Vector{Dict{String,Any}}
    projects::Dict{String,Dict{String,Any}}
    seq::Dict{Any,Int}
end
function InMemPG()
    def = _def_project_row()
    InMemPG(Dict{String,Any}[], Dict{String,Dict{String,Any}}(String(def["id"]) => def), Dict{Any,Int}())
end
const _ISSUE_COLS = ["id","key","title","description","status","priority","story_points",
    "epic_id","sprint_id","assignee_id","reporter_id","start_date","due_date","position",
    "created","updated","project_id"]
function (db::InMemPG)(sql::AbstractString, params::AbstractVector)
    s = String(sql)
    _sortkey(r) = (r["position"], r["key"])
    if occursin("INSERT INTO issues", s)
        push!(db.issues, Dict{String,Any}(_ISSUE_COLS[i] => params[i] for i in eachindex(_ISSUE_COLS)))
        return Dict{String,Any}[]
    elseif occursin("FROM projects WHERE key =", s)
        k = String(params[1])
        for d in values(db.projects)
            String(d["key"]) == k && return [copy(d)]
        end
        return Dict{String,Any}[]
    elseif occursin("FROM projects WHERE id =", s)
        pid = String(params[1])
        return haskey(db.projects, pid) ? [copy(db.projects[pid])] : Dict{String,Any}[]
    elseif occursin("SELECT last FROM key_seq", s)
        return haskey(db.seq, params[1]) ? [Dict{String,Any}("last" => db.seq[params[1]])] : Dict{String,Any}[]
    elseif occursin("INSERT INTO key_seq", s)
        db.seq[params[1]] = params[2]; return Dict{String,Any}[]
    elseif occursin("SELECT key FROM issues WHERE key LIKE", s)
        # LIKE pattern e.g. "QCI-%" — return matching keys for max-suffix parse.
        pat = String(params[1])
        pref = endswith(pat, "%") ? pat[1:end-1] : pat
        return [Dict{String,Any}("key" => r["key"]) for r in db.issues if startswith(String(r["key"]), pref)]
    elseif occursin("COUNT(*) AS c FROM issues", s)
        return [Dict{String,Any}("c" => count(r -> r["status"] == params[1], db.issues))]
    elseif occursin("SELECT * FROM issues WHERE id", s)
        i = findfirst(r -> r["id"] == params[1], db.issues)
        return i === nothing ? Dict{String,Any}[] : [copy(db.issues[i])]
    elseif occursin("SELECT id FROM issues WHERE status", s) && occursin("AND id !=", s)
        rows = sort([r for r in db.issues if r["status"] == params[1] && r["id"] != params[2]], by = _sortkey)
        return [Dict{String,Any}("id" => r["id"]) for r in rows]
    elseif occursin("SELECT id FROM issues WHERE status", s)
        rows = sort([r for r in db.issues if r["status"] == params[1]], by = _sortkey)
        return [Dict{String,Any}("id" => r["id"]) for r in rows]
    elseif occursin("SELECT * FROM issues WHERE project_id", s) && occursin("AND status", s)
        rows = sort([r for r in db.issues if r["project_id"] == params[1] && r["status"] == params[2]], by = _sortkey)
        return [copy(r) for r in rows]
    elseif occursin("SELECT * FROM issues WHERE project_id", s)
        rows = sort([r for r in db.issues if r["project_id"] == params[1]],
                    by = r -> (r["status"], r["position"], r["key"]))
        return [copy(r) for r in rows]
    elseif occursin("SELECT * FROM issues WHERE status", s)
        rows = sort([r for r in db.issues if r["status"] == params[1]], by = _sortkey)
        return [copy(r) for r in rows]
    elseif occursin("SELECT * FROM issues ORDER BY", s)
        return [copy(r) for r in sort(db.issues, by = r -> (r["status"], r["position"], r["key"]))]
    elseif occursin("UPDATE issues SET status", s)
        i = findfirst(r -> r["id"] == params[4], db.issues)
        i === nothing || (db.issues[i]["status"] = params[1]; db.issues[i]["position"] = params[2])
        return Dict{String,Any}[]
    elseif occursin("UPDATE issues SET position", s)
        i = findfirst(r -> r["id"] == params[2], db.issues)
        i === nothing || (db.issues[i]["position"] = params[1])
        return Dict{String,Any}[]
    elseif occursin("DELETE FROM issues WHERE id", s)
        filter!(r -> r["id"] != params[1], db.issues); return Dict{String,Any}[]
    end
    return Dict{String,Any}[]   # issue_labels deletes, generic field updates, etc.
end

@testset "Remote board semantics via in-memory PG (C2/C3/C4/C10)" begin
    bs = S.RemoteBoardStore(InMemPG())
    a = S.create_issue!(bs; title = "A", status = "Backlog")
    b = S.create_issue!(bs; title = "B", status = "Backlog")
    c = S.create_issue!(bs; title = "C", status = "Backlog")
    # C2: sequential MAX+1 keys + append positions (not random / not constant 0)
    @test [a.key, b.key, c.key] == ["QCI-100", "QCI-101", "QCI-102"]
    @test [a.position, b.position, c.position] == [0, 1, 2]
    # C3: move reindexes vacated column dense
    S.move_issue!(bs, a.id; status = "To Do")
    @test [x.position for x in S.list_issues(bs; status = "Backlog")] == [0, 1]
    @test S.get_issue(bs, a.id).status == "To Do" && S.get_issue(bs, a.id).position == 0
    S.rank_issue!(bs, c.id; position = 0)
    bl = S.list_issues(bs; status = "Backlog")
    @test bl[1].id == c.id && [x.position for x in bl] == [0, 1]
    # C4: update_issue! validates + routes status through move (stays dense)
    S.update_issue!(bs, b.id; status = "To Do")
    @test [x.position for x in S.list_issues(bs; status = "To Do")] == [0, 1]
    # position via update_issue! → routed through move (dense)
    S.update_issue!(bs, b.id; position = 0)
    @test S.list_issues(bs; status = "To Do")[1].id == b.id
    @test_throws ArgumentError S.update_issue!(bs, b.id; status = "Nope")
    @test_throws ArgumentError S.update_issue!(bs, b.id; priority = "Nope")
    # C10: delete the highest key, then create → key never recycled
    hi = S.create_issue!(bs; title = "D", status = "Backlog")
    @test hi.key == "QCI-103"
    S.delete_issue!(bs, hi.id)
    nxt = S.create_issue!(bs; title = "E", status = "Backlog")
    @test nxt.key == "QCI-104"
    bkl = S.list_issues(bs; status = "Backlog")
    @test [x.position for x in bkl] == collect(0:length(bkl) - 1)   # dense after delete
end
