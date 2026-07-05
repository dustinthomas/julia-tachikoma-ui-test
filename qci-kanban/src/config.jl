# ═══════════════════════════════════════════════════════════════════════
# config.jl — AppConfig from TOML (stdlib) + ENV overrides.
#
# Wrapped by `module Config` in QciKanban.jl. All filesystem paths are
# injectable so tests never touch ~/.qci-kanban. The JWT secret is generated
# once and persisted with 0600 perms on first use.
# ═══════════════════════════════════════════════════════════════════════

using TOML
using Random
using Dates

export AppConfig, SmtpConfig, PostgresConfig
export load_config, ensure_jwt_secret!

# ── Sub-configs ─────────────────────────────────────────────────────────
Base.@kwdef mutable struct SmtpConfig
    enabled::Bool = false
    host::String = "localhost"
    port::Int = 25
    user::String = ""
    password::String = ""
    from::String = "qci-kanban@localhost"
end

Base.@kwdef mutable struct PostgresConfig
    host::String = "localhost"
    port::Int = 5432
    dbname::String = "qci_kanban"
    user::String = "postgres"
    password::String = ""
end

# ── Top-level config ────────────────────────────────────────────────────
Base.@kwdef mutable struct AppConfig
    backend::Symbol = :sqlite                    # :sqlite | :remote
    users_db_path::String = joinpath(homedir(), ".qci-kanban", "users.db")
    board_db_path::String = joinpath(homedir(), ".qci-kanban", "board.db")
    jwt_secret::Union{String,Nothing} = nothing
    jwt_secret_path::String = joinpath(homedir(), ".qci-kanban", "jwt.secret")
    session_token_path::String = joinpath(homedir(), ".qci-kanban", "session.jwt")
    token_ttl_seconds::Int = 60 * 60 * 24 * 7    # one week
    smtp::SmtpConfig = SmtpConfig()
    postgres::PostgresConfig = PostgresConfig()
end

# ── TOML loading + ENV overrides ─────────────────────────────────────────
_as_bool(v)::Bool = v isa Bool ? v : lowercase(String(v)) in ("1", "true", "yes", "on")
_as_int(v)::Int = v isa Integer ? Int(v) : parse(Int, String(v))

const MIN_JWT_SECRET_LEN = 32

"Reject a configured JWT secret that is too short to be a safe HS256 key."
function _validate_jwt_secret(secret::AbstractString)
    length(secret) >= MIN_JWT_SECRET_LEN ||
        throw(ArgumentError("configured JWT secret must be at least $(MIN_JWT_SECRET_LEN) characters"))
    secret
end

"""
    _atomic_write_0600(path, contents)

Write `contents` to `path` atomically at mode 0600: a temp file in the *same*
directory is created, written, chmod-ed 0600 and `rename`d over `path`, so the
target never exists with wider perms (closes the chmod-after-write TOCTOU).
"""
function _atomic_write_0600(path::AbstractString, contents::AbstractString)
    dir = dirname(path)
    isempty(dir) || isdir(dir) || mkpath(dir)
    tmp, io = mktemp(isempty(dir) ? pwd() : dir)
    write(io, contents)
    close(io)
    chmod(tmp, 0o600)          # temp is 0600 before it ever appears at `path`
    mv(tmp, path; force = true)
    path
end

"Read a secret/token file, rejecting a symlinked path (no symlink following)."
function _read_no_symlink(path::AbstractString)::String
    islink(path) && throw(ArgumentError("refusing to read symlinked secret file: $path"))
    strip(read(path, String))
end

"""
    load_config(path=nothing; env=ENV) -> AppConfig

Build an `AppConfig` from an optional TOML file, then apply ENV overrides.
Missing file → defaults only. ENV always wins over the file.

Recognized ENV keys: `QCI_BACKEND`, `QCI_USERS_DB`, `QCI_BOARD_DB`,
`QCI_JWT_SECRET`, `QCI_JWT_SECRET_PATH`, `QCI_SESSION_TOKEN_PATH`,
`QCI_TOKEN_TTL`, `QCI_SMTP_ENABLED`, `QCI_SMTP_HOST`, `QCI_SMTP_PORT`,
`QCI_SMTP_USER`, `QCI_SMTP_PASSWORD`, `QCI_SMTP_FROM`, `QCI_PG_HOST`,
`QCI_PG_PORT`, `QCI_PG_DBNAME`, `QCI_PG_USER`, `QCI_PG_PASSWORD`.
"""
function load_config(path::Union{AbstractString,Nothing} = nothing; env = ENV)::AppConfig
    cfg = AppConfig()
    if path !== nothing && isfile(path)
        t = TOML.parsefile(path)
        haskey(t, "backend") && (cfg.backend = Symbol(t["backend"]))
        haskey(t, "users_db_path") && (cfg.users_db_path = String(t["users_db_path"]))
        haskey(t, "board_db_path") && (cfg.board_db_path = String(t["board_db_path"]))
        haskey(t, "jwt_secret") && (cfg.jwt_secret = String(t["jwt_secret"]))
        haskey(t, "jwt_secret_path") && (cfg.jwt_secret_path = String(t["jwt_secret_path"]))
        haskey(t, "session_token_path") && (cfg.session_token_path = String(t["session_token_path"]))
        haskey(t, "token_ttl_seconds") && (cfg.token_ttl_seconds = _as_int(t["token_ttl_seconds"]))
        if haskey(t, "smtp")
            s = t["smtp"]
            haskey(s, "enabled") && (cfg.smtp.enabled = _as_bool(s["enabled"]))
            haskey(s, "host") && (cfg.smtp.host = String(s["host"]))
            haskey(s, "port") && (cfg.smtp.port = _as_int(s["port"]))
            haskey(s, "user") && (cfg.smtp.user = String(s["user"]))
            haskey(s, "password") && (cfg.smtp.password = String(s["password"]))
            haskey(s, "from") && (cfg.smtp.from = String(s["from"]))
        end
        if haskey(t, "postgres")
            p = t["postgres"]
            haskey(p, "host") && (cfg.postgres.host = String(p["host"]))
            haskey(p, "port") && (cfg.postgres.port = _as_int(p["port"]))
            haskey(p, "dbname") && (cfg.postgres.dbname = String(p["dbname"]))
            haskey(p, "user") && (cfg.postgres.user = String(p["user"]))
            haskey(p, "password") && (cfg.postgres.password = String(p["password"]))
        end
    end

    # ENV overrides (always win)
    haskey(env, "QCI_BACKEND") && (cfg.backend = Symbol(env["QCI_BACKEND"]))
    haskey(env, "QCI_USERS_DB") && (cfg.users_db_path = String(env["QCI_USERS_DB"]))
    haskey(env, "QCI_BOARD_DB") && (cfg.board_db_path = String(env["QCI_BOARD_DB"]))
    haskey(env, "QCI_JWT_SECRET") && (cfg.jwt_secret = String(env["QCI_JWT_SECRET"]))
    haskey(env, "QCI_JWT_SECRET_PATH") && (cfg.jwt_secret_path = String(env["QCI_JWT_SECRET_PATH"]))
    haskey(env, "QCI_SESSION_TOKEN_PATH") && (cfg.session_token_path = String(env["QCI_SESSION_TOKEN_PATH"]))
    haskey(env, "QCI_TOKEN_TTL") && (cfg.token_ttl_seconds = _as_int(env["QCI_TOKEN_TTL"]))
    haskey(env, "QCI_SMTP_ENABLED") && (cfg.smtp.enabled = _as_bool(env["QCI_SMTP_ENABLED"]))
    haskey(env, "QCI_SMTP_HOST") && (cfg.smtp.host = String(env["QCI_SMTP_HOST"]))
    haskey(env, "QCI_SMTP_PORT") && (cfg.smtp.port = _as_int(env["QCI_SMTP_PORT"]))
    haskey(env, "QCI_SMTP_USER") && (cfg.smtp.user = String(env["QCI_SMTP_USER"]))
    haskey(env, "QCI_SMTP_PASSWORD") && (cfg.smtp.password = String(env["QCI_SMTP_PASSWORD"]))
    haskey(env, "QCI_SMTP_FROM") && (cfg.smtp.from = String(env["QCI_SMTP_FROM"]))
    haskey(env, "QCI_PG_HOST") && (cfg.postgres.host = String(env["QCI_PG_HOST"]))
    haskey(env, "QCI_PG_PORT") && (cfg.postgres.port = _as_int(env["QCI_PG_PORT"]))
    haskey(env, "QCI_PG_DBNAME") && (cfg.postgres.dbname = String(env["QCI_PG_DBNAME"]))
    haskey(env, "QCI_PG_USER") && (cfg.postgres.user = String(env["QCI_PG_USER"]))
    haskey(env, "QCI_PG_PASSWORD") && (cfg.postgres.password = String(env["QCI_PG_PASSWORD"]))

    # S9: a JWT secret supplied via TOML/ENV must be long enough to be safe.
    cfg.jwt_secret === nothing || _validate_jwt_secret(cfg.jwt_secret)

    cfg
end

"""
    ensure_jwt_secret!(cfg) -> String

Return the JWT secret, generating and persisting a fresh 32-byte random hex
secret to `cfg.jwt_secret_path` (0600) if none is configured. If the file
already exists it is read back rather than regenerated.
"""
function ensure_jwt_secret!(cfg::AppConfig)::String
    cfg.jwt_secret !== nothing && return cfg.jwt_secret
    if isfile(cfg.jwt_secret_path) || islink(cfg.jwt_secret_path)
        cfg.jwt_secret = _read_no_symlink(cfg.jwt_secret_path)   # rejects symlinks
        return cfg.jwt_secret
    end
    secret = bytes2hex(rand(RandomDevice(), UInt8, 32))
    _atomic_write_0600(cfg.jwt_secret_path, secret)              # atomic 0600 write
    cfg.jwt_secret = secret
    secret
end
