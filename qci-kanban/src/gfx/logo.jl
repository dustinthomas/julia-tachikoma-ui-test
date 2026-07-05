# ═══════════════════════════════════════════════════════════════════════
# gfx/logo.jl — Phase 5 QCI logo for the v2 login screen + header.
#
# Layered rendering, all three layers sharing the SAME layout footprint so the
# surrounding view geometry (and every TestBackend assertion) is deterministic:
#
#   (a) PIXEL   — PixelCanvas via the kitty/sixel graphics protocol, used only
#                 when `graphics_protocol()` reports a capable terminal. This is
#                 the sole pixel-protocol-only glue (COV_EXCL): under TestBackend
#                 `graphics_protocol()` is always `gfx_none`, so it never runs.
#   (b) CANVAS  — braille/BlockCanvas pixel-art wordmark (QCI_MARK_BITMAP,
#                 rasterized from branding/qci-logo-ref.png) drawn dot-by-dot.
#                 This is what renders under TestBackend; the `QCI • KANBAN`
#                 tagline below it is always emitted so `find_text`/`row_text`
#                 can assert the branding.
#   (c) TEXT    — tiny-size fallback: just the centered tagline (or "QCI").
#
# QCI cyan glow is a cheap, animation-gated pulse (color_lerp primary→primary_hi)
# that only runs when `animations_enabled()`; with animations off (as in tests)
# the output is byte-for-byte deterministic.
#
# Colors go through Theming accessors only — no raw ColorRGB literals here.
# ═══════════════════════════════════════════════════════════════════════

using .Theming
using Tachikoma: color_lerp

"Centered branding tagline drawn under every logo layer (assertable text)."
const LOGO_TAGLINE = "QCI • KANBAN"

"Braille spinner frames for the subtle login-submit animation."
const SPINNER_FRAMES = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')

"""
    spinner_glyph(tick) -> Char

Deterministic spinner frame for `tick` (pure; used only when animations are on).
"""
spinner_glyph(tick::Integer) = SPINNER_FRAMES[mod1(Int(tick) + 1, length(SPINNER_FRAMES))]

# ── Pixel-art mark: the QCi wordmark as a filled bitmap ──────────────────────
# Rasterized from the official wordmark (branding/qci-logo-ref.png): filled
# rounded Q with counter + diagonal tail notch, open C with angled terminal,
# lowercase i with detached square dot. '#' = dot on; all rows are 58 chars.
const QCI_MARK_BITMAP = [
    "      ##############               ################  #####",
    "    ###################         ###################  #####",
    "   #####################       ####################  #####",
    "  #######################     #####################  #####",
    " #########################   ######################  #####",
    " #######           #######  ########                      ",
    "#######             ######  #######                  #####",
    "######               ###### ######                   #####",
    "######               ###### ######                   #####",
    "######               ###### ######                   #####",
    "######                ##### ######                   #####",
    "#######      ########  ###  #######                  #####",
    " #######      ########  ##   #######                 #####",
    " ######################      ######################  #####",
    "  ######################      #####################  #####",
    "   #######################     ####################  #####",
    "    #######################     ###################  #####",
    "       #####################       ################  #####",
]

"""
    _mark_dots(dw, dh) -> Vector{NTuple{2,Int}}

Pure scaler: 0-based dot coordinates drawing `QCI_MARK_BITMAP` centered in a
`dw`×`dh` dot grid. Upscaling snaps to an integer factor so pixel edges stay
crisp; downscaling max-pools (any '#' in the source block lights the dot) so
strokes survive small header sizes. Returns no dots when the grid can't hold
a legible mark.
"""
function _mark_dots(dw::Int, dh::Int)
    dots = NTuple{2,Int}[]
    bw = length(QCI_MARK_BITMAP[1])
    bh = length(QCI_MARK_BITMAP)
    (dw < 8 || dh < 4) && return dots
    s = min(dw / bw, dh / bh)
    if s >= 1.0
        si = floor(Int, s)
        x0 = (dw - bw * si) ÷ 2
        y0 = (dh - bh * si) ÷ 2
        for by in 1:bh, bx in 1:bw
            QCI_MARK_BITMAP[by][bx] == '#' || continue
            for py in 0:(si - 1), px in 0:(si - 1)
                push!(dots, (x0 + (bx - 1) * si + px, y0 + (by - 1) * si + py))
            end
        end
    else
        ow = max(1, floor(Int, bw * s))
        oh = max(1, floor(Int, bh * s))
        x0 = (dw - ow) ÷ 2
        y0 = (dh - oh) ÷ 2
        for ty in 0:(oh - 1)
            sy0 = ty * bh ÷ oh + 1
            sy1 = max(sy0, (ty + 1) * bh ÷ oh)
            for tx in 0:(ow - 1)
                sx0 = tx * bw ÷ ow + 1
                sx1 = max(sx0, (tx + 1) * bw ÷ ow)
                lit = any(QCI_MARK_BITMAP[sy][sx] == '#' for sy in sy0:sy1, sx in sx0:sx1)
                lit && push!(dots, (x0 + tx, y0 + ty))
            end
        end
    end
    dots
end

"Memo for `_mark_dots` — the glow path redraws the mark every animation tick."
const _MARK_DOTS_MEMO = Dict{NTuple{2,Int},Vector{NTuple{2,Int}}}()

"Draw the QCi pixel-art wordmark into `c` (Canvas / BlockCanvas / PixelCanvas)."
function _draw_qci_mark!(c)
    clear!(c)
    dw, dh = canvas_dot_size(c)
    for (dx, dy) in get!(() -> _mark_dots(dw, dh), _MARK_DOTS_MEMO, (dw, dh))
        set_point!(c, dx, dy)
    end
    c
end

# ── Layer (a): pixel protocol (COV_EXCL — never runs under TestBackend) ──────
# COV_EXCL_START
function _render_pixel_logo!(buf::Buffer, area::Rect)
    c = PixelCanvas(area.width, area.height; style = Style(; fg = col_primary()))
    _draw_qci_mark!(c)
    f = Frame(buf, area, GraphicsRegion[], PixelSnapshot[])
    render_canvas(c, area, f)
    nothing
end
# COV_EXCL_STOP

# ── Layer (b): braille / block canvas mark (renders under TestBackend) ───────
function _render_canvas_logo!(buf::Buffer, area::Rect; tick::Int = 0)
    c = create_canvas(area.width, area.height; style = Style(; fg = col_primary()))
    _draw_qci_mark!(c)
    f = Frame(buf, area, GraphicsRegion[], PixelSnapshot[])
    render_canvas(c, area, f)
    # Cyan glow pulse — animation-gated (skipped when animations are off).
    if animations_enabled()
        t = clamp(0.5 + 0.5 * sin(tick / 4.0), 0.0, 1.0)
        gc = create_canvas(area.width, area.height;
                           style = Style(; fg = color_lerp(col_primary(), col_primary_hi(), t)))
        _draw_qci_mark!(gc)
        render_canvas(gc, area, f)
    end
    nothing
end

"""
    render_qci_logo_v2!(buf, area; tick=0) -> Symbol

Render the layered QCI logo into `area`, returning the layer used
(`:pixel` | `:canvas` | `:text` | `:none`). The `QCI • KANBAN` tagline is drawn
on the last row for every non-tiny layer so branding text is always assertable.
"""
function render_qci_logo_v2!(buf::Buffer, area::Rect; tick::Int = 0)
    (area.width < 3 || area.height < 1) && return :none

    # (c) tiny fallback: no room for a mark — center the tagline (or "QCI").
    if area.height < 3 || area.width < 12
        txt = area.width >= length(LOGO_TAGLINE) ? LOGO_TAGLINE : "QCI"
        tx = area.x + max(0, (area.width - length(txt)) ÷ 2)
        set_string!(buf, tx, area.y, txt, Style(; fg = col_primary(), bold = true))
        return :text
    end

    mark_area = Rect(area.x, area.y, area.width, area.height - 1)
    layer = :canvas
    if graphics_protocol() != gfx_none                    # COV_EXCL_START
        try
            _render_pixel_logo!(buf, mark_area)
            layer = :pixel
        catch
            _render_canvas_logo!(buf, mark_area; tick = tick)
        end                                                # COV_EXCL_STOP
    else
        _render_canvas_logo!(buf, mark_area; tick = tick)
    end

    tag_y = area.y + area.height - 1
    tx = area.x + max(0, (area.width - length(LOGO_TAGLINE)) ÷ 2)
    set_string!(buf, tx, tag_y, LOGO_TAGLINE, Style(; fg = col_primary_hi(), bold = true))
    # Subtle spinner accent beside the tagline (animation-gated, deterministic).
    if animations_enabled() && tx - 2 >= area.x
        set_string!(buf, tx - 2, tag_y, string(spinner_glyph(tick)), Style(; fg = col_primary()))
    end
    layer
end
