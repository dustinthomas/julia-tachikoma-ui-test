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
    end

    @testset "User" begin
        u = D.User(; id = "u1", email = "a@b.co", name = "Alex")
        @test u.id == "u1" && u.active == true
        @test u.created isa DateTime
        u2 = D.User(; id = "u2", email = "x@y.co", name = "X", active = false)
        @test u2.active == false
        @test_throws ArgumentError D.User(; id = "u", email = "bad", name = "n")
        @test_throws ArgumentError D.User(; id = "u", email = "a@b.co", name = "   ")
    end

    @testset "Issue" begin
        i = D.Issue(; id = "i1", key = "QCI-1", title = "T")
        @test i.status == "Backlog" && i.priority == "Medium"
        @test i.story_points === nothing && i.labels == String[]
        i2 = D.Issue(; id = "i2", key = "QCI-2", title = "T2", status = "Done",
                     priority = "High", story_points = 5, epic_id = "e", sprint_id = "s",
                     assignee_id = "a", reporter_id = "r", start_date = Date(2026, 1, 1),
                     due_date = Date(2026, 1, 2), position = 3, labels = ["l1"])
        @test i2.story_points == 5 && i2.epic_id == "e" && i2.labels == ["l1"]
        @test i2.due_date == Date(2026, 1, 2) && i2.position == 3
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "  ")
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", status = "Nope")
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", priority = "Nope")
        @test_throws ArgumentError D.Issue(; id = "i", key = "k", title = "t", story_points = -1)
    end

    @testset "Epic / Label / Comment" begin
        e = D.Epic(; id = "e1", key = "EPIC-1", name = "Onboarding")
        @test e.color == "violet"
        @test_throws ArgumentError D.Epic(; id = "e", key = "k", name = "")
        l = D.Label(; id = "l1", name = "bug")
        @test l.color == "blue"
        @test_throws ArgumentError D.Label(; id = "l", name = " ")
        c = D.Comment(; id = "c1", issue_id = "i1", author_id = "u1", body = "hi")
        @test c.body == "hi"
        @test_throws ArgumentError D.Comment(; id = "c", issue_id = "i", author_id = "u", body = "")
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
        @test s.state == :future && s.goal == ""
        @test_throws ArgumentError D.Sprint(; id = "s", name = "")
        @test_throws ArgumentError D.Sprint(; id = "s", name = "n", state = :bogus)

        @test D.can_transition(:future, :active)
        @test D.can_transition(:active, :closed)
        @test !D.can_transition(:future, :closed)
        @test !D.can_transition(:closed, :active)
        @test !D.can_transition(:active, :future)

        active = D.transition(s, :active)
        @test active.state == :active && active.id == s.id
        closed = D.transition(active, :closed)
        @test closed.state == :closed
        @test_throws ArgumentError D.transition(s, :closed)
        @test_throws ArgumentError D.transition(closed, :active)
    end
end
