# ═══════════════════════════════════════════════════════════════════════
# auth/jwt.jl — HS256 JWT issue/verify, thin wrapper over JSONWebTokens.jl.
#
# issue with iat/exp claims; verify returns claims Dict or `nothing` for a
# bad signature, expired token, malformed token, or an alg=none attack.
# Part of `module Auth`.
# ═══════════════════════════════════════════════════════════════════════

import JSONWebTokens
using Dates

export issue_jwt, verify_jwt

"""
    issue_jwt(secret, claims; ttl_seconds, now=now(UTC)) -> String

Encode `claims` (a Dict) as an HS256 JWT, injecting `iat` and `exp`
(seconds since the Unix epoch). `ttl_seconds` sets `exp = iat + ttl`.
"""
function issue_jwt(secret::AbstractString, claims::AbstractDict;
                   ttl_seconds::Integer = 3600,
                   now::DateTime = Dates.now(UTC))::String
    iat = round(Int, Dates.datetime2unix(now))
    payload = Dict{String,Any}()
    for (k, v) in claims
        payload[String(k)] = v
    end
    payload["iat"] = iat
    payload["exp"] = iat + Int(ttl_seconds)
    JSONWebTokens.encode(JSONWebTokens.HS256(String(secret)), payload)
end

"""
    verify_jwt(token, secret; now=now(UTC)) -> Dict | nothing

Verify signature + expiry. Returns the claims Dict on success, `nothing` for:
bad signature, missing/non-numeric `exp`, expired (`exp <= now`), malformed
token, or `alg=none` (JSONWebTokens rejects the alg mismatch / empty signature
for us). A token with no `exp` claim is rejected — every token must expire.
"""
function verify_jwt(token::AbstractString, secret::AbstractString;
                    now::DateTime = Dates.now(UTC))
    claims = try
        JSONWebTokens.decode(JSONWebTokens.HS256(String(secret)), String(token))
    catch
        return nothing
    end
    claims isa AbstractDict || return nothing
    exp = get(claims, "exp", nothing)
    exp === nothing && return nothing            # every token must carry an expiry
    now_unix = Dates.datetime2unix(now)
    (exp isa Number && now_unix < exp) || return nothing
    claims
end
