# ═══════════════════════════════════════════════════════════════════════════
# test/coverage_gate.jl — Phase 6 coverage gate for QCI Kanban.
#
# Measures per-file line coverage over ALL of src/ using Coverage.jl, honours
# the in-source `# COV_EXCL_START` / `# COV_EXCL_STOP` block markers and
# `# COV_EXCL_LINE` markers (plus the explicit `EXPLICIT_EXCLUSIONS` list
# below, documented in COVERAGE.md), then:
#
#   • REPORTS v1-legacy files  (src/QciKanban.jl, src/db.jl) — not gated.
#   • GATES v2 files (domain.jl, config.jl, auth/, store/, notify/, ui/, gfx/):
#     exits NONZERO with a per-file uncovered-line report if any is below 100%.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   # One shot: run the suite under coverage, analyse, gate, clean up *.cov.
#   julia --project=. test/coverage_gate.jl
#
#   # Analyse *.cov already produced by a prior run (skip the subprocess).
#   # Scope instrumentation to src/ so no *.cov leaks into test/ or the depot:
#   julia --project=. --code-coverage=@src test/runtests.jl
#   julia --project=. test/coverage_gate.jl --no-run
#
# Either way the script deletes every *.cov it processed on exit. Coverage.jl
# lives in the test extras; when this script is run with `--project=.` it is
# not on the load path, so the script transparently adds it to a throwaway
# environment (offline, from the depot).
# ═══════════════════════════════════════════════════════════════════════════

const PROJ = normpath(joinpath(@__DIR__, ".."))
const SRC  = joinpath(PROJ, "src")

# ── v1-legacy files: measured and reported, never gated (see CLAUDE.md) ──────
const V1_FILES = Set(["QciKanban.jl", "db.jl"])

# ── Explicit line exclusions beyond the in-source COV_EXCL markers ───────────
# Keyed by path relative to src/. Kept EMPTY by policy: every real exclusion is
# an auditable in-source `# COV_EXCL_*` marker (see COVERAGE.md). This hook
# exists only for lines a marker cannot express; add entries sparingly and
# document each in COVERAGE.md.
const EXPLICIT_EXCLUSIONS = Dict{String,Set{Int}}()

# ── Load Coverage.jl (add it to a scratch env if not already reachable) ──────
# Coverage lives in the test extras, so it is NOT on the load path under
# `--project=.`. Resolve it once, at top level, to keep world ages sane.
import Pkg
try
    @eval import Coverage
catch
    Pkg.activate(mktempdir(); io = devnull)
    Pkg.add("Coverage"; io = devnull)
    @eval import Coverage
end

# ── Clean *.cov under src/ ───────────────────────────────────────────────────
function _clean_cov()
    for (root, _, files) in walkdir(SRC)
        for f in files
            endswith(f, ".cov") && rm(joinpath(root, f); force = true)
        end
    end
end

# ── Run the suite under --code-coverage=user in a subprocess ─────────────────
function _run_coverage_suite()
    _clean_cov()
    # Scope instrumentation to src/ so no *.cov litters test/ or the depot.
    cmd = `$(Base.julia_cmd()) --project=$PROJ --code-coverage=@$SRC $(joinpath(PROJ, "test", "runtests.jl"))`
    @info "Running suite under coverage" cmd
    run(cmd)
    return
end

# ── Build the set of excluded 1-based line numbers for one source file ───────
function _excluded_lines(path::AbstractString)
    excl = Set{Int}()
    within = false
    for (i, line) in enumerate(eachline(path))
        if occursin("COV_EXCL_START", line)
            within = true; push!(excl, i); continue
        elseif occursin("COV_EXCL_STOP", line)
            within = false; push!(excl, i); continue
        end
        (within || occursin("COV_EXCL_LINE", line)) && push!(excl, i)
    end
    rel = relpath(path, SRC)
    haskey(EXPLICIT_EXCLUSIONS, rel) && union!(excl, EXPLICIT_EXCLUSIONS[rel])
    excl
end

struct FileReport
    rel::String
    covered::Int
    coverable::Int
    uncovered::Vector{Int}
    gated::Bool
end

pct(r::FileReport) = r.coverable == 0 ? 100.0 : 100 * r.covered / r.coverable

function _analyse()
    fcs = Coverage.process_folder(SRC)   # Vector{FileCoverage}
    reports = FileReport[]
    for fc in fcs
        path = fc.filename
        cov = collect(fc.coverage)           # Vector{Union{Nothing,Int}}
        excl = _excluded_lines(path)
        for i in excl
            i <= length(cov) && (cov[i] = nothing)
        end
        coverable = count(c -> c isa Int, cov)
        covered   = count(c -> c isa Int && c > 0, cov)
        uncovered = [i for i in eachindex(cov) if cov[i] isa Int && cov[i] == 0]
        rel = relpath(path, SRC)
        gated = !(basename(path) in V1_FILES)
        push!(reports, FileReport(rel, covered, coverable, uncovered, gated))
    end
    sort!(reports; by = r -> (r.gated ? 0 : 1, r.rel))
    reports
end

function _print_table(reports)
    println("\n", "="^72)
    println("QCI Kanban — coverage gate report")
    println("="^72)
    namew = maximum(length(r.rel) for r in reports; init = 20) + 2
    hdr = rpad("file", namew) * rpad("cov/total", 12) * rpad("pct", 9) * "status"
    println(hdr); println("-"^length(hdr))
    function row(r)
        p = pct(r)
        tag = !r.gated ? "report" : (p >= 100 ? "PASS" : "FAIL")
        println(rpad(r.rel, namew) *
                rpad("$(r.covered)/$(r.coverable)", 12) *
                rpad(string(round(p; digits = 2), "%"), 9) * tag)
    end
    println("── gated (v2) ─────────────────────────────────────────────────────────")
    foreach(row, filter(r -> r.gated, reports))
    println("── reported (v1-legacy, not gated) ─────────────────────────────────────")
    foreach(row, filter(r -> !r.gated, reports))
end

function main()
    run_suite = !("--no-run" in ARGS)
    try
        run_suite && _run_coverage_suite()
        reports = _analyse()
        _print_table(reports)
        failing = filter(r -> r.gated && pct(r) < 100, reports)
        if !isempty(failing)
            println("\n", "!"^72)
            println("GATE FAILED — gated v2 files below 100% line coverage:")
            for r in failing
                srclines = readlines(joinpath(SRC, r.rel))
                println("\n  $(r.rel)  ($(r.covered)/$(r.coverable), $(round(pct(r); digits=2))%)")
                for ln in r.uncovered
                    txt = ln <= length(srclines) ? strip(srclines[ln]) : ""
                    println("    L$(lpad(ln, 4)): $(txt)")
                end
            end
            println("\n", "!"^72)
            return 1
        end
        println("\nGATE PASSED — all gated v2 files at 100% line coverage.")
        return 0
    finally
        _clean_cov()
    end
end

exit(main())
