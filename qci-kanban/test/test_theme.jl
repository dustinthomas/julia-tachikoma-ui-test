# Phase 2a — theme palette + accessors + no-raw-ColorRGB enforcement.
# Depends on `using QciKanban`, `const T = Tachikoma` from runtests.jl.

const TH = QciKanban.Theming

@testset "Phase 2a — Theme palette" begin
    @testset "exact palette values from DESIGN.md 'Theme (final)'" begin
        @test TH.col_bg()         == T.ColorRGB(13, 17, 33)
        @test TH.col_surface()    == T.ColorRGB(24, 28, 52)
        @test TH.col_surface_hi() == T.ColorRGB(30, 32, 75)
        @test TH.col_primary()    == T.ColorRGB(0, 188, 212)
        @test TH.col_primary_hi() == T.ColorRGB(77, 216, 235)
        @test TH.col_text()       == T.ColorRGB(230, 237, 243)
        @test TH.col_text_dim()   == T.ColorRGB(140, 150, 180)
        @test TH.col_text_muted() == T.ColorRGB(100, 110, 165)
        @test TH.col_ok()         == T.ColorRGB(78, 204, 94)
        @test TH.col_warn()       == T.ColorRGB(240, 198, 116)
        @test TH.col_err()        == T.ColorRGB(224, 60, 49)
        # G2: Gantt alternating period wash (between BG and SURFACE)
        @test TH.col_gantt_period_alt() == T.ColorRGB(20, 24, 48)
        @test TH.GANTT_PERIOD_ALT == T.ColorRGB(20, 24, 48)
    end

    @testset "selection style is cyan-on-navy bold" begin
        s = TH.sel_style()
        @test s.fg == TH.col_primary()
        @test s.bg == TH.col_surface_hi()
        @test s.bold == true
    end

    @testset "priority_color maps High/Medium/Low to err/warn/ok" begin
        @test TH.priority_color("High")   == TH.col_err()
        @test TH.priority_color("Medium") == TH.col_warn()
        @test TH.priority_color("Low")    == TH.col_ok()
        @test TH.priority_color("???")    == TH.col_text_dim()
    end

    @testset "epic_color is a stable 5-ramp for ints and strings" begin
        cols = [TH.epic_color(i) for i in 1:5]
        @test length(unique(cols)) == 5              # 5 distinct colors
        @test TH.epic_color(6) == TH.epic_color(1)   # cycles
        @test all(c isa T.ColorRGB for c in cols)
        # string ids are stable + land in the ramp
        @test TH.epic_color("EPIC-100") == TH.epic_color("EPIC-100")
        @test TH.epic_color("EPIC-100") in cols
        @test TH.epic_color("") == cols[1]
    end

    @testset "v1 compatibility aliases still resolve to correct colors" begin
        @test TH.QCI_CYAN      == T.ColorRGB(0, 188, 212)
        @test TH.QCI_NAVY      == T.ColorRGB(30, 32, 75)
        @test TH.QCI_SECONDARY == T.ColorRGB(100, 110, 165)
        # v1 module-level constants remain defined + typed (keeps v1 tests green)
        @test QciKanban.QCI_SECONDARY isa T.ColorRGB
        @test QciKanban.QCI_CYAN isa T.ColorRGB
    end

    @testset "no raw ColorRGB literals under src/ui/ + src/gfx/ outside theme.jl" begin
        roots = [normpath(joinpath(@__DIR__, "..", "src", "ui")),
                 normpath(joinpath(@__DIR__, "..", "src", "gfx"))]
        offenders = String[]
        for root in roots
            for (dir, _, files) in walkdir(root)   # recursive
                for fn in files
                    endswith(fn, ".jl") || continue
                    fn == "theme.jl" && continue
                    f = joinpath(dir, fn)
                    for (i, line) in enumerate(eachline(f))
                        # ignore comments
                        code = split(line, '#')[1]
                        if occursin("ColorRGB(", code)
                            push!(offenders, "$(relpath(f, root)):$i")
                        end
                    end
                end
            end
        end
        @test isempty(offenders)
    end
end
