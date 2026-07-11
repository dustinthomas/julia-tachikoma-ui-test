# packaging/build_linux_app.jl — PackageCompiler create_app driver (Linux).
#
# Run from qci-kanban/:
#   julia --project=. -e 'using Pkg; Pkg.instantiate()'          # Step 0
#   julia --project=packaging -e 'using Pkg; Pkg.instantiate()'  # Step 1
#   julia --project=packaging packaging/build_linux_app.jl       # Step 2
#
# Optional: QCI_CPU_TARGET=native (default) or a broader target for redistrib.
# PackageCompiler is NOT a product dependency — only this packaging/ project.

using PackageCompiler

const ROOT = abspath(dirname(@__DIR__))  # qci-kanban/
const OUT = joinpath(ROOT, "dist", "qci-kanban-linux")
const PRE = joinpath(@__DIR__, "precompile_app.jl")
const MANIFEST = joinpath(ROOT, "Manifest.toml")
const CPU_TARGET = get(ENV, "QCI_CPU_TARGET", "native")

@info "QCI Kanban PackageCompiler build" ROOT OUT cpu_target = CPU_TARGET julia = string(VERSION)

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
    filter_stdlibs = false,
    force = true,
    include_lazy_artifacts = true,
    include_transitive_dependencies = true,
    include_preferences = true,
    cpu_target = CPU_TARGET,
)

@info "create_app finished" OUT duration_s = round(duration_s; digits = 1)
