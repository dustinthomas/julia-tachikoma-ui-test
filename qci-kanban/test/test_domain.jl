# Unit tests for QciKanban.Domain — types, validators, sprint state machine.
using Test
using Dates
const D = QciKanban.Domain

@testset "Domain types + validators" begin
    @testset "validators" begin
        @test D.valid_email("a@b.co")
        @test D.valid_email("first.last+tag@sub.example.com")
        @test !D.valid_email("nope")
        @test !D.valid_email("no@domain")
        @test !D.valid_email("@b.co")
        @test D.valid_priority("High") && D.valid_priority("Medium") && D.valid_priority("Low")
        @test !D.valid_priority("Urgent")
        @test D.valid_status("Backlog") && D.valid_status("Done")
        @test !D.valid_status("Archived")
        @test D.valid_sprint_state(:future) && D.valid_sprint_state(:active) && D.valid_sprint_state(:closed)
        @test !D.valid_sprint_state(:paused)
        @test D.valid_notification_kind(:assigned) && D.valid_notification_kind(:mentioned)
        @test !D.valid_notification_kind(:bogus)
        @test D.valid_project_key("QCI") && D.valid_project_key("LA") && D.valid_project_key("LINE2")
        @test D.valid_project_key("MAINT") && D.valid_project_key("A1") && D.valid_project_key("ABCDEFGH")
        @test !D.valid_project_key("") && !D.valid_project_key("A") && !D.valid_project_key("abcdefgh")
        @test !D.valid_project_key("qci") && !D.valid_project_key("QC-1") && !D.valid_project_key("ABCDEFGHI")
        @test D.valid_work_type(nothing) && D.valid_work_type("PM") && D.valid_work_type("CM")
        @test D.valid_work_type("Improvement") && D.valid_work_type("Safety") && D.valid_work_type("Other")
        @test !D.valid_work_type("Emergency") && !D.valid_work_type("pm")
        @test D.WORK_TYPES == ("PM", "CM", "Improvement", "Safety", "Other")
    end

    @testset "Project" begin
        p = D.Project(; id = "p1", key = "QCI", name = "Default")
        @test p.key == "QCI" && p.name == "Default" && p.archived == false
        @test p.description == "" && p.color == "blue"
        p2 = D.Project(; id = "p2", key = "LA", name = "Line A", description = "plant",
                       color = "teal", archived = true)
        @test p2.archived && p2.color == "teal"
        @test_throws ArgumentError D.Project(; id = "p", key = "bad", name = "n")
        @test_throws ArgumentError D.Project(; id = "p", key = "QCI", name = "  ")
    end

    @testset "User" begin
        u = D.User(; id = "u1", email = "a@b.co", name = "Alex")
        @test u.id == "u1" && u.active == true
        @test u.created isa DateTime
        @test u.role == "supervisor"   # PR-H1 keyword default
        u2 = D.User(; id = "u2", email = "x@y.co", name = "X", active = false)
        @test u2.active == false
        u3 = D.User(; id = "u3", email = "a@b.co", name = "A", role = "admin")
        @test u3.role == "admin"
        @test_throws ArgumentError D.User(; id = "u", email = "bad", name = "n")
        @test_throws ArgumentError D.User(; id = "u", email = "a@b.co", name = "   ")
        @test_throws ArgumentError D.User(; id = "u", email = "a@b.co", name = "n", role = "nope")
    end

    @testset "USER_ROLES / valid_role / can (PR-H1)" begin
        @test D.USER_ROLES == ("admin", "supervisor", "technician", "viewer")
        @test D.valid_role("admin") && D.valid_role("viewer")
        @test !D.valid_role("nope") && !D.valid_role("")
        admin = D.User(; id = "a", email = "a@b.co", name = "A", role = "admin")
        sup = D.User(; id = "s", email = "s@b.co", name = "S", role = "supervisor")
        tech = D.User(; id = "t", email = "t@b.co", name = "T", role = "technician")
        view = D.User(; id = "v", email = "v@b.co", name = "V", role = "viewer")
        inactive = D.User(; id = "i", email = "i@b.co", name = "I", role = "admin", active = false)
        mine = D.Issue(; id = "i1", key = "QCI-1", title = "Mine", assignee_id = "t")
        other = D.Issue(; id = "i2", key = "QCI-2", title = "Other", assignee_id = "s")
        unassigned = D.Issue(; id = "i3", key = "QCI-3", title = "Free")
        # unauthenticated / inactive
        @test !D.can(nothing, :edit_issue)
        @test !D.can(inactive, :edit_issue)
        # admin full
        for act in (:view_board, :edit_issue, :create_issue, :delete_issue,
                    :manage_sprint, :manage_project, :export_csv, :manage_users)
            @test D.can(admin, act)
        end
        # viewer read-only
        @test D.can(view, :view_board)
        @test !D.can(view, :delete_issue) && !D.can(view, :create_issue)
        @test !D.can(view, :edit_issue; resource = mine)
        # technician: create yes; edit only assigned
        @test D.can(tech, :create_issue)
        @test D.can(tech, :edit_issue; resource = mine)
        @test !D.can(tech, :edit_issue; resource = other)
        @test !D.can(tech, :edit_issue; resource = unassigned)
        @test !D.can(tech, :edit_issue)  # no resource → deny
        @test !D.can(tech, :delete_issue)
        @test D.can(tech, :export_csv)
        # supervisor work + no user-admin
        @test D.can(sup, :edit_issue; resource = other) && D.can(sup, :manage_sprint)
        @test !D.can(sup, :manage_users)
        @test !D.can(admin, :bogus_action)
    end

    @testset "Issue" begin
        i = D.Issue(; id = "i1", key = "QCI-1", title = "T")
        @test i.status == "Backlog" && i.priority == "Medium"
        @test i.story_points === nothing && i.labels == String[]
        @test i.project_id == ""
        @test i.asset_tag === nothing && i.location === nothing && i.work_type === nothing
        i2 = D.Issue(; id = "i2", key = "QCI-2", title = "T2", status = "Done",
                     priority = "High", story_points = 5, epic_id = "e", sprint_id = "s",
                     assignee_id = "a", reporter_id = "r", start_date = Date(2026, 1, 1),
                     due_date = Date(2026, 1, 2), position = 3, labels = ["l1"],
                     project_id = "p1", asset_tag = "CNC-01", location = "Bay 2",
                     work_type = "CM")
        @test i2.story_points == 5 && i2.epic_id == "e" && i2.labels == ["l1"]
        @test i2.due_date == Date(2026, 1, 2) && i2.position == 3 && i2.project_id == "p1"
        @test i2.asset_tag == "CNC-01" && i2.location == "Bay 2" && i2.work_type == "CM"
        # blank optional strings normalize to nothing
        i3 = D.Issue(; id = "i3", key = "QCI-3", title = "T3", asset_tag = "  ", location = "")
        @test i3.asset_tag === nothing && i3.location === nothing
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "  ")
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", status = "Nope")
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", priority = "Nope")
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", story_points = -1)
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", work_type = "bogus")
    end

    @testset "issues_to_csv (pure)" begin
        empty_csv = D.issues_to_csv(D.Issue[])
        @test startswith(empty_csv, "key,title,status,")
        @test count(==('\n'), empty_csv) == 1  # header only + trailing newline
        iss = D.Issue(; id = "i1", key = "QCI-1", title = "Fix, \"quoted\"",
                      description = "line1\nline2", status = "To Do", priority = "High",
                      story_points = 3, asset_tag = "CNC-01", location = "Bay 2",
                      work_type = "PM", labels = ["a", "b"], project_id = "p1",
                      start_date = Date(2026, 3, 1), due_date = Date(2026, 3, 8))
        csv = D.issues_to_csv([iss])
        @test startswith(csv, "key,title,status,priority")
        @test occursin("QCI-1", csv)
        @test occursin("\"Fix, \"\"quoted\"\"\"", csv)  # RFC 4180 escape of comma+quotes
        @test occursin("\"line1\nline2\"", csv)        # newline field is quoted
        @test occursin("CNC-01", csv)
        @test occursin("a|b", csv)
        @test occursin("2026-03-01", csv)
        # nothing cells are empty between commas
        bare = D.Issue(; id = "i2", key = "X-1", title = "Bare")
        bare_csv = D.issues_to_csv([bare])
        @test occursin("X-1,Bare,Backlog,Medium,", bare_csv)
    end

    @testset "Epic / Label / Comment" begin
        e = D.Epic(; id = "e1", key = "QCI-E-1", name = "Onboarding")
        @test e.color == "violet" && e.project_id == ""
        e2 = D.Epic(; id = "e2", key = "LA-E-1", name = "Line", project_id = "p1")
        @test e2.project_id == "p1"
        @test_throws ArgumentError D.Epic(; id = "e", key = "k", name = "")
        l = D.Label(; id = "l1", name = "bug")
        @test l.color == "blue" && l.project_id == ""
        l2 = D.Label(; id = "l2", name = "PM", project_id = "p1")
        @test l2.project_id == "p1"
        @test_throws ArgumentError D.Label(; id = "l", name = " ")
        c = D.Comment(; id = "c1", issue_id = "i1", author_id = "u1", body = "hi")
        @test c.body == "hi"
        @test_throws ArgumentError D.Comment(; id = "c", issue_id = "i", author_id = "u", body = "")
    end

    @testset "SprintMetrics + sum_units" begin
        sm = D.SprintMetrics(; sprint_id = "s1", project_id = "p1",
                             planned_units = 13, completed_units = 8,
                             completed_count = 2, incomplete_count = 1)
        @test sm.unit_kind == :points && sm.planned_units == 13
        @test sm.completed_count == 2 && sm.incomplete_count == 1
        @test_throws ArgumentError D.SprintMetrics(; sprint_id = "s", project_id = "p",
                                                   planned_units = -1)
        @test_throws ArgumentError D.SprintMetrics(; sprint_id = "s", project_id = "p",
                                                   unit_kind = :hours)
        iss = [
            D.Issue(; id = "1", key = "QCI-1", title = "a", story_points = 5),
            D.Issue(; id = "2", key = "QCI-2", title = "b", story_points = nothing),
            D.Issue(; id = "3", key = "QCI-3", title = "c", story_points = 3),
        ]
        @test D.sum_units(iss) == 8
        @test D.sum_units(D.Issue[]) == 0
    end

    @testset "IssueLink + LINK_TYPES + would_blocks_cycle (G6a)" begin
        @test D.LINK_TYPES == ("blocks", "relates_to")
        @test D.valid_link_type("blocks") && D.valid_link_type("relates_to")
        @test !D.valid_link_type("depends_on") && !D.valid_link_type("blocked_by")
        ln = D.IssueLink(; id = "l1", from_id = "a", to_id = "b")
        @test ln.kind == "blocks" && ln.from_id == "a" && ln.to_id == "b"
        ln2 = D.IssueLink(; id = "l2", from_id = "a", to_id = "c", kind = "relates_to")
        @test ln2.kind == "relates_to"
        @test_throws ArgumentError D.IssueLink(; id = "x", from_id = "a", to_id = "b", kind = "blocked_by")
        @test_throws ArgumentError D.IssueLink(; id = "x", from_id = "  ", to_id = "b")
        @test_throws ArgumentError D.IssueLink(; id = "x", from_id = "a", to_id = "")

        # Pure cycle helper: self-loop
        @test D.would_blocks_cycle(Tuple{String,String}[], "a", "a")
        # No edges: A→B ok
        @test !D.would_blocks_cycle(Tuple{String,String}[], "a", "b")
        # A→B→C: closing C→A or C→B cycles; C→D is fine
        edges = [("a", "b"), ("b", "c")]
        @test D.would_blocks_cycle(edges, "c", "a")
        @test D.would_blocks_cycle(edges, "c", "b")   # b→c + c→b
        @test !D.would_blocks_cycle(edges, "c", "d")
        # direct reverse of existing edge
        @test D.would_blocks_cycle([("a", "b")], "b", "a")
        # longer chain
        chain = [("1", "2"), ("2", "3"), ("3", "4")]
        @test D.would_blocks_cycle(chain, "4", "1")
        @test !D.would_blocks_cycle(chain, "1", "4")  # forward edge along existing path ≠ cycle
        @test !D.would_blocks_cycle(chain, "4", "5")
    end

    @testset "ActivityEvent" begin
        a = D.ActivityEvent(; id = "a1", issue_id = "i1", kind = :created)
        @test a.actor_id === nothing && a.detail == ""
        a2 = D.ActivityEvent(; id = "a2", issue_id = "i1", actor_id = "u1", kind = :moved, detail = "x")
        @test a2.actor_id == "u1" && a2.kind == :moved
    end

    @testset "NotificationEvent" begin
        n = D.NotificationEvent(; kind = :assigned, recipient_email = "a@b.co",
                                actor_name = "Alex", issue_key = "QCI-1", issue_title = "T")
        @test n.kind == :assigned && n.issue_key == "QCI-1"
        @test_throws ArgumentError D.NotificationEvent(; kind = :bogus, recipient_email = "a@b.co")
        @test_throws ArgumentError D.NotificationEvent(; kind = :assigned, recipient_email = "bad")
    end

    @testset "Sprint + state machine" begin
        s = D.Sprint(; id = "s1", name = "Sprint 1")
        @test s.state == :future && s.goal == "" && s.project_id == ""
        s_p = D.Sprint(; id = "s2", name = "S2", project_id = "p1")
        @test s_p.project_id == "p1"
        @test_throws ArgumentError D.Sprint(; id = "s", name = "")
        @test_throws ArgumentError D.Sprint(; id = "s", name = "n", state = :bogus)

        @test D.can_transition(:future, :active)
        @test D.can_transition(:active, :closed)
        @test !D.can_transition(:future, :closed)
        @test !D.can_transition(:closed, :active)
        @test !D.can_transition(:active, :future)

        active = D.transition(s, :active)
        @test active.state == :active && active.id == s.id && active.project_id == s.project_id
        active_p = D.transition(s_p, :active)
        @test active_p.project_id == "p1"
        closed = D.transition(active, :closed)
        @test closed.state == :closed
        @test_throws ArgumentError D.transition(s, :closed)
        @test_throws ArgumentError D.transition(closed, :active)
    end
end
