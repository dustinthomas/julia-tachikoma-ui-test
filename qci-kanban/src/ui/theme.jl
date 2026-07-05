# ═══════════════════════════════════════════════════════════════════════
# ui/theme.jl — the QCI palette (single source of truth).
#
# Wrapped by `module Theming` in QciKanban.jl. This is the ONLY file under
# src/ui/ permitted to contain raw `ColorRGB(...)` literals — a test greps the
# rest of src/ui/ to enforce that every other view file goes through these
# semantic accessors. Palette is the finalized table from DESIGN.md
# "Theme (final)".
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma: ColorRGB, Style

export col_bg, col_surface, col_surface_hi, col_primary, col_primary_hi
export col_text, col_text_dim, col_text_muted, col_ok, col_warn, col_err
export sel_style, priority_color, epic_color
export QCI_CYAN, QCI_NAVY, QCI_SECONDARY

# ── Palette constants (DESIGN.md "Theme (final)") ────────────────────────
const BG          = ColorRGB(13, 17, 33)     # app background wash
const SURFACE     = ColorRGB(24, 28, 52)     # cards, modals
const SURFACE_HI  = ColorRGB(30, 32, 75)     # raised / selected surfaces (QCI navy)
const PRIMARY     = ColorRGB(0, 188, 212)    # QCI cyan — borders, titles, accents
const PRIMARY_HI  = ColorRGB(77, 216, 235)   # hover / active accent
const TEXT        = ColorRGB(230, 237, 243)  # primary text
const TEXT_DIM    = ColorRGB(140, 150, 180)  # secondary text
const TEXT_MUTED  = ColorRGB(100, 110, 165)  # hints, inactive
const OK          = ColorRGB(78, 204, 94)    # success, Low priority
const WARN        = ColorRGB(240, 198, 116)  # warnings, Medium priority
const ERR         = ColorRGB(224, 60, 49)    # errors, High priority, overdue

# Epic tag 5-color cycle: violet / teal / orange / pink / blue.
const EPIC_RAMP = (
    ColorRGB(155, 110, 240),  # violet
    ColorRGB(0, 188, 160),    # teal
    ColorRGB(240, 150, 70),   # orange
    ColorRGB(240, 110, 180),  # pink
    ColorRGB(80, 140, 240),   # blue
)

# ── Semantic accessors ───────────────────────────────────────────────────
col_bg()         = BG
col_surface()    = SURFACE
col_surface_hi() = SURFACE_HI
col_primary()    = PRIMARY
col_primary_hi() = PRIMARY_HI
col_text()       = TEXT
col_text_dim()   = TEXT_DIM
col_text_muted() = TEXT_MUTED
col_ok()         = OK
col_warn()       = WARN
col_err()        = ERR

"Selection style: QCI cyan on navy, bold."
sel_style() = Style(; fg = PRIMARY, bg = SURFACE_HI, bold = true)

"""
    priority_color(p) -> ColorRGB

Priority → semantic color: High=err(red), Medium=warn(amber), Low=ok(green).
Anything else falls back to dim text.
"""
function priority_color(p::AbstractString)
    p == "High"   && return ERR
    p == "Medium" && return WARN
    p == "Low"    && return OK
    return TEXT_DIM
end

"""
    epic_color(i) -> ColorRGB

Stable epic tag color from the 5-color ramp. Accepts a 1-based index or a
string id/key (hashed into the ramp).
"""
epic_color(i::Integer) = EPIC_RAMP[mod1(Int(i), length(EPIC_RAMP))]
function epic_color(s::AbstractString)
    isempty(s) && return EPIC_RAMP[1]
    epic_color(1 + (Int(sum(codeunits(s))) % length(EPIC_RAMP)))
end

# ── v1 compatibility aliases (keep QciKanban.QCI_* semantics available) ───
const QCI_CYAN      = PRIMARY
const QCI_NAVY      = SURFACE_HI
const QCI_SECONDARY = TEXT_MUTED
