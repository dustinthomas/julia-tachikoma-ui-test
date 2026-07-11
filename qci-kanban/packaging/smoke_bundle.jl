# packaging/smoke_bundle.jl — post-build binary smoke.
#
# After create_app, run the relocatable binary with --smoke and exit with its
# code. Does not require JULIA_PROJECT or a source tree load path.
#
#   julia packaging/smoke_bundle.jl
#   julia packaging/smoke_bundle.jl /path/to/dist/qci-kanban-linux

const ROOT = abspath(dirname(@__DIR__))  # qci-kanban/
const DEFAULT_OUT = joinpath(ROOT, "dist", "qci-kanban-linux")

const OUT = length(ARGS) >= 1 ? abspath(ARGS[1]) : DEFAULT_OUT
const BIN = joinpath(OUT, "bin", "qci-kanban")

if !isfile(BIN)
    println(stderr, "smoke_bundle: missing binary at $BIN")
    println(stderr, "Build first: julia --project=packaging packaging/build_linux_app.jl")
    exit(1)
end

if !Sys.isexecutable(BIN)
    println(stderr, "smoke_bundle: binary exists but is not executable: $BIN")
    println(stderr, "Re-run create_app or chmod +x the binary, then retry.")
    exit(1)
end

@info "smoke_bundle: running" BIN
# ignorestatus so we can forward the binary exit code without a throw
p = run(ignorestatus(`$BIN --smoke`))
# exitcode is nothing when the process dies on a signal — treat as failure
exit(something(p.exitcode, 1))
