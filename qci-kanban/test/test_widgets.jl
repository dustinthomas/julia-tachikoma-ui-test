# Phase 3 — focus-routable form widgets (Selector, MultiSelect): unit-level.
Qw = QciKanban

@testset "Phase 3 — Selector widget" begin
    s = Qw.Selector("Priority:", ["Low", "Medium", "High"], Any["Low", "Medium", "High"]; selected = 2)
    @test Qw.text(s) == "Medium"
    @test Qw.sel_current_value(s) == "Medium"
    @test Tachikoma.value(s) == "Medium"
    @test Tachikoma.focusable(s)
    # right cycles forward (wraps), left backward (wraps)
    @test Tachikoma.handle_key!(s, T.KeyEvent(:right)); @test Qw.text(s) == "High"
    @test Tachikoma.handle_key!(s, T.KeyEvent(:right)); @test Qw.text(s) == "Low"   # wrap
    @test Tachikoma.handle_key!(s, T.KeyEvent(:left));  @test Qw.text(s) == "High"  # wrap back
    # space also advances
    @test Tachikoma.handle_key!(s, T.KeyEvent(' '))
    # non-nav key ignored
    @test !Tachikoma.handle_key!(s, T.KeyEvent('x'))
    # renders focused + unfocused without error
    for foc in (true, false)
        s.focused = foc
        tb = T.TestBackend(40, 3); T.reset!(tb.buf)
        Tachikoma.render(s, T.Rect(1, 1, 30, 1), tb.buf)
        @test T.find_text(tb, "Priority") !== nothing
    end
    # empty selector degrades gracefully
    e = Qw.Selector("E:", String[], Any[])
    @test Qw.text(e) == ""
    @test Qw.sel_current_value(e) === nothing
    @test !Tachikoma.handle_key!(e, T.KeyEvent(:right))
end

@testset "Phase 3 — MultiSelect widget" begin
    ms = Qw.MultiSelect("Labels:", ["bug", "ui", "docs"], ["l1", "l2", "l3"])
    @test Tachikoma.focusable(ms)
    @test Qw.ms_selected_values(ms) == String[]
    @test Qw.text(ms) == ""
    # chip cursor: left/right only (up/down are field-nav at the focus router)
    @test Tachikoma.handle_key!(ms, T.KeyEvent(:right)); @test ms.cursor == 2
    @test Tachikoma.handle_key!(ms, T.KeyEvent(:right)); @test ms.cursor == 3
    @test Tachikoma.handle_key!(ms, T.KeyEvent(:left));  @test ms.cursor == 2
    @test Tachikoma.handle_key!(ms, T.KeyEvent(:left));  @test ms.cursor == 1
    # space toggles the highlighted chip
    @test Tachikoma.handle_key!(ms, T.KeyEvent(' '))
    @test ms.checked[1]
    @test Qw.ms_selected_values(ms) == ["l1"]
    @test Qw.text(ms) == "bug"
    @test !Tachikoma.handle_key!(ms, T.KeyEvent('z'))
    # render focused (highlight + checked) and unfocused
    for foc in (true, false)
        ms.focused = foc
        tb = T.TestBackend(50, 3); T.reset!(tb.buf)
        Tachikoma.render(ms, T.Rect(1, 1, 45, 1), tb.buf)
        @test T.find_text(tb, "Labels") !== nothing
    end
    # empty options: renders "(none)" and ignores keys
    e = Qw.MultiSelect("L:", String[], String[])
    @test !Tachikoma.handle_key!(e, T.KeyEvent(' '))
    tb = T.TestBackend(30, 3); T.reset!(tb.buf)
    Tachikoma.render(e, T.Rect(1, 1, 25, 1), tb.buf)
    @test T.find_text(tb, "(none)") !== nothing
    # narrow width: chips break early without error
    tb2 = T.TestBackend(12, 3); T.reset!(tb2.buf)
    ms.focused = true
    Tachikoma.render(ms, T.Rect(1, 1, 10, 1), tb2.buf)
    @test T.row_text(tb2, 1) !== nothing
end

@testset "Phase 3 — MultiSelect green bubbles (no checkmarks, no overlap)" begin
    ms = Qw.MultiSelect("Labels:", ["bug", "ui"], ["l1", "l2"]; checked = [true, false])
    ms.focused = true
    tb = T.TestBackend(60, 3); T.reset!(tb.buf)
    Tachikoma.render(ms, T.Rect(1, 1, 55, 1), tb.buf)
    row = T.row_text(tb, 1)
    # green bubbles, not checkbox marks
    @test occursin("●", row) || occursin("•", row)  # filled bubble for checked
    @test occursin("○", row) || occursin("◯", row) || occursin("o", row)  # empty for unchecked
    @test !occursin("☑", row) && !occursin("☐", row)
    # bubble and label name are separated (no "●bug" glue / overlap)
    @test occursin("● bug", row) || occursin("• bug", row)
    # checked bubble uses success green
    loc = T.find_text(tb, "bug")
    @test loc !== nothing
    # walk left from the name for the bubble glyph; assert col_ok on a green cell nearby
    found_ok = false
    for dx in 0:4
        x = max(1, loc.x - dx)
        st = T.style_at(tb, x, loc.y)
        if st.fg == Qw.Theming.col_ok()
            found_ok = true
            break
        end
    end
    @test found_ok
    # chips must start after the "Labels:" field label (no overlap into label)
    lab = T.find_text(tb, "Labels")
    bug = T.find_text(tb, "bug")
    @test lab !== nothing && bug !== nothing
    @test bug.x > lab.x + length("Labels:")
end

@testset "Phase 3 — DateField widget (picker + manual)" begin
    using Dates
    df = Qw.DateField(; text = "2026-07-15")
    @test Tachikoma.focusable(df)
    @test Tachikoma.text(df) == "2026-07-15"
    @test !df.menu_open
    # Space opens calendar menu
    @test Tachikoma.handle_key!(df, T.KeyEvent(' '))
    @test df.menu_open
    # arrows move the calendar cursor
    before = df.menu_date
    @test Tachikoma.handle_key!(df, T.KeyEvent(:right))
    @test df.menu_date == before + Day(1)
    @test Tachikoma.handle_key!(df, T.KeyEvent(:left))
    @test df.menu_date == before
    @test Tachikoma.handle_key!(df, T.KeyEvent(:down))
    @test df.menu_date == before + Day(7)
    @test Tachikoma.handle_key!(df, T.KeyEvent(:up))
    @test df.menu_date == before
    # unhandled key while menu open → false
    @test !Tachikoma.handle_key!(df, T.KeyEvent('z'))
    @test df.menu_open
    # Enter commits selection and closes menu
    df.menu_date = Date(2026, 8, 1)
    @test Tachikoma.handle_key!(df, T.KeyEvent(:enter))
    @test !df.menu_open
    @test Tachikoma.text(df) == "2026-08-01"
    # typing digits enters/continues manual entry (menu closed)
    Qw.set_date_text!(df, "")
    for ch in collect("2026-03-20")
        @test Tachikoma.handle_key!(df, T.KeyEvent(ch))
    end
    @test Tachikoma.text(df) == "2026-03-20"
    @test !df.menu_open
    # backspace removes a char; empty backspace is a no-op success
    @test Tachikoma.handle_key!(df, T.KeyEvent(:backspace))
    @test Tachikoma.text(df) == "2026-03-2"
    Qw.set_date_text!(df, "")
    @test Tachikoma.handle_key!(df, T.KeyEvent(:backspace))
    @test Tachikoma.text(df) == ""
    # left/right/delete swallowed when menu closed
    @test Tachikoma.handle_key!(df, T.KeyEvent(:left))
    @test Tachikoma.handle_key!(df, T.KeyEvent(:right))
    @test Tachikoma.handle_key!(df, T.KeyEvent(:delete))
    # non-char structural-ish fallthrough
    @test !Tachikoma.handle_key!(df, T.KeyEvent(:f1))
    # render value + open menu without crash
    Qw.set_date_text!(df, "2026-03-20")
    df.focused = true
    tb = T.TestBackend(40, 12); T.reset!(tb.buf)
    Tachikoma.render(df, T.Rect(1, 1, 35, 1), tb.buf)
    @test T.find_text(tb, "2026-03-20") !== nothing
    df.menu_open = true
    df.menu_date = Date(2026, 3, 20)
    Tachikoma.render(df, T.Rect(1, 1, 35, 10), tb.buf)  # taller rect for calendar
    @test T.find_text(tb, "2026") !== nothing || T.find_text(tb, "Mar") !== nothing ||
          T.find_text(tb, "March") !== nothing
end

@testset "C1/U1 — unicode-safe truncation helpers" begin
    @testset "fit_width: width-budgeted, codepoint-safe, never crashes" begin
        @test Qw.fit_width("hello", 0) == ""
        @test Qw.fit_width("hello", -3) == ""
        @test Qw.fit_width("hello", 10) == "hello"      # fits → unchanged
        @test Qw.fit_width("hello", 3) == "hel"
        # multibyte: em dash / box-drawing must not throw or split a codepoint
        @test Qw.fit_width("a—b—c", 3) == "a—b"          # em dash is 1 column, 3 bytes
        @test Qw.fit_width("◄ Priority ►", 3) == "◄ P"
        # emoji are double-width: budget by display columns, whole glyph only
        @test Qw.fit_width("🎯🎯🎯", 3) == "🎯"           # 2 cols fit, next would be 4>3
        @test Qw.fit_width("🎯x", 2) == "🎯"
        @test Qw.fit_width("🎯x", 1) == ""               # can't fit a 2-col glyph in 1
    end
    @testset "ellipsize: appends … only when truncating, width-safe" begin
        @test Qw.ellipsize("hello", 0) == ""
        @test Qw.ellipsize("hello", 10) == "hello"       # fits → no ellipsis
        @test Qw.ellipsize("hello world", 5) == "hell…"
        @test Qw.ellipsize("café-society", 4) == "caf…"  # accented char safe
        # never throws on a multibyte boundary
        @test Qw.ellipsize("日本語テスト", 4) isa String
        @test endswith(Qw.ellipsize("日本語テスト", 4), "…")
    end
    @testset "Selector renders emoji/box-drawing value without crashing at any width" begin
        s = Qw.Selector("Epic:", ["🎯 Launch — Q3", "日本語"], Any["a", "b"]; selected = 1, focused = true)
        for w in 1:20
            tb = T.TestBackend(w + 2, 3); T.reset!(tb.buf)
            Tachikoma.render(s, T.Rect(1, 1, w, 1), tb.buf)   # must not throw
            @test T.row_text(tb, 1) !== nothing
        end
    end
end
