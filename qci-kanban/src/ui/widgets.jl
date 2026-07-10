# ═══════════════════════════════════════════════════════════════════════
# ui/widgets.jl — small focus-routable form widgets for the edit modal.
#
# Tachikoma's DropDown/Checkbox use an Int `focused` field (highlight index),
# which collides with the focus router's Bool `.focused` convention. So the
# card-edit form uses these purpose-built widgets instead: each has a plain
# `focused::Bool`, a `handle_key!` that cycles/toggles on arrows/space, and a
# `text`/`value` accessor so tests can read them and the router can drive them
# uniformly. No raw ColorRGB literals here — all color via Theming accessors.
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Dates

# ── Unicode-safe truncation (shared by every view) ──────────────────────────
# Slicing a String by a codepoint count used as a byte index (`s[1:n]`) throws
# StringIndexError on any multibyte glyph (em dash, box-drawing, emoji). These
# two helpers are the ONE truncation path for all of src/ui + src/gfx: they walk
# whole characters and budget by DISPLAY width (`textwidth`, so emoji/CJK count
# as their true 2 columns), never producing an invalid slice or overflowing the
# rect. `n <= 0` yields "" (guards the U9 zero-width case).

"""
    fit_width(s, n) -> String

Longest prefix of `s` whose display width (`textwidth`) is ≤ `n` columns,
truncated on whole-character boundaries. `""` when `n ≤ 0`. No ellipsis.
"""
function fit_width(s::AbstractString, n::Integer)
    n <= 0 && return ""
    textwidth(s) <= n && return String(s)
    io = IOBuffer()
    used = 0
    for ch in s
        w = textwidth(ch)
        used + w > n && break
        print(io, ch)
        used += w
    end
    String(take!(io))
end

"""
    ellipsize(s, n) -> String

Like `fit_width`, but when `s` is wider than `n` columns the result is truncated
to fit `n` **including** a trailing `…`. `""` when `n ≤ 0`.
"""
function ellipsize(s::AbstractString, n::Integer)
    n <= 0 && return ""
    textwidth(s) <= n && return String(s)
    fit_width(s, max(1, n - 1)) * "…"
end

# ── Selector: single-choice cycler (priority / epic / sprint / assignee) ────
mutable struct Selector
    label::String
    options::Vector{String}      # display labels
    values::Vector{Any}          # underlying values (parallel to options)
    selected::Int                # 1-based index into options
    focused::Bool
end

function Selector(label::AbstractString, options::Vector{String}, values::Vector;
                  selected::Integer = 1, focused::Bool = false)
    n = length(options)
    Selector(String(label), options, Any[values...], clamp(Int(selected), 1, max(1, n)), focused)
end

function Tachikoma.focusable(::Selector)
    return true
end
sel_current_value(s::Selector) = isempty(s.values) ? nothing : s.values[clamp(s.selected, 1, length(s.values))]
Tachikoma.text(s::Selector) = isempty(s.options) ? "" : s.options[clamp(s.selected, 1, length(s.options))]
Tachikoma.value(s::Selector) = sel_current_value(s)

function Tachikoma.handle_key!(s::Selector, evt::KeyEvent)::Bool
    n = length(s.options)
    n == 0 && return false
    if evt.key === :left
        s.selected = mod1(s.selected - 1, n); return true
    elseif evt.key === :right || (evt.key === :char && evt.char == ' ')
        s.selected = mod1(s.selected + 1, n); return true
    end
    false
end

function Tachikoma.render(s::Selector, rect::Rect, buf::Buffer)
    rect.width < 1 && return
    lstyle = s.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim())
    set_string!(buf, rect.x, rect.y, s.label, lstyle)
    vx = rect.x + length(s.label) + 1
    val = Tachikoma.text(s)
    arrows = s.focused ? "◄ $(val) ►" : "  $(val)"
    vstyle = s.focused ? Style(; fg = col_primary_hi(), bold = true) : Style(; fg = col_text())
    avail = max(1, rect.x + rect.width - vx)
    set_string!(buf, vx, rect.y, fit_width(arrows, avail), vstyle)
end

# ── MultiSelect: labels multi-choice (space toggles the highlighted chip) ────
mutable struct MultiSelect
    label::String
    options::Vector{String}
    values::Vector{String}       # ids parallel to options
    checked::Vector{Bool}
    cursor::Int                  # 1-based highlighted chip
    focused::Bool
end

function MultiSelect(label::AbstractString, options::Vector{String}, values::Vector{String};
                     checked::Vector{Bool} = fill(false, length(options)), focused::Bool = false)
    n = length(options)
    ck = length(checked) == n ? copy(checked) : fill(false, n)
    MultiSelect(String(label), options, copy(values), ck, n == 0 ? 0 : 1, focused)
end

function Tachikoma.focusable(::MultiSelect)
    return true
end
ms_selected_values(ms::MultiSelect) = String[ms.values[i] for i in eachindex(ms.values) if ms.checked[i]]
Tachikoma.text(ms::MultiSelect) = join(String[ms.options[i] for i in eachindex(ms.options) if ms.checked[i]], ",")

function Tachikoma.handle_key!(ms::MultiSelect, evt::KeyEvent)::Bool
    n = length(ms.options)
    n == 0 && return false
    # left/right only — ↑/↓ are reserved for form field navigation at the router
    if evt.key === :left
        ms.cursor = mod1(ms.cursor - 1, n); return true
    elseif evt.key === :right
        ms.cursor = mod1(ms.cursor + 1, n); return true
    elseif evt.key === :char && evt.char == ' '
        ms.checked[ms.cursor] = !ms.checked[ms.cursor]; return true
    end
    false
end

function Tachikoma.render(ms::MultiSelect, rect::Rect, buf::Buffer)
    rect.width < 1 && return
    lstyle = ms.focused ? Style(; fg = col_primary(), bold = true) : Style(; fg = col_text_dim())
    set_string!(buf, rect.x, rect.y, ms.label, lstyle)
    # display-width for the field label so chips never draw under it
    x = rect.x + textwidth(ms.label) + 1
    maxx = rect.x + rect.width
    if isempty(ms.options)
        set_string!(buf, x, rect.y, "(none)", Style(; fg = col_text_muted()))
        return
    end
    for i in eachindex(ms.options)
        # Green filled bubble when checked; empty ring when not. Space after bubble
        # so the glyph never overlaps the label name.
        bubble = ms.checked[i] ? "●" : "○"
        chip = bubble * " " * ms.options[i] * " "
        chip_w = textwidth(chip)
        x + chip_w - 1 > maxx && break
        st = if ms.focused && i == ms.cursor
            # keep cursor highlight but preserve green on the bubble glyph
            sel_style()
        elseif ms.checked[i]
            Style(; fg = col_ok(), bold = true)
        else
            Style(; fg = col_text_dim())
        end
        # draw bubble in green even when the chip is the focused cursor
        if ms.checked[i]
            rest = " " * ms.options[i] * " "
            if ms.focused && i == ms.cursor
                set_string!(buf, x, rect.y, bubble,
                            Style(; fg = col_ok(), bg = col_surface_hi(), bold = true))
                set_string!(buf, x + textwidth(bubble), rect.y, rest, sel_style())
            else
                set_string!(buf, x, rect.y, chip, Style(; fg = col_ok(), bold = true))
            end
        else
            set_string!(buf, x, rect.y, chip, st)
        end
        x += chip_w
    end
end

# ── DateField: calendar menu + optional manual YYYY-MM-DD entry ─────────────

"""
    DateField(; text="", focused=false)

Start/Due editor: Space opens a month calendar; ←/→ day, ↑/↓ week; Enter
commits. Digits/`-`/backspace edit the text manually. Esc closes an open menu
without discarding the form (handled via `menu_open` + focus router).
"""
mutable struct DateField
    buffer::String
    focused::Bool
    menu_open::Bool
    menu_date::Date
end

function DateField(; text::AbstractString = "", focused::Bool = false)
    t = String(text)
    md = let d = tryparse(Date, t)
        d === nothing ? Dates.today() : d
    end
    DateField(t, focused, false, md)
end

function Tachikoma.focusable(::DateField)
    return true
end
Tachikoma.text(d::DateField) = d.buffer

function set_date_text!(d::DateField, s::AbstractString)
    d.buffer = String(s)
    parsed = tryparse(Date, d.buffer)
    parsed === nothing || (d.menu_date = parsed)
    d
end

# Alias so call sites that use Tachikoma.set_text! (TextInput) keep working.
function Tachikoma.set_text!(d::DateField, s::AbstractString)
    set_date_text!(d, s)
end

function _df_open_menu!(d::DateField)
    parsed = tryparse(Date, strip(d.buffer))
    d.menu_date = parsed === nothing ? Dates.today() : parsed
    d.menu_open = true
    d
end

function Tachikoma.handle_key!(d::DateField, evt::KeyEvent)::Bool
    if d.menu_open
        if evt.key === :left
            d.menu_date -= Day(1); return true
        elseif evt.key === :right
            d.menu_date += Day(1); return true
        elseif evt.key === :up
            d.menu_date -= Day(7); return true
        elseif evt.key === :down
            d.menu_date += Day(7); return true
        elseif evt.key === :enter || (evt.key === :char && evt.char == ' ')
            d.buffer = string(d.menu_date)
            d.menu_open = false
            return true
        elseif evt.key === :escape
            d.menu_open = false
            return true
        end
        return false
    end
    # menu closed
    if evt.key === :char && evt.char == ' '
        _df_open_menu!(d); return true
    elseif evt.key === :backspace
        isempty(d.buffer) && return true
        d.buffer = d.buffer[1:prevind(d.buffer, lastindex(d.buffer))]
        return true
    elseif evt.key === :delete || evt.key === :home || evt.key === :end ||
           evt.key === :left || evt.key === :right
        # no internal cursor yet; swallow navigation so it doesn't leak to the form
        return true
    elseif evt.key === :char
        ch = evt.char
        # Manual entry: accept any printable (digits/hyphen for YYYY-MM-DD, plus
        # letters so a bad format can be typed and the save path can warn).
        if isprint(ch) && ch != '\t'
            d.buffer *= string(ch)
            return true
        end
    end
    false
end

function Tachikoma.render(d::DateField, rect::Rect, buf::Buffer)
    rect.width < 1 && return
    shown = isempty(d.buffer) ? "(none)" : d.buffer
    hint = d.focused && !d.menu_open ? "  [Spc calendar]" : (d.menu_open ? "  [calendar…]" : "")
    line = fit_width(shown * hint, rect.width)
    st = d.focused ? Style(; fg = col_primary_hi(), bold = true) :
         (isempty(d.buffer) ? Style(; fg = col_text_muted()) : Style(; fg = col_text()))
    set_string!(buf, rect.x, rect.y, line, st)
    d.menu_open || return
    # Calendar grid below the value line when the rect is tall enough; otherwise
    # still draw a compact month header on the next row if height ≥ 2.
    _render_date_menu!(d, rect, buf)
end

"""Render a compact month grid starting one row under `rect.y` when space allows."""
function _render_date_menu!(d::DateField, rect::Rect, buf::Buffer)
    rect.height < 2 && return
    y0 = rect.y + 1
    x0 = rect.x
    w = rect.width
    md = d.menu_date
    first_of_month = Date(year(md), month(md), 1)
    # Monday=1 … Sunday=7 in Dates; we want Sun-first grid → shift
    # dayofweek: Mon=1 .. Sun=7. Columns Su=0 .. Sa=6.
    lead = mod(dayofweek(first_of_month), 7)   # Sun→0, Mon→1, … Sat→6
    days_in = daysinmonth(md)
    header = fit_width(Dates.format(md, "U yyyy"), w)
    set_string!(buf, x0, y0, header, Style(; fg = col_primary(), bold = true))
    y0 + 1 > rect.y + rect.height - 1 && return
    dow = fit_width("Su Mo Tu We Th Fr Sa", w)
    set_string!(buf, x0, y0 + 1, dow, Style(; fg = col_text_dim()))
    row = y0 + 2
    col = lead
    for day in 1:days_in
        row > rect.y + rect.height - 1 && break
        cell_x = x0 + col * 3
        cell_x + 2 > x0 + w && (row += 1; col = 0; cell_x = x0; row > rect.y + rect.height - 1 && break)
        label = lpad(string(day), 2)
        is_sel = day == Dates.day(md)
        st = is_sel ? Style(; fg = col_bg(), bg = col_primary(), bold = true) :
             Style(; fg = col_text())
        set_string!(buf, cell_x, row, fit_width(label, max(1, x0 + w - cell_x)), st)
        col += 1
        if col >= 7
            col = 0
            row += 1
        end
    end
end
