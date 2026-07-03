# ═══════════════════════════════════════════════════════════════════════════
# QCI Canvas Logos for Tachikoma.jl
#
# Creative, vector-graphic QCI logomarks implemented using Tachikoma's
# Canvas / BlockCanvas / PixelCanvas graphics (see docs on Canvas).
#
# These are *drawn* using the primitives described at:
# https://kahliburke.github.io/Tachikoma.jl/dev/canvas
#   - create_canvas, canvas_dot_size
#   - arc!, line!, rect!, set_point!, clear!
#   - render_canvas(canvas, area, frame)
#
# Redone to stay true to Raleway font (elegant geometric sans-serif):
#   - Q: round bowl + classic thin diagonal tail stroke (not a cut)
#   - C: open with nearly horizontal terminals
#   - I: clean straight vertical bar
# Proportions, weight and spacing follow Raleway display style.
#
# See branding/qci-logo-raleway.svg and qci-logo-raleway*.png for references.
# Cyan + Navy digital/tech aesthetic preserved for TUI use.
#
# Usage (in any view(m, f) ):
#   logo_area = ...  # a Rect from split_layout
#   c = create_canvas(logo_area.width, logo_area.height;
#                     style = Style(; fg = QCI_CYAN))
#   draw_qci_logo_vector!(c)
#   render_canvas(c, logo_area, f)
#
# Different variants give different "feels": clean vector, tech grid,
# layered neon, emblem with kanban motif.
# All are scalable to the canvas size.
#
# Works with braille (universal), BlockCanvas (denser), or PixelCanvas
# (high res if terminal supports).
# ═══════════════════════════════════════════════════════════════════════════

using Tachikoma

export draw_qci_logo_vector!, draw_qci_logo_tech!,
       draw_qci_logo_neon!, draw_qci_logo_emblem!,
       qci_logo_canvas, render_qci_logo_canvas

# ───────────────────────────────────────────────────────────────────────────
# Core drawing helper — draws QCI in a style true to Raleway font.
# Raleway is an elegant geometric sans-serif: clean round bowls, precise
# diagonal tail on Q, open C with horizontal terminals, simple vertical I.
# Proportions, weight and spacing are adjusted to feel like Raleway.
# ───────────────────────────────────────────────────────────────────────────
function _draw_qci_core!(c; style_scale::Float64 = 1.0)
    clear!(c)
    dw, dh = canvas_dot_size(c)
    cx = dw ÷ 2
    cy = dh ÷ 2

    # Scale so the logo fits with breathing room (Raleway-like proportions)
    s = min(dw, dh) / 50.0 * style_scale

    # Q — left: round bowl + classic Raleway-style diagonal tail
    q_cx = round(Int, cx - dw * 0.17)
    q_r = round(Int, 13.0 * s)

    # Bowl (nearly full circle, elegant round)
    arc!(c, q_cx, cy, q_r, -15.0, 200.0; steps=52)
    # Slight inner for weight
    if q_r > 6
        arc!(c, q_cx, cy, max(4, q_r-2), -10.0, 195.0; steps=44)
    end

    # Raleway Q tail: diagonal stroke from lower-right of bowl going down-right
    tail_start_x = round(Int, q_cx + q_r * 0.65)
    tail_start_y = round(Int, cy + q_r * 0.55)
    tail_end_x   = round(Int, q_cx + q_r * 1.25)
    tail_end_y   = round(Int, cy + q_r * 1.15)
    line!(c, tail_start_x, tail_start_y, tail_end_x, tail_end_y)
    # Slight parallel for stroke weight (Raleway elegance)
    line!(c, tail_start_x+1, tail_start_y+1, tail_end_x+1, tail_end_y+1)

    # C — center-right, open with more horizontal terminals like Raleway
    c_cx = round(Int, cx + dw * 0.01)
    c_r  = round(Int, q_r * 0.90)
    # Arc with terminals closer to horizontal
    arc!(c, c_cx, cy, c_r, -80.0, 260.0; steps=48)
    if c_r > 6
        arc!(c, c_cx, cy, max(3, c_r-2), -75.0, 255.0; steps=42)
    end

    # I — right: clean vertical bar (Raleway I is minimal and elegant)
    i_cx  = round(Int, cx + dw * 0.20)
    i_top = round(Int, cy - dh * 0.20)
    i_bot = round(Int, cy + dh * 0.20)

    # Main stem
    line!(c, i_cx, i_top, i_cx, i_bot)
    # Subtle weight
    line!(c, i_cx+1, i_top, i_cx+1, i_bot)

    # Minimal top and bottom accents (small horizontal for presence, keeping sans feel)
    for dx in -1:1
        set_point!(c, i_cx + dx, i_top)
        set_point!(c, i_cx + dx, i_bot)
    end
end

# ───────────────────────────────────────────────────────────────────────────
# Variant 1: Clean Vector (directly echoes qci-logo-ref.png + clean PNGs)
# Precise, minimal, high-end tech mark.
# ───────────────────────────────────────────────────────────────────────────
function draw_qci_logo_vector!(c)
    _draw_qci_core!(c; style_scale = 1.0)
end

# ───────────────────────────────────────────────────────────────────────────
# Variant 2: Tech / Grid (inspired by qci-logo-tech.png)
# Core mark + fine digitized grid + "data" points + subtle construction lines.
# Feels like a HUD or engineering schematic.
# ───────────────────────────────────────────────────────────────────────────
function draw_qci_logo_tech!(c)
    _draw_qci_core!(c; style_scale = 1.15)

    dw, dh = canvas_dot_size(c)

    # Subtle background grid (low density so it doesn't fight the logo)
    gstep_x = max(3, dw ÷ 18)
    gstep_y = max(2, dh ÷ 14)
    for x in gstep_x:gstep_x:dw-2
        for y in 1:2:dh-1
            # Only draw where not too close to center logo mass (rough mask)
            if abs(x - dw/2) > dw*0.12 || abs(y - dh/2) > dh*0.18
                set_point!(c, x, y)
            end
        end
    end

    # "Data stream" dots tracing a path near the notch — creative digital touch
    nx = round(Int, dw * 0.55)
    ny = round(Int, dh * 0.62)
    for i in 0:5
        set_point!(c, nx + i*2, ny + round(Int, sin(i*0.9)*1.5))
        if i % 2 == 0
            set_point!(c, nx + i*2 + 1, ny + 2)
        end
    end

    # Thin construction / alignment marks at corners (very light tech framing)
    for off in (3, 5)
        set_point!(c, off, off)
        set_point!(c, dw - off, off)
        set_point!(c, off, dh - off)
        set_point!(c, dw - off, dh - off)
    end
end

# ───────────────────────────────────────────────────────────────────────────
# Variant 3: Neon / Layered Glow (based on cyan-glow and ref-cyan PNGs)
# Multiple offset passes create a soft glowing / neon-tube effect.
# Works especially well with bright cyan on dark backgrounds.
# ───────────────────────────────────────────────────────────────────────────
function draw_qci_logo_neon!(c)
    dw, dh = canvas_dot_size(c)
    cx = dw ÷ 2
    cy = dh ÷ 2
    s  = min(dw, dh) / 48.0

    # Glow "halo" layers first (outer)
    # We draw slightly larger / offset versions before the crisp core
    q_cx = round(Int, cx - dw * 0.16)
    q_r  = round(Int, 12.8 * s)

    # Outer glow ring (larger arc)
    arc!(c, q_cx, cy, round(Int, q_r * 1.18), 15.0, 345.0; steps=36)
    arc!(c, q_cx + 1, cy + 1, round(Int, q_r * 1.1), 20.0, 340.0; steps=30)

    c_cx = round(Int, cx + dw * 0.02)
    c_r  = round(Int, q_r * 0.95)
    arc!(c, c_cx, cy, round(Int, c_r * 1.15), -75.0, 255.0; steps=30)

    # Now the sharp core on top
    _draw_qci_core!(c; style_scale = 1.0)

    # Extra inner "hot" highlight on the notch for glow pop
    n1x = round(Int, q_cx + q_r * 0.48)
    n1y = round(Int, cy + q_r * 0.18)
    n2x = round(Int, q_cx + q_r * 1.12)
    n2y = round(Int, cy + q_r * 0.82)
    line!(c, n1x, n1y, n2x, n2y)
    set_point!(c, n1x + 2, n1y + 2)
end

# ───────────────────────────────────────────────────────────────────────────
# Variant 4: Emblem / Kanban (qci-logo-kanban + creative board motif)
# Full QCI mark + stylized kanban "columns" as graphic elements.
# The five thin verticals evoke the five board columns.
# ───────────────────────────────────────────────────────────────────────────
function draw_qci_logo_emblem!(c)
    _draw_qci_core!(c; style_scale = 1.1)

    dw, dh = canvas_dot_size(c)

    # Five stylized kanban columns below / integrated under the mark
    # (thin vertical lines spaced evenly)
    base_y1 = round(Int, dh * 0.72)
    base_y2 = round(Int, dh * 0.88)
    col_spacing = max(3, round(Int, dw / 9))
    start_x = round(Int, dw * 0.22)

    for i in 0:4
        x = start_x + i * col_spacing
        # Column bar
        line!(c, x, base_y1, x, base_y2)
        # Small "card" accent on a couple columns (creative detail)
        if i == 1 || i == 3
            rect!(c, x-1, base_y1+1, x+1, base_y1 + 4)
        end
    end

    # Small connecting "flow" line under everything — digital ribbon
    flow_y = base_y2 + 2
    if flow_y < dh - 1
        line!(c, round(Int, dw*0.18), flow_y, round(Int, dw*0.82), flow_y)
    end
end

# ───────────────────────────────────────────────────────────────────────────
# Variant 5: TERMINAL / Chunky pixel (direct adaptation of QCI Terminal.jpg)
# Heavy filled blocks + internal structure + cursor stair accent.
# Uses rects for "pixels" to give authentic chunky retro terminal presence.
# Good on BlockCanvas / when you want the JPG vibe in graphics mode.
# ───────────────────────────────────────────────────────────────────────────
function draw_qci_logo_terminal!(c)
    clear!(c)
    dw, dh = canvas_dot_size(c)

    # Compute tight bounding box for the three chunky letters
    # Proportions chosen to echo the wide pixel letters in the JPG
    margin = max(1, dw ÷ 12)
    lx = margin
    lw = max(8, (dw - margin*2) ÷ 3)
    spacing = max(2, (dw - margin*2 - 3*lw) ÷ 2)

    letter_h = max(5, dh - 3)
    top = max(1, (dh - letter_h) ÷ 2)

    fill_sty_points = true  # we use rects + set_point for fill + detail

    function chunky_letter!(base_x, letter::Char)
        # outer block
        w = lw
        h = letter_h
        # main body rect (thick)
        rect!(c, base_x, top, base_x + w - 1, top + h - 1)
        # inner detail / notch simulation (like the ▄▄▄ area in Q)
        if letter == 'Q'
            # notch / bowl inner
            inx = base_x + w ÷ 3
            iny = top + h ÷ 3
            rect!(c, inx, iny, base_x + w*2÷3, top + h*2÷3)
            # tail stair suggestion (bottom right protrusion)
            set_point!(c, base_x + w - 1, top + h - 2)
            set_point!(c, base_x + w , top + h - 1)
            # the "cursor" white stair hint (small dots at bottom-left of Q area)
            cx = base_x + w ÷ 2
            cy = top + h - 1
            set_point!(c, cx-1, cy)
            set_point!(c, cx, cy-1)
            set_point!(c, cx+1, cy-2)
        elseif letter == 'C'
            # open the right side (hollow a vertical strip)
            for yy in (top+1):(top+h-2)
                set_point!(c, base_x + w - 2, yy)  # punch to create C opening
            end
        elseif letter == 'I'
            # I is a strong vertical with subtle caps
            # already filled; add weight at ends
            for dx in -1:1
                set_point!(c, base_x + w÷2 + dx, top)
                set_point!(c, base_x + w÷2 + dx, top + h - 1)
            end
        end
    end

    chunky_letter!(lx , 'Q')
    chunky_letter!(lx + lw + spacing, 'C')
    chunky_letter!(lx + 2*(lw + spacing), 'I')

    # subtle scanline / green edge accents simulated via points (caller color decides tone)
    for x in (lx-1):(lx + 3*lw + 2*spacing)
        if x >= 0 && x < dw
            set_point!(c, x, top-1)
            set_point!(c, x, top + letter_h)
        end
    end
end

# ───────────────────────────────────────────────────────────────────────────
# Convenience: create a ready-to-render canvas with a chosen logo variant
# ───────────────────────────────────────────────────────────────────────────
const _VARIANT_MAP = Dict(
    :vector => draw_qci_logo_vector!,
    :tech   => draw_qci_logo_tech!,
    :neon   => draw_qci_logo_neon!,
    :emblem => draw_qci_logo_emblem!,
    :terminal => draw_qci_logo_terminal!,
)

function qci_logo_canvas(width::Int, height::Int;
                         variant::Symbol = :vector,
                         style = Style(; fg = ColorRGB(0, 188, 212)))   # QCI_CYAN default
    c = create_canvas(width, height; style = style)
    fn = get(_VARIANT_MAP, variant, draw_qci_logo_vector!)
    fn(c)
    return c
end

# Helper to render one of the logos directly (common pattern)
function render_qci_logo_canvas(buf_or_frame, area::Rect;
                                variant::Symbol = :vector,
                                style = Style(; fg = ColorRGB(0, 188, 212)))
    c = qci_logo_canvas(area.width, area.height; variant=variant, style=style)
    # render_canvas works with Frame (f). If you only have buf you may need to wrap.
    # Most real views pass the frame.
    render_canvas(c, area, buf_or_frame)
end

# Example standalone usage (paste into a test or demo):
#
# using Tachikoma
# tb = TestBackend(60, 16)
# c = qci_logo_canvas(30, 8; variant=:tech, style=Style(; fg=QCI_CYAN))
# # then in real code: render_canvas(c, some_area, frame)
# # For pure inspection you can also just look at the canvas dots.

# (loaded silently — use the draw_* functions or qci_logo_canvas)
