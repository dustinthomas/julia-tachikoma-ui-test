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
    if evt.key === :left || evt.key === :up
        ms.cursor = mod1(ms.cursor - 1, n); return true
    elseif evt.key === :right || evt.key === :down
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
    x = rect.x + length(ms.label) + 1
    maxx = rect.x + rect.width
    if isempty(ms.options)
        set_string!(buf, x, rect.y, "(none)", Style(; fg = col_text_muted()))
        return
    end
    for i in eachindex(ms.options)
        mark = ms.checked[i] ? "☑" : "☐"
        chip = "$(mark)$(ms.options[i]) "
        x + length(chip) > maxx && break
        st = if ms.focused && i == ms.cursor
            sel_style()
        elseif ms.checked[i]
            Style(; fg = col_primary())
        else
            Style(; fg = col_text_dim())
        end
        set_string!(buf, x, rect.y, chip, st)
        x += length(chip)
    end
end
