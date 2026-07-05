# ═══════════════════════════════════════════════════════════════════════
# auth/password.jl — PBKDF2-HMAC-SHA256 password hashing (SHA stdlib only).
#
# 16-byte random salt, >= 100_000 iterations, constant-time verification.
# Part of `module Auth`.
# ═══════════════════════════════════════════════════════════════════════

import SHA
using Random

export PasswordHash, hash_password, verify_password, constant_time_eq

const DEFAULT_ITERATIONS = 100_000
const MIN_ITERATIONS = 100_000
const MAX_ITERATIONS = 10_000_000   # sane ceiling: rejects login-DoS via huge stored counts
const SALT_BYTES = 16
const DK_BYTES = 32   # one SHA-256 block

struct PasswordHash
    hash_hex::String
    salt_hex::String
    iterations::Int
end

# 32-bit big-endian block index for PBKDF2 block 1.
_int_be(i::Integer) = UInt8[(i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff]

"""
    pbkdf2_hmac_sha256(password, salt, iterations, dklen=32) -> Vector{UInt8}

Derive a key with PBKDF2 (PRF = HMAC-SHA256). We only ever need one 32-byte
block, so the block loop is written for `dklen <= 32` (single block, index 1).
"""
function pbkdf2_hmac_sha256(password::Vector{UInt8}, salt::Vector{UInt8},
                            iterations::Int, dklen::Int = DK_BYTES)::Vector{UInt8}
    iterations >= 1 || throw(ArgumentError("iterations must be >= 1"))
    u = SHA.hmac_sha2_256(password, vcat(salt, _int_be(1)))
    t = copy(u)
    for _ in 2:iterations
        u = SHA.hmac_sha2_256(password, u)
        @inbounds for j in eachindex(t)
            t[j] ⊻= u[j]
        end
    end
    t[1:dklen]
end

"""
    hash_password(password; iterations=100_000, salt=random) -> PasswordHash

Hash `password` with a fresh 16-byte random salt (or a supplied one, for
deterministic tests). Enforces `iterations >= 100_000`.
"""
function hash_password(password::AbstractString;
                       iterations::Int = DEFAULT_ITERATIONS,
                       salt::Vector{UInt8} = rand(RandomDevice(), UInt8, SALT_BYTES))::PasswordHash
    iterations >= 100_000 || throw(ArgumentError("iterations must be >= 100_000"))
    pw = Vector{UInt8}(codeunits(password))
    dk = pbkdf2_hmac_sha256(pw, salt, iterations)
    PasswordHash(bytes2hex(dk), bytes2hex(salt), iterations)
end

"""
    constant_time_eq(a, b) -> Bool

Compare two byte vectors without early exit on the first differing byte.
"""
function constant_time_eq(a::Vector{UInt8}, b::Vector{UInt8})::Bool
    length(a) == length(b) || return false
    diff = UInt8(0)
    @inbounds for i in eachindex(a)
        diff |= a[i] ⊻ b[i]
    end
    diff == 0x00
end

"""
    verify_password(password, ph::PasswordHash) -> Bool

Re-derive with the stored salt/iterations and compare in constant time. The
stored `iterations` is validated against `[MIN_ITERATIONS, MAX_ITERATIONS]`
before use: a value below the floor (downgrade) or above the ceiling
(login-DoS via an attacker-planted huge count) is rejected outright.
"""
function verify_password(password::AbstractString, ph::PasswordHash)::Bool
    (MIN_ITERATIONS <= ph.iterations <= MAX_ITERATIONS) || return false
    salt = hex2bytes(ph.salt_hex)
    pw = Vector{UInt8}(codeunits(password))
    dk = pbkdf2_hmac_sha256(pw, salt, ph.iterations)
    constant_time_eq(dk, hex2bytes(ph.hash_hex))
end

verify_password(password::AbstractString, hash_hex::AbstractString,
                salt_hex::AbstractString, iterations::Integer)::Bool =
    verify_password(password, PasswordHash(String(hash_hex), String(salt_hex), Int(iterations)))
