# Unit tests for QciKanban.Notify — templates, Null/Outbox/SMTP notifiers.
using Test
const N = QciKanban.Notify
const Dm = QciKanban.Domain
const S = QciKanban.Stores
const C = QciKanban.Config

mkevent(kind; actor = "Alex", detail = "", email = "a@b.co") =
    Dm.NotificationEvent(; kind = kind, recipient_email = email, actor_name = actor,
                         issue_key = "QCI-1", issue_title = "Do the thing", detail = detail)

@testset "Notify: subject/body templates per kind" begin
    for kind in Dm.NOTIFICATION_KINDS
        ev = mkevent(kind)
        subj = N.render_subject(ev)
        body = N.render_body(ev)
        @test occursin("QCI-1", subj)
        @test occursin("Do the thing", subj)
        @test occursin("QCI-1", body)
    end
    @test occursin("assigned", N.render_subject(mkevent(:assigned)))
    @test occursin("Status changed", N.render_subject(mkevent(:status_changed)))
    @test occursin("New comment", N.render_subject(mkevent(:comment_added)))
    @test occursin("Due soon", N.render_subject(mkevent(:due_soon)))
    @test occursin("mentioned", N.render_subject(mkevent(:mentioned)))
    # actor fallback + detail branch
    @test occursin("Someone", N.render_body(mkevent(:assigned; actor = "")))
    @test occursin("Alex assigned", N.render_body(mkevent(:assigned)))
    @test occursin("changed the status", N.render_body(mkevent(:status_changed)))
    @test occursin("commented", N.render_body(mkevent(:comment_added)))
    @test occursin("due soon", N.render_body(mkevent(:due_soon)))
    @test occursin("mentioned you", N.render_body(mkevent(:mentioned)))
    @test occursin("extra info", N.render_body(mkevent(:assigned; detail = "extra info")))
end

@testset "S4: header injection stripped from key/title; recipient validated" begin
    # CR/LF and control chars in issue key/title must not survive into subject/body.
    ev = Dm.NotificationEvent(; kind = :assigned, recipient_email = "a@b.co",
                              actor_name = "Bad\r\nBcc: evil@x", issue_key = "QCI-1\r\nBcc: evil@x",
                              issue_title = "hi\nthere\ttab")
    subj = N.render_subject(ev)
    body = N.render_body(ev)
    @test !occursin('\r', subj) && !occursin('\n', subj) && !occursin('\t', subj)
    @test !occursin("\r\nBcc:", subj)
    @test !occursin("Bad\r\n", body)                 # actor sanitized in body lead
    @test occursin("QCI-1", subj)                     # legitimate text preserved
    @test N.sanitize_header("a\r\nb\x00c") == "abc"

    # SMTP delivery rejects a malformed/injected recipient
    ft = N.FakeTransport()
    enabled = N.SMTPNotifier(C.SmtpConfig(; enabled = true, from = "sys@qci.co"), ft)
    @test N.deliver!(enabled, "not-an-email", "s", "b") == false
    @test N.sent_count(ft) == 0
    @test N.deliver!(enabled, "ok@b.co", "s", "b") == true
    @test N.sent_count(ft) == 1
end

@testset "Notify: NullNotifier" begin
    nn = N.NullNotifier()
    @test N.notify!(nn, mkevent(:assigned)) === nothing
    @test N.deliver!(nn, "a@b.co", "s", "b") == true
end

@testset "Notify: FakeTransport + SMTPNotifier (config-gated)" begin
    ft = N.FakeTransport()
    @test N.sent_count(ft) == 0

    disabled = N.SMTPNotifier(C.SmtpConfig(; enabled = false, from = "sys@qci.co"), ft)
    @test N.deliver!(disabled, "a@b.co", "s", "b") == false   # gated off, no send
    @test N.sent_count(ft) == 0
    @test N.notify!(disabled, mkevent(:assigned)) == false

    enabled = N.SMTPNotifier(C.SmtpConfig(; enabled = true, from = "sys@qci.co"), ft)
    @test N.deliver!(enabled, "a@b.co", "subj", "body") == true
    @test N.sent_count(ft) == 1
    @test ft.sends[end].from == "sys@qci.co" && ft.sends[end].to == "a@b.co"
    @test N.notify!(enabled, mkevent(:assigned))
    @test N.sent_count(ft) == 2
    @test occursin("assigned", ft.sends[end].subject)
end

@testset "Notify: OutboxNotifier + flush_outbox!" begin
    bs = S.SQLiteBoardStore(":memory:")
    outbox = N.OutboxNotifier(bs)
    N.notify!(outbox, mkevent(:assigned; email = "one@b.co"))
    N.notify!(outbox, mkevent(:status_changed; email = "two@b.co"))
    pend = S.pending_outbox(bs)
    @test length(pend) == 2
    @test any(r -> r["recipient_email"] == "one@b.co", pend)

    # flush through FakeTransport marks rows sent
    ft = N.FakeTransport()
    smtp = N.SMTPNotifier(C.SmtpConfig(; enabled = true, from = "sys@qci.co"), ft)
    n = N.flush_outbox!(bs, smtp)
    @test n == 2
    @test N.sent_count(ft) == 2
    @test isempty(S.pending_outbox(bs))

    # flushing again drains nothing
    @test N.flush_outbox!(bs, smtp) == 0

    # NullNotifier still marks sent (deliver! true)
    N.notify!(outbox, mkevent(:comment_added; email = "three@b.co"))
    @test N.flush_outbox!(bs, N.NullNotifier()) == 1
    @test isempty(S.pending_outbox(bs))

    # disabled SMTP delivers false → rows NOT marked sent
    N.notify!(outbox, mkevent(:due_soon; email = "four@b.co"))
    disabled = N.SMTPNotifier(C.SmtpConfig(; enabled = false), N.FakeTransport())
    @test N.flush_outbox!(bs, disabled) == 0
    @test length(S.pending_outbox(bs)) == 1
end
