# ═══════════════════════════════════════════════════════════════════════════
# QCI Terminal Logos for Tachikoma.jl
#
# Digitized + stylized QCI logomarks meant to be rendered directly
# in the terminal using Tachikoma's Buffer (set_string!).
#
# The designs are inspired by the custom mark in branding/bg-light-top-right.png:
# - Distinctive Q with angular notch / cut on the lower-right of the bowl
# - Bold geometric C and I (square i-dot suggestion via weight)
#
# Pick a variant and color it with QCI_CYAN / QCI_NAVY at render time.
# ═══════════════════════════════════════════════════════════════════════════

# Small (header / top bar)
const QCI_LOGO_SMALL = """
 ████ ███ █
█    █ █  █
 ████  █  █
"""

# Primary medium logo — good balance of size and personality.
# The Q has an internal "notch" (▄▄▄ area + right side shaping).
const QCI_LOGO_MEDIUM = """
  ██████  
 █      █ 
█        █
█   ▄▄▄  █
█     █  █
 █    █ █ 
  ████  █ 
"""

# Stronger notch, more "constructed".
const QCI_LOGO_MEDIUM2 = """
   ██████ 
  █     ██
 █       █
 █   ▄▄▄ █
  █    █ █
   █   █ █
    ███  █
"""

# Digital / HUD style with inner lines suggesting data or pixels.
const QCI_LOGO_DIGITAL = """
  ▄████▄  
 ██    ██ 
█   ░░   █
█  ▄▄▄▄  █
 ██    ██ 
  ▀████▀ █
         █
"""

# Clean outline / wireframe digitized feel.
const QCI_LOGO_OUTLINE = """
  ▄▄▄▄▄▄  
 ▀      ▀ 
▀        ▀
▀  ▄▄▄▄  ▀
 ▀      ▀ 
  ▀    ▀  
   ▀▀▀▀  ▀
"""

# Heavy solid block version — great presence on dark screens.
const QCI_LOGO_HEAVY = """
  ██████  
 ████████ 
██ ████ ██
██      ██
 ████████ 
  ██████  █
"""

# QCI + KANBAN subtitle. Use for splash / about / first run screens.
const QCI_LOGO_KANBAN = """
  ██████  
 █      █ 
█        █
█   ▄▄▄  █
█     █  █
 █    █ █ 
  ████  █ 
K A N B A N
"""

# Compact pixel / low-res digital.
const QCI_LOGO_PIXEL = """
█▀▀█ █▀▀█ █
█  █ █  █ █
█▄▄█ █▄▄█ █
"""

# Mini tech / segmented style (very compact).
const QCI_LOGO_HUD = """
█▀▀▀▀█ █▀▀█ █
█    █ █  █ █
█▄▄▄▄█ █▄▄█ █
"""

const QCI_LOGO_MINI = "QCI"

# ───────────────────────────────────────────────────────────────────────────
# TERMINAL / RETRO style — direct adaptation of branding/QCI Terminal.jpg
# Chunky pixel-block letters with notched personality, purple/blue body
# + green highlight edges in spirit (rendered via style in caller).
# Includes the signature white staircase cursor accent under the Q.
# Use for splash, login gate headers, or demo recordings.
# ───────────────────────────────────────────────────────────────────────────
const QCI_LOGO_TERMINAL = """
  ██████    ██████    ████
 █      █  █      █  █    █
█        █ █      █ █      █
█   ▄▄▄  █ █      █ █      █
█     █  █ █      █ █      █
 █    █ █   █    █   █    █
  ████  █    ████     ████ 
         ▄██
        ██  
"""

# Compact terminal for tight logo areas (still chunky)
const QCI_LOGO_TERMINAL_SMALL = """
 ████ ████ ███
█   ██   █  █
█ ▄▄ █   █  █
█    █  █   █
 ████  ██  ██ 
   ▀▀
"""

const ALL_QCI_LOGOS = [
    ("mini",    QCI_LOGO_MINI),
    ("small",   QCI_LOGO_SMALL),
    ("medium",  QCI_LOGO_MEDIUM),
    ("medium2", QCI_LOGO_MEDIUM2),
    ("digital", QCI_LOGO_DIGITAL),
    ("outline", QCI_LOGO_OUTLINE),
    ("heavy",   QCI_LOGO_HEAVY),
    ("kanban",  QCI_LOGO_KANBAN),
    ("pixel",   QCI_LOGO_PIXEL),
    ("hud",     QCI_LOGO_HUD),
    ("terminal", QCI_LOGO_TERMINAL),
    ("terminal_small", QCI_LOGO_TERMINAL_SMALL),
]

function render_qci_logo(buf, logo::AbstractString, x::Int, y::Int; style = nothing)
    for (i, line) in enumerate(split(logo, '\n'; keepempty=false))
        if style === nothing
            set_string!(buf, x, y + i - 1, line)
        else
            set_string!(buf, x, y + i - 1, line, style)
        end
    end
end

# Centering helper (returns the x you should pass to render_qci_logo)
function center_logo_x(logo::AbstractString, area_x::Int, area_width::Int)
    lines = split(logo, '\n'; keepempty=false)
    w = isempty(lines) ? 0 : maximum(length, lines)
    area_x + max(0, (area_width - w) ÷ 2)
end
