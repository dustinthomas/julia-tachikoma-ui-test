# ═══════════════════════════════════════════════════════════════════════
# auth/session.jl — login / restore / logout + token file persistence.
#
# Token file path is injectable (never ~/.qci-kanban in tests) and written
# with 0600 perms. Part of `module Auth`.
# ═══════════════════════════════════════════════════════════════════════

using Dates

export Session, login!, restore, restore_from_file!, logout!, save_token, load_token

mutable struct Session
    secret::String
    token_path::String
    ttl_seconds::Int
    current_user::Union{User,Nothing}
    token::Union{String,Nothing}
end
Session(; secret::AbstractString, token_path::AbstractString,
        ttl_seconds::Integer = 3600) =
    Session(String(secret), String(token_path), Int(ttl_seconds), nothing, nothing)

"""
    save_token(path, token)

Persist a token to `path` atomically at 0600 (temp-in-same-dir + rename), so the
file never exists with wider perms. Creates the parent dir if needed.
"""
save_token(path::AbstractString, token::AbstractString) =
    Config._atomic_write_0600(path, token)

"""
    load_token(path) -> String | nothing

Read a persisted token, or `nothing` if the file is absent. A symlinked token
path is rejected (never followed) to defeat a symlink-swap attack.
"""
function load_token(path::AbstractString)
    islink(path) && throw(ArgumentError("refusing to read symlinked token file: $path"))
    isfile(path) ? strip(read(path, String)) : nothing
end

"""
    login!(sess, userstore, email, password) -> User | nothing

Authenticate against `userstore`; on success issue a JWT (`sub`/`name`/`email`
claims), persist it (0600), populate the session, and return the User.
Bad credentials leave the session untouched and return `nothing`.
"""
function login!(sess::Session, userstore, email::AbstractString, password::AbstractString)
    user = authenticate(userstore, email, password)
    user === nothing && return nothing
    token = issue_jwt(sess.secret,
                      Dict("sub" => user.id, "name" => user.name, "email" => user.email,
                           "tv" => get_token_version(userstore, user.id));
                      ttl_seconds = sess.ttl_seconds)
    sess.current_user = user
    sess.token = token
    save_token(sess.token_path, token)
    user
end

"""
    restore(sess, token, userstore=nothing) -> Bool

Verify `token` against the session secret. When a `userstore` is supplied (the
secure path — callers SHOULD always pass it), the user is loaded from the store
by the `sub` claim and the session is rebuilt **from the DB row**, not the
claims: the restore is rejected (session cleared, `false`) if

  * the signature/expiry is invalid,
  * no user with that `sub` exists,
  * the user's `active` flag is `false` (deactivated user cannot regain access),
  * the token's `tv` (token-version) claim does not match the user's current
    `token_version` (a logout/deactivate bumps it, orphaning outstanding tokens).

When `userstore === nothing` the legacy claims-only rebuild is used (kept for
backward compatibility; not safe against deactivation — see the UI-wave note).
"""
function restore(sess::Session, token::AbstractString, userstore = nothing)::Bool
    claims = verify_jwt(token, sess.secret)
    if claims === nothing
        sess.current_user = nothing
        sess.token = nothing
        return false
    end
    if userstore === nothing
        # Legacy path: rebuild from claims (active assumed true).
        sess.token = String(token)
        sess.current_user = User(; id = get(claims, "sub", ""),
                                 email = get(claims, "email", "unknown@unknown.invalid"),
                                 name = get(claims, "name", "unknown"))
        return true
    end
    sub = String(get(claims, "sub", ""))
    user = get_user(userstore, sub)
    if user === nothing || !user.active ||
       Int(get(claims, "tv", 0)) != get_token_version(userstore, sub)
        sess.current_user = nothing
        sess.token = nothing
        return false
    end
    sess.token = String(token)
    sess.current_user = user            # authoritative DB row, not the claims
    true
end

"""
    restore_from_file!(sess, userstore=nothing) -> Bool

Load the persisted token (if any) and `restore` from it, forwarding `userstore`
so the secure DB-backed re-check applies.
"""
function restore_from_file!(sess::Session, userstore = nothing)::Bool
    token = load_token(sess.token_path)
    token === nothing && return false
    restore(sess, token, userstore)
end

"""
    logout!(sess, userstore=nothing)

Clear the session and delete the persisted token file. When a `userstore` is
supplied, the current user's `token_version` is bumped first so every
outstanding token for that user is immediately orphaned (server-side
revocation, not just local file deletion).
"""
function logout!(sess::Session, userstore = nothing)
    if userstore !== nothing && sess.current_user !== nothing
        bump_token_version!(userstore, sess.current_user.id)
    end
    sess.current_user = nothing
    sess.token = nothing
    isfile(sess.token_path) && rm(sess.token_path; force = true)
    sess
end
