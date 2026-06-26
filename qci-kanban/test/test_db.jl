using Test
using SQLite
using DBInterface
using Tables: columntable
using Dates: now, UTC

# Load the package (brings DB submodule)
using QciKanban
const DB = QciKanban.DB

@testset "QciKanban DB: schema + CRUD + seed (isolated temp DB)" begin

    @testset "open + init_schema on :memory:" begin
        db = DB.open_db(":memory:")
        @test db isa SQLite.DB
        # Tables exist
        tables = DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table'") |> columntable
        names = tables.name
        @test "users" in names
        @test "issues" in names
        DB.close_db(db)
    end

    @testset "user create + list + get" begin
        db = DB.open_db(":memory:")
        id = DB.create_user!(db, "Test User")
        @test !isempty(id)

        users = DB.list_users(db)
        @test length(users) == 1
        @test users[1]["name"] == "Test User"

        u = DB.get_user(db, id)
        @test u !== nothing
        @test u["name"] == "Test User"
        DB.close_db(db)
    end

    @testset "issue create + list by status + get + update status" begin
        db = DB.open_db(":memory:")
        uid = DB.create_user!(db, "Owner")

        iid = DB.create_issue!(db;
            title = "First card",
            status = "To Do",
            priority = "High",
            assignee_id = uid,
            position = 0
        )
        @test startswith(iid, "-") || length(iid) > 10  # uuid-ish

        todo = DB.list_issues(db; status="To Do")
        @test length(todo) == 1
        @test todo[1]["title"] == "First card"
        @test todo[1]["key"] == "QCI-101" || startswith(todo[1]["key"], "QCI-")

        got = DB.get_issue(db, iid)
        @test got !== nothing
        @test got["status"] == "To Do"

        # move
        DB.update_issue_status_and_position!(db, iid, "In Progress", 5)
        moved = DB.get_issue(db, iid)
        @test moved["status"] == "In Progress"
        @test moved["position"] == 5

        DB.close_db(db)
    end

    @testset "seed_demo creates sample data only once" begin
        db = DB.open_db(":memory:")
        DB.seed_demo!(db)
        users = DB.list_users(db)
        @test length(users) >= 2
        all_iss = DB.list_issues(db)
        @test length(all_iss) >= 5

        # calling again does nothing
        DB.seed_demo!(db)
        @test length(DB.list_issues(db)) == length(all_iss)
        DB.close_db(db)
    end

    @testset "delete_issue" begin
        db = DB.open_db(":memory:")
        iid = DB.create_issue!(db; title="to be deleted", status="Backlog")
        @test DB.get_issue(db, iid) !== nothing
        DB.delete_issue!(db, iid)
        @test DB.get_issue(db, iid) === nothing
        DB.close_db(db)
    end
end
