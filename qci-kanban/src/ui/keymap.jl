# ═══════════════════════════════════════════════════════════════════════
# ui/keymap.jl — declarative bindings: (context, key) → action symbol.
#
# The keymap is DATA. Help overlays and status-bar hints are GENERATED from
# this table, so they can never drift from what the app actually does. Steps
# 2–4 of the DESIGN.md dispatch order (modal → view → global) are expressed as
# a context stack passed to `lookup_action`.
# ═══════════════════════════════════════════════════════════════════════

# `using Tachikoma` provides KeyEvent.

"""
    Binding(context, token, action, label, help, hint)

One keymap row. `token` is the normalized key (see `key_token`): a `Char` for
printable keys, a `Symbol` for named keys (`:enter`, `:escape`, `:ctrl_c`, …),
or a `(:ctrl, char)` tuple for Ctrl-combos. `label`/`help` feed the generated
help + status hints; `hint=true` surfaces the binding in the status bar.
"""
struct Binding
    context::Symbol
    token::Any
    action::Symbol
    label::String
    help::String
    hint::Bool
end

"""
    key_token(evt) -> Char | Symbol | Tuple{Symbol,Char}

Normalize a KeyEvent into the hashable token used as a keymap key.
"""
function key_token(evt::KeyEvent)
    if evt.key === :char
        return evt.char
    elseif evt.key === :ctrl
        return (:ctrl, evt.char)
    else
        return evt.key
    end
end

# ── The table ────────────────────────────────────────────────────────────
const KEYMAP = Binding[
    # Global (post-login; the fallthrough context under every view).
    Binding(:global, 'q',          :quit,          "q",     "Quit",            true),
    Binding(:global, :ctrl_c,      :quit,          "^C",    "Quit",            false),
    Binding(:global, '?',          :toggle_help,   "?",     "Help",            true),
    Binding(:global, 'B',          :view_board,    "B",     "Board",           true),
    Binding(:global, 'K',          :view_backlog,  "K",     "Backlog",         true),
    Binding(:global, 'C',          :view_calendar, "C",     "Calendar",        true),
    Binding(:global, 'G',          :view_gantt,    "G",     "Gantt",           true),
    Binding(:global, (:ctrl, 'l'), :logout,        "^L",    "Log out",         true),

    # Login — sign in (email + password). Printable chars are captured by the
    # focused editor before this table is consulted; 'c' only reaches here on
    # the first-run zero-user screen (no editor focused).
    Binding(:login, :enter,        :login_submit,     "Enter", "Sign in",         true),
    Binding(:login, 'c',           :login_to_create,  "c",     "Create account",  true),
    Binding(:login, (:ctrl, 'n'),  :login_to_create,  "^N",    "Create account",  false),
    Binding(:login, 'q',           :quit,             "q",     "Quit",            true),
    Binding(:login, :ctrl_c,       :quit,             "^C",    "Quit",            false),

    # Login — create account (email + name + password).
    Binding(:login_create, :enter,   :create_submit,    "Enter", "Create & sign in", true),
    Binding(:login_create, :escape,  :login_to_signin,  "Esc",   "Back to sign in",  true),
    Binding(:login_create, :ctrl_c,  :quit,             "^C",    "Quit",             false),

    # Help modal (consumes everything; standalone context).
    Binding(:help, :escape, :close_help, "Esc", "Close help", true),
    Binding(:help, '?',     :close_help, "?",   "Close help", true),

    # ── Board view ─────────────────────────────────────────────────────────
    # NOTE: 'K' (rank up) intentionally shadows the global 'K' (Backlog view)
    # while on the board — view bindings beat global by design. Backlog stays
    # reachable from every other view via 'K'.
    Binding(:board, 'h',   :nav_left,       "h",   "Left",             true),
    Binding(:board, 'l',   :nav_right,      "l",   "Right",            true),
    Binding(:board, 'j',   :nav_down,       "j",   "Down",             true),
    Binding(:board, 'k',   :nav_up,         "k",   "Up",               true),
    Binding(:board, :left,  :nav_left,      "←",   "Left",             false),
    Binding(:board, :right, :nav_right,     "→",   "Right",            false),
    Binding(:board, :down,  :nav_down,      "↓",   "Down",             false),
    Binding(:board, :up,    :nav_up,        "↑",   "Up",               false),
    Binding(:board, 's',   :cycle_swimlane, "s",   "Swimlanes",        true),
    Binding(:board, 't',   :toggle_stats,   "t",   "Stats",            true),
    Binding(:board, 'n',   :new_card,       "n",   "New card",         true),
    Binding(:board, 'e',   :edit_card,      "e",   "Edit",             true),
    Binding(:board, 'd',   :delete_card,    "d",   "Delete",           true),
    Binding(:board, 'v',   :view_card,      "v",   "Details",          true),
    Binding(:board, :enter, :view_card,     "Enter", "Details",        false),
    Binding(:board, 'a',   :assign_me,      "a",   "Assign me",        true),
    Binding(:board, '<',   :move_prev,      "<",   "Move ←",           true),
    Binding(:board, '>',   :move_next,      ">",   "Move →",           true),
    Binding(:board, 'J',   :rank_down,      "J",   "Rank down",        false),
    Binding(:board, 'K',   :rank_up,        "K",   "Rank up",          false),
    Binding(:board, ' ',   :toggle_select,  "Spc", "Select",           true),
    Binding(:board, 'M',   :bulk_move,      "M",   "Bulk move",        false),
    Binding(:board, 'A',   :bulk_assign,    "A",   "Bulk assign",      false),
    Binding(:board, 'D',   :bulk_delete,    "D",   "Bulk delete",      false),
    Binding(:board, '/',   :open_search,    "/",   "Search",           true),
    Binding(:board, 'm',   :filter_mine,    "m",   "Filter mine",      false),
    Binding(:board, 'H',   :filter_high,    "H",   "Filter high",      false),
    Binding(:board, 'u',   :filter_due,     "u",   "Filter due-soon",  false),
    Binding(:board, 'p',   :filter_sprint,  "p",   "Filter sprint",    false),
    Binding(:board, '#',   :cycle_label_filter, "#", "Label filter",   false),

    # ── Backlog view ─────────────────────────────────────────────────────────
    Binding(:backlog, 'j',   :backlog_down,        "j",     "Down",         true),
    Binding(:backlog, 'k',   :backlog_up,          "k",     "Up",           true),
    Binding(:backlog, :down, :backlog_down,        "↓",     "Down",         false),
    Binding(:backlog, :up,   :backlog_up,          "↑",     "Up",           false),
    Binding(:backlog, 'n',   :new_sprint,          "n",     "New sprint",   true),
    Binding(:backlog, '>',   :move_to_sprint,      ">",     "→ sprint",     true),
    Binding(:backlog, '<',   :move_to_backlog,     "<",     "→ backlog",    true),
    Binding(:backlog, 'S',   :start_sprint,        "S",     "Start sprint", true),
    Binding(:backlog, 'X',   :close_sprint,        "X",     "Close sprint", true),
    Binding(:backlog, 'v',   :backlog_view_card,   "v",     "Details",      true),
    Binding(:backlog, :enter,:backlog_view_card,   "Enter", "Details",      false),
    Binding(:backlog, 'e',   :backlog_edit_card,   "e",     "Edit",         true),
    Binding(:backlog, 'd',   :backlog_delete_card, "d",     "Delete",       true),

    # ── Calendar view ──────────────────────────────────────────────────────
    Binding(:calendar, 'h',    :cal_prev_month, "h",     "Prev month",   true),
    Binding(:calendar, 'l',    :cal_next_month, "l",     "Next month",   true),
    Binding(:calendar, :left,  :cal_prev_month, "←",     "Prev month",   false),
    Binding(:calendar, :right, :cal_next_month, "→",     "Next month",   false),
    Binding(:calendar, 'j',    :cal_day_next,   "j",     "Next day",     true),
    Binding(:calendar, 'k',    :cal_day_prev,   "k",     "Prev day",     true),
    Binding(:calendar, :down,  :cal_day_next,   "↓",     "Next day",     false),
    Binding(:calendar, :up,    :cal_day_prev,   "↑",     "Prev day",     false),
    Binding(:calendar, 'n',    :cal_new,        "n",     "New (due=sel)", true),
    Binding(:calendar, 'v',    :cal_view_card,  "v",     "Details",      true),
    Binding(:calendar, :enter, :cal_view_card,  "Enter", "Details",      false),

    # ── Gantt view ─────────────────────────────────────────────────────────
    Binding(:gantt, 'h',    :gantt_scroll_left,  "h",     "Scroll ←",   true),
    Binding(:gantt, 'l',    :gantt_scroll_right, "l",     "Scroll →",   true),
    Binding(:gantt, :left,  :gantt_scroll_left,  "←",     "Scroll ←",   false),
    Binding(:gantt, :right, :gantt_scroll_right, "→",     "Scroll →",   false),
    Binding(:gantt, 'j',    :gantt_row_next,     "j",     "Next row",   true),
    Binding(:gantt, 'k',    :gantt_row_prev,     "k",     "Prev row",   true),
    Binding(:gantt, :down,  :gantt_row_next,     "↓",     "Next row",   false),
    Binding(:gantt, :up,    :gantt_row_prev,     "↑",     "Prev row",   false),
    Binding(:gantt, 'z',    :gantt_zoom,         "z",     "Zoom day/wk/mo", true),
    Binding(:gantt, 'v',    :gantt_view_card,    "v",     "Details",    true),
    Binding(:gantt, :enter, :gantt_view_card,    "Enter", "Details",    false),

    # ── Card detail modal (comment box focused; Enter submits, Esc closes) ──
    Binding(:card_detail, :enter,  :submit_comment, "Enter", "Add comment", true),
    Binding(:card_detail, :escape, :close_card,     "Esc",   "Close",       true),

    # ── Card create/edit modal ─────────────────────────────────────────────
    # Ctrl+S always saves (works from the multi-line Desc field, where Enter
    # inserts a newline). Enter also saves from any single-line field.
    Binding(:card_edit, (:ctrl, 's'), :save_edit,  "^S",    "Save",   true),
    Binding(:card_edit, :enter,  :edit_enter, "Enter", "Newline/Save", true),
    Binding(:card_edit, :escape, :close_card, "Esc",   "Cancel", true),

    # ── Confirm modal ──────────────────────────────────────────────────────
    Binding(:confirm, 'y',     :confirm_yes, "y",   "Yes",    true),
    Binding(:confirm, :enter,  :confirm_yes, "Enter", "Yes",  false),
    Binding(:confirm, 'n',     :confirm_no,  "n",   "No",     true),
    Binding(:confirm, :escape, :confirm_no,  "Esc", "No",     false),

    # ── Search modal ───────────────────────────────────────────────────────
    Binding(:search, :enter,  :apply_search, "Enter", "Apply", true),
    Binding(:search, :escape, :clear_search, "Esc",   "Clear", true),

    # ── New-sprint modal ───────────────────────────────────────────────────
    Binding(:new_sprint, :enter,  :submit_new_sprint, "Enter", "Create", true),
    Binding(:new_sprint, :escape, :close_card,        "Esc",   "Cancel", true),
]

const _KEYMAP_INDEX = let d = Dict{Tuple{Symbol,Any},Binding}()
    for b in KEYMAP
        d[(b.context, b.token)] = b
    end
    d
end

"All bindings declared for a single context, in table order."
bindings_for(context::Symbol) = Binding[b for b in KEYMAP if b.context == context]

"""
    lookup_action(context, evt) -> Symbol | nothing
    lookup_action(contexts, evt) -> Symbol | nothing

Resolve the action for `evt`. The vector form walks the context stack
most-specific-first (e.g. `[:board, :global]`), returning the first match.
"""
function lookup_action(context::Symbol, evt::KeyEvent)
    b = get(_KEYMAP_INDEX, (context, key_token(evt)), nothing)
    b === nothing ? nothing : b.action
end

function lookup_action(contexts::AbstractVector{Symbol}, evt::KeyEvent)
    for c in contexts
        a = lookup_action(c, evt)
        a === nothing || return a
    end
    nothing
end

"""
    help_lines(contexts) -> Vector{String}

Human-readable help rows generated from the table, in context-stack order.
"""
function help_lines(contexts::AbstractVector{Symbol})
    lines = String[]
    for c in contexts
        for b in bindings_for(c)
            push!(lines, rpad(b.label, 6) * "  " * b.help)
        end
    end
    lines
end

"""
    status_hints(contexts) -> String

Compact " [key] Help " string for the status bar, deduplicated, in
context-stack order. Only bindings with `hint=true` are shown.
"""
function status_hints(contexts::AbstractVector{Symbol}; editors_focused::Bool = false)
    parts = String[]
    seen = Set{String}()
    for c in contexts, b in bindings_for(c)
        b.hint || continue
        # When a text editor owns input, printable-char shortcuts type into the
        # field rather than firing — so they must NOT be advertised (finding U3).
        # Structural keys (Enter/Esc/Ctrl-combos) still reach the keymap.
        (editors_focused && b.token isa Char) && continue
        s = "[$(b.label)] $(b.help)"
        if !(s in seen)
            push!(parts, s)
            push!(seen, s)
        end
    end
    join(parts, "  ")
end
