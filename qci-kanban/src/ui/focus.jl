# ═══════════════════════════════════════════════════════════════════════
# ui/focus.jl — the no-conflict focus core.
#
# `FocusState` wraps Tachikoma's `FocusRing` (next!/prev!/current) plus a
# single `active` flag that answers "does an editor currently own input?".
# There are NO per-field guard flags anywhere else in v2 — this is the single
# source of truth. `route_to_focus!` implements step 1 of the DESIGN.md
# dispatch order: a focused editor swallows every printable/editing key; only
# the structural keys (Enter/Esc/Tab/Ctrl) are handed back to the keymap.
# ═══════════════════════════════════════════════════════════════════════

# `using Tachikoma` (in QciKanban.jl) provides FocusRing, next!, prev!,
# current, handle_key!, KeyEvent.

"""
    FocusState()
    FocusState(editors; active_index=1, active=true)

Track which editor (if any) owns keyboard input. `editors` is an ordered list
of focusable widgets (TextInput/TextArea) that Tab/Shift-Tab cycle through.
Constructing keeps each widget's `.focused` flag in lock-step: exactly the
active editor is focused, all others blurred.
"""
mutable struct FocusState
    editors::Vector{Any}
    ring::FocusRing
    active::Bool
end

FocusState() = FocusState(Any[], FocusRing(Any[]), false)

function FocusState(editors::AbstractVector; active_index::Integer = 1, active::Bool = true)
    eds = Any[editors...]
    ring = FocusRing(eds)
    if !isempty(eds)
        ring.active = clamp(Int(active_index), 1, length(eds))
    end
    fs = FocusState(eds, ring, active && !isempty(eds))
    _sync_focus_flags!(fs)
    fs
end

"Keep every editor's `.focused` flag consistent with the active selection."
function _sync_focus_flags!(fs::FocusState)
    cur = isempty(fs.editors) ? nothing : fs.ring.items[fs.ring.active]
    for ed in fs.editors
        if hasproperty(ed, :focused)
            ed.focused = fs.active && (ed === cur)
        end
    end
    fs
end

"The editor currently owning input, or `nothing`."
focused_editor(fs::FocusState) =
    (fs.active && !isempty(fs.editors)) ? current(fs.ring) : nothing

function focus_next!(fs::FocusState)
    isempty(fs.editors) && return nothing
    next!(fs.ring); fs.active = true; _sync_focus_flags!(fs)
    current(fs.ring)
end

function focus_prev!(fs::FocusState)
    isempty(fs.editors) && return nothing
    prev!(fs.ring); fs.active = true; _sync_focus_flags!(fs)
    current(fs.ring)
end

function focus_index!(fs::FocusState, i::Integer)
    isempty(fs.editors) && return fs
    fs.ring.active = clamp(Int(i), 1, length(fs.editors))
    fs.active = true
    _sync_focus_flags!(fs)
    fs
end

"Blur all editors — no editor owns input; keys fall through to the keymap."
function blur!(fs::FocusState)
    fs.active = false
    _sync_focus_flags!(fs)
    fs
end

"""
    route_to_focus!(fs, evt) -> Symbol

Step 1 of the dispatch order. Returns:
- `:consumed`    — the event was handled by the focused editor (printable char,
                   backspace, arrows, delete, home/end) or by Tab/Shift-Tab
                   focus cycling. Nothing else must run.
- `:structural`  — a focused editor exists but the key (Enter/Esc/Ctrl-combo)
                   is reserved for the keymap; the caller dispatches it.
- `:fallthrough` — no editor is focused; the caller runs the keymap normally.

The contract: while an editor is focused, ANY printable char (digits included)
mutates only that editor's text — never a view/global shortcut.
"""
function route_to_focus!(fs::FocusState, evt::KeyEvent)::Symbol
    ed = focused_editor(fs)
    ed === nothing && return :fallthrough
    if evt.key === :tab
        focus_next!(fs); return :consumed
    elseif evt.key === :backtab
        focus_prev!(fs); return :consumed
    elseif evt.key === :enter || evt.key === :escape ||
           evt.key === :ctrl || evt.key === :ctrl_c
        return :structural
    else
        handle_key!(ed, evt)
        return :consumed
    end
end
