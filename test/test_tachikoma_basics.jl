using Test
using Tachikoma
const T = Tachikoma

@testset "TachikomaUITest: TestBackend basics" begin
    @testset "Render simple Paragraph" begin
        tb = T.TestBackend(30, 5)
        T.render_widget!(tb, T.Paragraph("hello tachikoma"))
        @test T.char_at(tb, 1, 1) == 'h'
        @test occursin("hello tachikoma", T.row_text(tb, 1))
        @test T.find_text(tb, "tachikoma") !== nothing
    end

    @testset "KeyEvent and handle_key! on TextInput" begin
        input = T.TextInput(text="abc", focused=true)
        @test T.text(input) == "abc"

        T.handle_key!(input, T.KeyEvent('!'))
        @test T.text(input) == "abc!"

        T.handle_key!(input, T.KeyEvent(:backspace))
        @test T.text(input) == "abc"
    end

    @testset "Direct Model update! testing (Elm pattern)" begin
        @kwdef mutable struct Counter <: T.Model
            quit::Bool = false
            count::Int = 0
        end

        T.should_quit(m::Counter) = m.quit

        function T.update!(m::Counter, evt::T.KeyEvent)
            if evt.key == :char && evt.char == '+'
                m.count += 1
            elseif evt.key == :escape
                m.quit = true
            end
        end

        m = Counter()
        T.update!(m, T.KeyEvent('+'))
        @test m.count == 1

        T.update!(m, T.KeyEvent('+'))
        @test m.count == 2

        T.update!(m, T.KeyEvent(:escape))
        @test m.quit == true
    end

    @testset "Layout split works" begin
        area = T.Rect(1, 1, 80, 24)
        cols = T.split_layout(T.Layout(T.Horizontal, [T.Fixed(20), T.Fill()]), area)
        @test length(cols) == 2
        @test cols[1].width == 20
        @test cols[2].width == 60
    end
end

# Example of property-based testing pattern (from Tachikoma docs)
@testset "Paragraph never crashes on arbitrary text (PBT)" begin
    @check function paragraph_robust(text = Data.Text(Data.Characters(); max_len=100))
        tb = T.TestBackend(40, 3)
        T.render_widget!(tb, T.Paragraph(text))
        true  # survived render
    end
end
