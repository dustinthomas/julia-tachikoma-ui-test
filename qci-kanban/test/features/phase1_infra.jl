# ═══════════════════════════════════════════════════════════════════════
# BDD acceptance specs for Phase 1 — Core infrastructure.
# Given/When/Then nested testsets per PHASES.md "Acceptance (BDD)".
# ═══════════════════════════════════════════════════════════════════════
using Test
using Dates
using Random
import Base64
# Supposition lives in the test target: available under `Pkg.test()`, but not
# on the load path for a plain `julia --project=. test/runtests.jl`. Use it for
# the property test when present; otherwise run a deterministic randomized
# fallback so both invocations stay green and the invariant is still exercised.
const HAS_SUPPOSITION = try
    @eval import Supposition
    true
catch
    false
end
const S = QciKanban.Stores
const A = QciKanban.Auth
const P = QciKanban.Passwords
const N = QciKanban.Notify
const Dm = QciKanban.Domain

@testset "FEATURE: Phase 1 core infrastructure (BDD acceptance)" begin

    @testset "Auth: create + authenticate a user" begin
        @testset "Given a fresh user store" begin
            us = S.SQLiteUserStore(":memory:")
            @testset "When a user is created and authenticated with the right password" begin
                u = S.create_user!(us; email = "dev@qci.co", name = "Dev", password = "s3cretpw!")
                @testset "Then the matching user is returned" begin
                    got = S.authenticate(us, "dev@qci.co", "s3cretpw!")
                    @test got !== nothing && got.id == u.id
                end
                @testset "Then wrong password or unknown email yields nothing" begin
                    @test S.authenticate(us, "dev@qci.co", "nope") === nothing
                    @test S.authenticate(us, "ghost@qci.co", "s3cretpw!") === nothing
                end
            end
            @testset "And the stored hash is not the password and differs per salt" begin
                a = P.hash_password("samepw")
                b = P.hash_password("samepw")
                @test a.hash_hex != "samepw"
                @test a.salt_hex != b.salt_hex
                @test a.hash_hex != b.hash_hex
            end
        end
    end

    @testset "JWT: round-trip and rejection of tampering" begin
        secret = "acceptance-secret"
        @testset "Given a token issued over some claims" begin
            tok = A.issue_jwt(secret, Dict("sub" => "u1", "name" => "Dev"); ttl_seconds = 3600)
            @testset "When verified with the right secret Then claims round-trip" begin
                c = A.verify_jwt(tok, secret)
                @test c !== nothing && c["sub"] == "u1"
            end
            @testset "Then tampered / bad-sig / alg=none / expired all verify to nothing" begin
                parts = split(tok, ".")
                @test A.verify_jwt(parts[1] * "." * parts[2] * "AA." * parts[3], secret) === nothing
                @test A.verify_jwt(tok, "wrong-secret") === nothing
                b64(x) = replace(rstrip(Base64.base64encode(x), '='), "+" => "-", "/" => "_")
                none = b64("""{"alg":"none","typ":"JWT"}""") * "." * b64("""{"sub":"x"}""") * "."
                @test A.verify_jwt(none, secret) === nothing
                exp = A.issue_jwt(secret, Dict("sub" => "u1"); ttl_seconds = 1,
                                  now = DateTime(2000, 1, 1))
                @test A.verify_jwt(exp, secret; now = DateTime(2001, 1, 1)) === nothing
            end
        end
    end

    @testset "Notify: status change → activity + outbox → flush marks sent" begin
        @testset "Given an issue and an OutboxNotifier" begin
            bs = S.SQLiteBoardStore(":memory:")
            outbox = N.OutboxNotifier(bs)
            iss = S.create_issue!(bs; title = "Move me", status = "Backlog")
            @testset "When the issue is moved between statuses" begin
                S.move_issue!(bs, iss.id; status = "In Progress")
                S.log_activity!(bs; issue_id = iss.id, actor_id = "u1", kind = :status_changed,
                                detail = "Backlog → In Progress")
                N.notify!(outbox, Dm.NotificationEvent(; kind = :status_changed,
                          recipient_email = "watcher@qci.co", actor_name = "Dev",
                          issue_key = iss.key, issue_title = iss.title))
                @testset "Then activity is logged and an outbox row exists" begin
                    acts = S.list_activity(bs, iss.id)
                    @test any(a -> a.kind == :status_changed, acts)
                    @test length(S.pending_outbox(bs)) == 1
                    @test S.get_issue(bs, iss.id).status == "In Progress"
                end
                @testset "And flushing through a FakeTransport marks it sent" begin
                    ft = N.FakeTransport()
                    smtp = N.SMTPNotifier(QciKanban.Config.SmtpConfig(; enabled = true), ft)
                    @test N.flush_outbox!(bs, smtp) == 1
                    @test N.sent_count(ft) == 1
                    @test isempty(S.pending_outbox(bs))
                end
            end
        end
    end

    @testset "PROPERTY: rank_issue!/move_issue! keep positions dense + collision-free" begin
        statuses = collect(Dm.STATUSES)

        # Pure invariant checker reused by both the Supposition and fallback paths.
        function _apply_and_check(ops)
            bs = S.SQLiteBoardStore(":memory:")
            ids = [S.create_issue!(bs; title = "I$i", status = "Backlog").id for i in 1:5]
            for (si, pos, which, op) in ops
                id = ids[which]
                if op === :rank
                    S.rank_issue!(bs, id; position = pos)
                else
                    S.move_issue!(bs, id; status = statuses[si], position = pos)
                end
            end
            for st in statuses
                iss = S.list_issues(bs; status = st)
                sort([x.position for x in iss]) == collect(0:length(iss) - 1) || return false
            end
            length(S.list_issues(bs)) == 5
        end

        if HAS_SUPPOSITION
            @eval using Supposition
            @eval begin
                opgen = Supposition.@composed (
                    si = Supposition.Data.Integers(1, length($statuses)),
                    pos = Supposition.Data.Integers(0, 12),
                    which = Supposition.Data.Integers(1, 5),
                    op = Supposition.Data.SampledFrom((:move, :rank))) -> (si, pos, which, op)
                opsgen = Supposition.Data.Vectors(opgen; min_size = 0, max_size = 25)
                Supposition.@check function positions_stay_dense(ops = opsgen)
                    $(_apply_and_check)(ops)
                end
            end
        else
            @testset "deterministic randomized fallback (Supposition unavailable)" begin
                rng = Random.MersenneTwister(0xC0FFEE)
                for _ in 1:400
                    n = rand(rng, 0:25)
                    ops = [(rand(rng, 1:length(statuses)), rand(rng, 0:12),
                            rand(rng, 1:5), rand(rng, (:move, :rank))) for _ in 1:n]
                    @test _apply_and_check(ops)
                end
            end
        end
    end
end
