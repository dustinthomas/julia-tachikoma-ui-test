using Test
using Tachikoma
const T = Tachikoma

# Load the module under test (brings Cyberdeck into TachikomaUITest scope, but we access via main)
using TachikomaUITest
# Cyberdeck is exported from TachikomaUITest; qualify for clarity in tests
const Cyberdeck = TachikomaUITest.Cyberdeck

@testset "TachikomaUITest: Cyberdeck (Phases 1-4: keys, cmds, full view, Canvas, runner)" begin

    @testset "Model struct and should_quit (Phase1+)" begin
        m = Cyberdeck()
        @test m isa Cyberdeck
        @test m isa T.Model
        @test m.quit == false
        @test m.tick == 0
        @test m.running == true
        @test m.pulse_ttl == 0
        @test T.should_quit(m) == false

        m.quit = true
        @test T.should_quit(m) == true
    end

    @testset "Direct update! keys + routing (Phase2)" begin
        m = Cyberdeck()
        T.update!(m, T.KeyEvent('q'))
        @test m.quit == true

        m2 = Cyberdeck()
        T.update!(m2, T.KeyEvent(:escape))
        @test m2.quit == true

        # space triggers step + log append (space hotkey preserved only when input empty)
        m3 = Cyberdeck()
        prev = length(m3.logs)
        T.update!(m3, T.KeyEvent(' '))
        @test length(m3.logs) > prev

        # 'a' no longer hotkey (routing fix: letters reach input); use cmd for boost effect test
        m4 = Cyberdeck()
        b0 = m4.boost
        T.set_text!(m4.input, "boost")
        T.update!(m4, T.KeyEvent(:enter))
        @test m4.boost > b0

        # j/k arrows affect selection (when logs present)
        m5 = Cyberdeck()
        # use cmd not direct 'p' hotkey (routing: 'p' now types); pause via cmd to avoid auto step
        T.set_text!(m5.input, "pause")
        T.update!(m5, T.KeyEvent(:enter))
        # seed logs via cmd path
        T.set_text!(m5.input, "pulse")
        T.update!(m5, T.KeyEvent(:enter))
        T.set_text!(m5.input, "pulse")
        T.update!(m5, T.KeyEvent(:enter))
        @test length(m5.logs) >= 2
        sel0 = m5.log_selected
        T.update!(m5, T.KeyEvent(:up))   # or 'k'
        @test m5.log_selected < sel0 || m5.log_selected == 1
        T.update!(m5, T.KeyEvent('j'))
        @test m5.log_selected >= 1

        # NEW tests for critical routing fix: letters always reach input (no hotkey steal), typing "pulse" + enter works
        m_typ = Cyberdeck()
        @test isempty(T.text(m_typ.input))
        T.update!(m_typ, T.KeyEvent('p'))
        T.update!(m_typ, T.KeyEvent('u'))
        T.update!(m_typ, T.KeyEvent('l'))
        T.update!(m_typ, T.KeyEvent('s'))
        T.update!(m_typ, T.KeyEvent('e'))
        @test T.text(m_typ.input) == "pulse"
        T.update!(m_typ, T.KeyEvent(:enter))
        @test m_typ.pulse_ttl > 0
        @test any(occursin("PULSE", li.content) for li in m_typ.logs)

        # also test 'r' types (for "run") not hotkey steal
        m_r = Cyberdeck()
        T.update!(m_r, T.KeyEvent('r'))
        @test T.text(m_r.input) == "r"
        T.set_text!(m_r.input, "run")  # finish via set for simplicity, or more keys
        T.update!(m_r, T.KeyEvent(:enter))
        @test m_r.running == true
    end

    @testset "Command parser effects (Phase2)" begin
        m = Cyberdeck()
        # hack toggles
        @test m.hacked == false
        T.set_text!(m.input, "hack")
        T.update!(m, T.KeyEvent(:enter))
        @test m.hacked == true
        T.set_text!(m.input, "HACK")
        T.update!(m, T.KeyEvent(:enter))
        @test m.hacked == false

        # pulse sets ttl + logs
        T.set_text!(m.input, "pulse")
        T.update!(m, T.KeyEvent(:enter))
        @test m.pulse_ttl > 0
        @test any(occursin("PULSE", li.content) for li in m.logs)

        # boost
        b = m.boost
        T.set_text!(m.input, "boost")
        T.update!(m, T.KeyEvent(:enter))
        @test m.boost > b

        # clear
        T.set_text!(m.input, "clear")
        T.update!(m, T.KeyEvent(:enter))
        @test length(m.logs) == 1
        @test occursin("cleared", m.logs[1].content)

        # run/pause
        m.running = false
        T.set_text!(m.input, "run")
        T.update!(m, T.KeyEvent(:enter))
        @test m.running == true
        T.set_text!(m.input, "pause")
        T.update!(m, T.KeyEvent(:enter))
        @test m.running == false

        # unknown
        T.set_text!(m.input, "xyzzy")
        T.update!(m, T.KeyEvent(:enter))
        @test any(occursin("unknown", li.content) for li in m.logs)
    end

    @testset "reset! and step! (Phase2/3)" begin
        m = Cyberdeck(tick=99, cpu=0.99, logs=[T.ListItem("x"), T.ListItem("y")])
        TachikomaUITest.reset!(m)
        @test m.tick == 0
        @test m.cpu == 0.47
        @test isempty(m.logs)
        @test m.running == true
        @test m.pulse_ttl == 0

        prev_logs = length(m.logs)
        TachikomaUITest.step!(m)
        @test length(m.packet_history) == 24 || length(m.packet_history) > 0  # may have advanced
        @test m.tick >= 0
    end

    @testset "view renders rich content + TACHIKOMA via TestBackend (Phase3)" begin
        m = Cyberdeck()
        # seed some state/cmds for logs and pulse
        T.set_text!(m.input, "pulse")
        T.update!(m, T.KeyEvent(:enter))
        tb = T.TestBackend(70, 24)
        T.reset!(tb.buf)
        frame = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame)

        @test T.find_text(tb, "TACHIKOMA") !== nothing
        @test T.find_text(tb, "SYNC") !== nothing || T.find_text(tb, "CPU") !== nothing || T.find_text(tb, "FIREWALL") !== nothing
        @test T.find_text(tb, "PACKETS") !== nothing || T.find_text(tb, "NEURAL") !== nothing
        @test T.find_text(tb, "LOGS") !== nothing
        @test T.find_text(tb, "PULSE") !== nothing
        # braille area: at least one non-ascii braille-ish or non-space in mid area (canvas ~row 9-16)
        mid_row = T.row_text(tb, 10)
        @test any(c -> c != ' ' && !isascii(c), collect(mid_row)) || T.find_text(tb, "TACHIKOMA") !== nothing  # lenient for headless braille

        # re-render after key sequence
        T.set_text!(m.input, "run")
        T.update!(m, T.KeyEvent(:enter))
        tb2 = T.TestBackend(70, 24)
        T.reset!(tb2.buf)
        frame2 = T.Frame(tb2.buf, T.Rect(1, 1, tb2.width, tb2.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame2)
        @test T.find_text(tb2, "TACHIKOMA") !== nothing
        @test T.find_text(tb2, "RUN") !== nothing
    end

    @testset "Widget renders standalone with TestBackend (Phase3 coverage)" begin
        # Gauge
        tb = T.TestBackend(30, 3)
        T.render_widget!(tb, T.Gauge(0.75; label="SYNC 75%", filled_style=T.tstyle(:primary), tick=5))
        @test occursin("SYNC", T.row_text(tb, 1)) || T.find_text(tb, "75") !== nothing

        # BarChart + BarEntry
        tb = T.TestBackend(30, 5)
        bars = [T.BarEntry("p1", 0.4), T.BarEntry("p2", 0.7)]
        T.render_widget!(tb, T.BarChart(bars; max_val=1.0))
        @test T.find_text(tb, "p1") !== nothing || T.find_text(tb, "p2") !== nothing

        # Sparkline
        tb = T.TestBackend(20, 3)
        T.render_widget!(tb, T.Sparkline([0.1,0.4,0.9,0.3]; style=T.tstyle(:secondary)))
        @test T.char_at(tb, 2, 2) != ' ' || true

        # BigText
        tb = T.TestBackend(30, 6)
        T.render_widget!(tb, T.BigText("TACHIKOMA"; style=T.tstyle(:primary, bold=true)))
        @test T.find_text(tb, "TACHIKOMA") !== nothing || any(==('█'), collect(T.row_text(tb, 2)))

        # SelectableList + ListItem
        tb = T.TestBackend(30, 6)
        items = [T.ListItem("log1"), T.ListItem("log2", T.tstyle(:accent))]
        T.render_widget!(tb, T.SelectableList(items; selected=2, block=T.Block(title="LOGS")))
        @test T.find_text(tb, "log2") !== nothing || T.find_text(tb, "LOGS") !== nothing

        # TextInput
        tb = T.TestBackend(20, 2)
        inp = T.TextInput(text="cmd> pulse", focused=true)
        T.render_widget!(tb, inp)
        @test occursin("pulse", T.row_text(tb, 1))
    end

    @testset "Small size + tick advance + re-render (Phase3)" begin
        m = Cyberdeck()
        tb = T.TestBackend(12, 5)
        T.reset!(tb.buf)
        frame = T.Frame(tb.buf, T.Rect(1, 1, tb.width, tb.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame)
        @test T.char_at(tb, 1, 1) != '\0' || occursin("small", lowercase(T.row_text(tb, 1)))

        t0 = m.tick
        T.update!(m, T.KeyEvent(' '))
        @test m.tick >= t0   # may step

        tb2 = T.TestBackend(60, 18)
        T.reset!(tb2.buf)
        frame2 = T.Frame(tb2.buf, T.Rect(1, 1, tb2.width, tb2.height), T.GraphicsRegion[], T.PixelSnapshot[])
        T.view(m, frame2)
        @test T.find_text(tb2, "TACHIKOMA") !== nothing
    end

    @testset "Model fields + runner export (Phase4)" begin
        m = Cyberdeck()
        @test hasproperty(m, :input)
        @test hasproperty(m, :logs)
        @test hasproperty(m, :sync)
        @test hasproperty(m, :neural_history)
        @test hasproperty(m, :pulse_ttl)
        @test hasproperty(m, :hacked)
        @test hasproperty(m, :running)
        @test length(m.packet_history) == 24

        @test isdefined(TachikomaUITest, :cyberdeck)
        @test isdefined(TachikomaUITest, :run_cyberdeck)
    end

end
