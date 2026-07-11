# packaging/build_linux_app.jl — PackageCompiler create_app driver (Linux).
#
# Run from qci-kanban/:
#   julia --project=. -e 'using Pkg; Pkg.instantiate()'          # Step 0
#   julia --project=packaging -e 'using Pkg; Pkg.instantiate()'  # Step 1
#   julia --project=packaging packaging/build_linux_app.jl       # Step 2
#
# Optional env:
#   QCI_CPU_TARGET — Stage 1 / same-machine: native (default).
#                    Redistribution attempt: generic (broader x86-64; rebuild required).
#                    See packaging/relocatable_smoke.md for cpu_target + off-machine smoke.
#   QCI_FILTER_STDLIBS=1 → filter_stdlibs=true (size experiment; NOT Stage 1 default)
# PackageCompiler is NOT a product dependency — only this packaging/ project.

using PackageCompiler

const ROOT = abspath(dirname(@__DIR__))  # qci-kanban/
const OUT = joinpath(ROOT, "dist", "qci-kanban-linux")
const PRE = joinpath(@__DIR__, "precompile_app.jl")
const MANIFEST = joinpath(ROOT, "Manifest.toml")
const CPU_TARGET = get(ENV, "QCI_CPU_TARGET", "native")
# Stage 1 default: full stdlib set. Opt-in experiment only — may shrink the
# bundle but can break packages that touch filtered stdlibs at runtime.
const FILTER_STDLIBS = get(ENV, "QCI_FILTER_STDLIBS", "") == "1"

@info "QCI Kanban PackageCompiler build" ROOT OUT cpu_target = CPU_TARGET filter_stdlibs = FILTER_STDLIBS julia = string(VERSION)

if !isfile(MANIFEST)
    error("""
    Missing product Manifest.toml at $MANIFEST.
    PackageCompiler create_app requires a resolved project + manifest.
    From qci-kanban/ run:
      julia --project=. -e 'using Pkg; Pkg.instantiate()'
    then re-run this script.
    """)
end

if !isfile(PRE)
    error("Missing precompile execution file: $PRE")
end

duration_s = @elapsed create_app(ROOT, OUT;
    executables = ["qci-kanban" => "julia_main"],
    precompile_execution_file = PRE,
    incremental = false,
    filter_stdlibs = FILTER_STDLIBS,
    force = true,
    include_lazy_artifacts = true,
    include_transitive_dependencies = true,
    include_preferences = true,
    cpu_target = CPU_TARGET,
)

@info "create_app finished" OUT duration_s = round(duration_s; digits = 1)
