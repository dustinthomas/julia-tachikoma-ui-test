# Unit tests for QciKanban.Passwords + QciKanban.Auth (jwt + session).
using Test
using Dates
import Base64
import JSONWebTokens
const P = QciKanban.Passwords
const A = QciKanban.Auth
const S = QciKanban.Stores

@testset "Passwords: PBKDF2-HMAC-SHA256" begin
    ph = P.hash_password("correct horse")
    @test ph isa P.PasswordHash
    @test ph.iterations >= 100_000
    @test ph.hash_hex != "correct horse"
    @test length(hex2bytes(ph.salt_hex)) == 16
    @test length(hex2bytes(ph.hash_hex)) == 32
    @test P.verify_password("correct horse", ph)
    @test !P.verify_password("wrong", ph)

    # different salt → different hash for identical password
    ph2 = P.hash_password("correct horse")
    @test ph.salt_hex != ph2.salt_hex
    @test ph.hash_hex != ph2.hash_hex

    # deterministic with a fixed salt
    salt = fill(0x01, 16)
    a = P.hash_password("pw"; salt = salt)
    b = P.hash_password("pw"; salt = salt)
    @test a.hash_hex == b.hash_hex

    # hex-string overload
    @test P.verify_password("pw", a.hash_hex, a.salt_hex, a.iterations)

    @test_throws ArgumentError P.hash_password("x"; iterations = 1000)
    @test_throws ArgumentError P.pbkdf2_hmac_sha256(Vector{UInt8}("p"), Vector{UInt8}("s"), 0)

    @test P.constant_time_eq(UInt8[1, 2, 3], UInt8[1, 2, 3])
    @test !P.constant_time_eq(UInt8[1, 2, 3], UInt8[1, 2, 4])
    @test !P.constant_time_eq(UInt8[1, 2], UInt8[1, 2, 3])
end

@testset "S5: verify_password rejects out-of-band stored iterations" begin
    ph = P.hash_password("pw"; salt = fill(0x02, 16))   # legit: 100_000 iterations
    @test P.verify_password("pw", ph)
    # below the floor (downgrade attempt) → rejected without trusting the count
    low = P.PasswordHash(ph.hash_hex, ph.salt_hex, 50_000)
    @test !P.verify_password("pw", low)
    # above the ceiling (login-DoS via a huge planted count) → rejected
    high = P.PasswordHash(ph.hash_hex, ph.salt_hex, 100_000_000)
    @test !P.verify_password("pw", high)
end

@testset "S8: JWT with no exp is rejected (every token must expire)" begin
    secret = "topsecret"
    noexp = JSONWebTokens.encode(JSONWebTokens.HS256(secret), Dict("sub" => "u"))  # no exp claim
    @test A.verify_jwt(noexp, secret) === nothing
    withexp = A.issue_jwt(secret, Dict("sub" => "u"); ttl_seconds = 3600)
    @test A.verify_jwt(withexp, secret) !== nothing
end

@testset "S6: token file written atomically 0600; symlink rejected on read" begin
    mktempdir() do dir
        p = joinpath(dir, "sub", "tok.jwt")
        A.save_token(p, "abc123")
        @test isfile(p)
        @test (filemode(p) & 0o777) == 0o600
        @test A.load_token(p) == "abc123"
        link = joinpath(dir, "link.jwt")
        symlink(p, link)
        @test_throws ArgumentError A.load_token(link)     # never follow a symlink
    end
end

@testset "S1/S2: secure restore rechecks store; deactivation + logout revoke tokens" begin
    mktempdir() do dir
        secret = "session-secret-abcdefghijklmnop"
        tok = joinpath(dir, "s.jwt")
        us = S.SQLiteUserStore(":memory:")
        u = S.create_user!(us; email = "a@b.co", name = "Al", password = "hunter2pw")

        sess = A.Session(; secret = secret, token_path = tok, ttl_seconds = 3600)
        A.login!(sess, us, "a@b.co", "hunter2pw")
        token = sess.token
        @test token !== nothing

        # S1: secure restore (with userstore) rebuilds from the DB row
        s2 = A.Session(; secret = secret, token_path = tok, ttl_seconds = 3600)
        @test A.restore(s2, token, us)
        @test s2.current_user.id == u.id && s2.current_user.active
        # restore_from_file! also forwards the userstore
        s2b = A.Session(; secret = secret, token_path = tok, ttl_seconds = 3600)
        @test A.restore_from_file!(s2b, us)
        @test s2b.current_user.id == u.id

        # unknown sub (empty store) → rejected
        @test !A.restore(A.Session(; secret = secret, token_path = tok), token, S.SQLiteUserStore(":memory:"))

        # S1: deactivated user cannot restore even with a valid, unexpired token
        S.deactivate_user!(us, u.id)
        s3 = A.Session(; secret = secret, token_path = tok, ttl_seconds = 3600)
        @test !A.restore(s3, token, us)
        @test s3.current_user === nothing
    end

    # S2: logout bumps token_version, orphaning outstanding tokens
    mktempdir() do dir
        secret = "session-secret-abcdefghijklmnop"
        tok = joinpath(dir, "s2.jwt")
        us = S.SQLiteUserStore(":memory:")
        u = S.create_user!(us; email = "b@b.co", name = "Bo", password = "hunter2pw")
        sess = A.Session(; secret = secret, token_path = tok, ttl_seconds = 3600)
        A.login!(sess, us, "b@b.co", "hunter2pw")
        token = sess.token
        @test A.restore(A.Session(; secret = secret, token_path = tok), token, us)   # valid pre-logout
        A.logout!(sess, us)                                                          # bumps token_version
        @test S.get_token_version(us, u.id) == 1
        @test !A.restore(A.Session(; secret = secret, token_path = tok), token, us)  # orphaned
    end
end

@testset "JWT: HS256 issue/verify" begin
    secret = "topsecret"
    tok = A.issue_jwt(secret, Dict("sub" => "u1", "name" => "Alex"); ttl_seconds = 3600)
    @test length(split(tok, ".")) == 3
    claims = A.verify_jwt(tok, secret)
    @test claims !== nothing
    @test claims["sub"] == "u1" && claims["name"] == "Alex"
    @test haskey(claims, "iat") && haskey(claims, "exp")

    # bad signature (wrong secret)
    @test A.verify_jwt(tok, "othersecret") === nothing
    # tampered payload
    parts = split(tok, ".")
    tampered = parts[1] * "." * parts[2] * "x" * "." * parts[3]
    @test A.verify_jwt(tampered, secret) === nothing
    # malformed
    @test A.verify_jwt("not-a-jwt", secret) === nothing
    @test A.verify_jwt("only.two", secret) === nothing

    # expired: issue then verify at a later time
    tok2 = A.issue_jwt(secret, Dict("sub" => "u1"); ttl_seconds = 60,
                       now = DateTime(2020, 1, 1, 0, 0, 0))
    @test A.verify_jwt(tok2, secret; now = DateTime(2020, 1, 1, 0, 0, 0)) !== nothing
    @test A.verify_jwt(tok2, secret; now = DateTime(2020, 1, 1, 1, 0, 0)) === nothing

    # alg=none attack — forged header alg:none must be rejected
    b64(x) = rstrip(Base64.base64encode(x), '=') |> s -> replace(s, "+" => "-", "/" => "_")
    none_tok = b64("""{"alg":"none","typ":"JWT"}""") * "." * b64("""{"sub":"attacker"}""") * "."
    @test A.verify_jwt(none_tok, secret) === nothing
    none_tok_nosig = b64("""{"alg":"none","typ":"JWT"}""") * "." * b64("""{"sub":"attacker"}""")
    @test A.verify_jwt(none_tok_nosig, secret) === nothing
end

@testset "Session: login / restore / logout" begin
    mktempdir() do dir
        tokpath = joinpath(dir, "sub", "session.jwt")
        secret = "sessionsecret"
        us = S.SQLiteUserStore(":memory:")
        S.create_user!(us; email = "a@b.co", name = "Alex", password = "hunter2pw")

        sess = A.Session(; secret = secret, token_path = tokpath, ttl_seconds = 3600)
        @test sess.current_user === nothing

        # wrong password → nothing, no file, session untouched
        @test A.login!(sess, us, "a@b.co", "wrong") === nothing
        @test sess.current_user === nothing
        @test !isfile(tokpath)

        # correct → user, token persisted 0600
        u = A.login!(sess, us, "a@b.co", "hunter2pw")
        @test u !== nothing && sess.current_user.name == "Alex"
        @test sess.token !== nothing
        @test isfile(tokpath)
        @test (filemode(tokpath) & 0o777) == 0o600
        @test A.load_token(tokpath) == sess.token

        # restore from a fresh session using the persisted token
        sess2 = A.Session(; secret = secret, token_path = tokpath, ttl_seconds = 3600)
        @test A.restore_from_file!(sess2)
        @test sess2.current_user.id == u.id
        @test sess2.current_user.name == "Alex"

        # restore with a bad token clears
        @test !A.restore(sess2, "garbage.token.here")
        @test sess2.current_user === nothing

        # restore_from_file! with no file → false
        sess3 = A.Session(; secret = secret, token_path = joinpath(dir, "none.jwt"))
        @test !A.restore_from_file!(sess3)

        # logout deletes file + clears
        A.logout!(sess)
        @test sess.current_user === nothing && sess.token === nothing
        @test !isfile(tokpath)
        A.logout!(sess)  # idempotent when file already gone
        @test !isfile(tokpath)

        # save_token / load_token helpers directly
        p2 = joinpath(dir, "manual.jwt")
        A.save_token(p2, "abc")
        @test A.load_token(p2) == "abc"
        @test A.load_token(joinpath(dir, "missing.jwt")) === nothing
    end
end
