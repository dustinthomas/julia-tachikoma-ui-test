# ═══════════════════════════════════════════════════════════════════════
# QciKanban — QCI Jira-Inspired Kanban TUI (Tachikoma)
#
# Self-contained sub-project. Run with: julia --project=qci-kanban ...
#
# Elm-style: mutable struct <: Model, should_quit, update!, view.
# Full TestBackend required for all UI (AGENTS.md).
#
# Branding: QCI navy + cyan from branding/bg-light-top-right.png
# Logo: stylized block-art QCI mark (digitized/notched) + tag. See QCI_LOGO_ART and branding/qci-terminal-logos.jl.
# The default art is adapted from branding/QCI Terminal.jpg (chunky terminal pixel style).
# ═══════════════════════════════════════════════════════════════════════

module QciKanban

using Tachikoma
using Dates
using UUIDs
using Base64
@tachikoma_app

include("db.jl")
using .DB

# ── QCI Kanban v2 core infrastructure (Phase 1; no UI) ───────────────────
# Self-contained submodules; do not collide with the v1 DB module or the
# existing update!/view code. See DESIGN.md / PHASES.md.
module Domain
    include("domain.jl")
end

module Config
    include("config.jl")
end

module Passwords
    include("auth/password.jl")
end

module Stores
    using ..Domain, ..Config, ..Passwords
    include("store/interface.jl")
    include("store/sqlite_store.jl")
    include("store/remote_store.jl")
end

module Auth
    using ..Domain, ..Config, ..Passwords, ..Stores
    include("auth/jwt.jl")
    include("auth/session.jl")
    # Auth is the single entry point for password primitives too.
    using ..Passwords: PasswordHash, hash_password, verify_password, constant_time_eq
    export PasswordHash, hash_password, verify_password, constant_time_eq
end

module Notify
    using ..Domain, ..Config, ..Stores
    include("notify/interface.jl")
    include("notify/outbox.jl")
    include("notify/smtp.jl")
end

# ── QCI Kanban v2 UI shell (Phase 2) ─────────────────────────────────────
# Palette lives in its own submodule (named Theming to avoid clashing with
# Tachikoma's exported `Theme` type). The focus router, keymap and app shell
# are included at QciKanban top level so they share Tachikoma's widget names
# and extend the same update!/view/should_quit generics as v1.
module Theming
    include("ui/theme.jl")
end

include("ui/focus.jl")     # FocusState + route_to_focus!
include("ui/keymap.jl")    # Binding table + lookup_action/help/hints
include("ui/widgets.jl")   # Selector / MultiSelect form widgets (before app: field-adjacent)
include("ui/app.jl")       # AppModel, update!/view/should_quit, kanban2
include("ui/board.jl")     # Phase 3: swimlane grid, rich cards, board ops, filters, WIP
include("ui/backlog.jl")   # Phase 3: backlog list + sprint lifecycle
include("ui/modals.jl")    # Phase 3: card detail / edit / confirm / search / new-sprint modals
include("ui/calendar.jl")  # Phase 4: month calendar view (due marks, day drill-down)
include("ui/gantt.jl")     # Phase 4: Gantt timeline (BlockCanvas bars, today marker, sprint bands)
include("gfx/logo.jl")     # Phase 5: layered QCI logo (pixel/canvas/text)
include("gfx/charts.jl")   # Phase 5: board stats strip + sprint burndown

# QCI branding (copied from ai_metrics_dashboard patterns for consistency)
const QCI_CYAN = ColorRGB(UInt8(0), UInt8(188), UInt8(212))
const QCI_NAVY = ColorRGB(UInt8(30), UInt8(32), UInt8(75))
const QCI_SECONDARY = ColorRGB(UInt8(100), UInt8(110), UInt8(165))  # lighter navy for unselected/secondary text (contrast on black)

export QCI_CYAN, QCI_NAVY, QCI_SECONDARY

# PR2+ rich cards: priority glyphs and colors for 1-line badges (Jira style)
const PRIORITY_GLYPHS = Dict(
    "High" => "▌",
    "Medium" => "▌",
    "Low" => "▌"
)
const PRIORITY_COLORS = Dict(
    "High" => ColorRGB(0xe0, 0x3c, 0x31),   # red
    "Medium" => ColorRGB(0xf0, 0xc6, 0x74), # amber
    "Low" => ColorRGB(0x4e, 0xcc, 0x5e)     # green
)

# Stylized QCI mark for terminal (digitized block art).
# Direct adaptation of the chunky pixel / retro terminal style from
# branding/QCI Terminal.jpg (purple body + green accents in spirit, + cursor).
# See also branding/qci-terminal-logos.jl for variants (QCI_LOGO_TERMINAL etc).
const QCI_LOGO_ART = """
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

# Optional richer graphic logos using Tachikoma Canvas (graphics & pixel section).
# Robust path using @__DIR__ so it works from any cwd.
try
    include(joinpath(@__DIR__, "..", "..", "branding", "qci-canvas-logos.jl"))
catch err
    # silent fallback — the text art QCI_LOGO_ART will be used
end

export DB  # for advanced use / tests

using SQLite   # for DB type hints in model (optional)

# Simple runtime column definition for board
const BOARD_COLUMNS = ["Backlog", "To Do", "In Progress", "Review", "Done"]

@kwdef mutable struct KanbanModel <: Model
    quit::Bool = false
    tick::Int = 0
    db_path::String = DB.DEFAULT_DB_PATH
    db::Union{SQLite.DB, Nothing} = nothing
    # Board data
    cards_by_status::Dict{String, Vector{Dict{String,Any}}} = Dict{String,Vector{Dict{String,Any}}}()
    # Selection
    selected_col::Int = 1
    selected_idx::Int = 1
    # UI
    view_mode::Symbol = :board   # :board | :calendar | :list
    message::String = ""
    search::String = ""
    search_input::TextInput = TextInput(; focused = false)
    active_filters::Set{String} = Set{String}()  # "High", "Due Soon", "Mine" for PR4 quick filters
    wip_limits::Dict{String,Int} = Dict("Backlog"=>0, "To Do"=>5, "In Progress"=>3, "Review"=>3, "Done"=>0)  # PR5 WIP limits, light config
    swimlane_by::Symbol = :none  # PR7 :none | :priority | :assignee
    selected_ids::Set{String} = Set{String}()  # PR7 bulk multi select scoped
    # Modal / edit (Phase 3)
    modal::Symbol = :none          # :none | :card_edit | :user_picker | :help
    editing_id::Union{String,Nothing} = nothing
    edit_title::TextInput = TextInput()
    edit_desc::TextArea = TextArea()
    edit_priority::String = "Medium"
    # Users (Phase 4)
    current_user_id::Union{String,Nothing} = nothing
    users::Vector{Dict{String,Any}} = Dict{String,Any}[]
    user_selected::Int = 1
    # Calendar (Phase 5)
    cal::Union{Calendar, Nothing} = nothing
    cal_selected_day::Int = Dates.day(Dates.today())
    # Login create + JWT + admin (for ACs)
    login_name::TextInput = TextInput()
    jwt_token::Union{String,Nothing} = nothing
end

# ── Board loading (Phase 2) ─────────────────────────────────────────────

function ensure_db!(m::KanbanModel)
    if m.db === nothing
        m.db = DB.open_db(m.db_path)
        DB.seed_demo!(m.db)
    end
end

function load_board!(m::KanbanModel)
    ensure_db!(m)
    empty!(m.cards_by_status)
    for status in BOARD_COLUMNS
        m.cards_by_status[status] = DB.list_issues(m.db; status=status)
    end
    load_users!(m)
    # clamp selection
    m.selected_col = clamp(m.selected_col, 1, length(BOARD_COLUMNS))
    n = length(get(m.cards_by_status, BOARD_COLUMNS[m.selected_col], []))
    m.selected_idx = clamp(m.selected_idx, 1, max(1, n))
    sync_calendar!(m)
    m.message = "loaded $(sum(length(v) for v in values(m.cards_by_status))) cards"
end

function sync_calendar!(m::KanbanModel)
    d = Dates.today()
    year, mon = Dates.year(d), Dates.month(d)
    marked = Set{Int}()
    for cards in values(m.cards_by_status), c in cards
        ds = get(c, "due_date", nothing)
        if ds !== nothing && !ismissing(ds)
            try
                dd = Date(string(ds))
                if Dates.year(dd) == year && Dates.month(dd) == mon
                    push!(marked, Dates.day(dd))
                end
            catch; end
        end
    end
    m.cal = Calendar(year, mon; today = Dates.day(d), marked = marked)
    m.cal_selected_day = Dates.day(d)
end

function load_users!(m::KanbanModel)
    ensure_db!(m)
    m.users = DB.list_users(m.db)
    # Do NOT auto-assign current_user_id here. Login gate requires explicit selection from initial state.
    # (load_board! calls this; gate logic and kanban() defer board until after login.)
end

function open_user_picker!(m::KanbanModel)
    load_users!(m)
    m.modal = :user_picker
    m.user_selected = 1
end

function wipe_test_users!(m::KanbanModel)
    ensure_db!(m)
    DB.wipe_test_users!(m.db)
    m.users = DB.list_users(m.db)
    m.user_selected = 1
end

function select_current_user!(m::KanbanModel)
    if !isempty(m.users)
        idx = clamp(m.user_selected, 1, length(m.users))
        u = m.users[idx]
        m.current_user_id = u["id"]
        m.jwt_token = jwt_encode(u["id"], get(u, "name", ""))
    end
    m.modal = :none
end

# Move selected card left/right (status) or within column (reorder)
function move_selected!(m::KanbanModel, dir::Symbol)
    ensure_db!(m)
    cols = BOARD_COLUMNS
    cidx = clamp(m.selected_col, 1, length(cols))
    status = cols[cidx]
    cards = get(m.cards_by_status, status, [])
    idx = clamp(m.selected_idx, 1, length(cards))
    isempty(cards) && return

    card = cards[idx]
    id = card["id"]

    if dir == :left && cidx > 1
        new_status = cols[cidx-1]
        target_cards = get(m.cards_by_status, new_status, [])
        new_pos = length(target_cards) + 1
        DB.update_issue_status_and_position!(m.db, id, new_status, new_pos)
        load_board!(m)
        m.selected_col = cidx - 1
        newc = get(m.cards_by_status, new_status, [])
        m.selected_idx = clamp(length(newc), 1, max(1, length(newc)))
        m.message = "moved → $(new_status)"
    elseif dir == :right && cidx < length(cols)
        new_status = cols[cidx+1]
        target_cards = get(m.cards_by_status, new_status, [])
        new_pos = length(target_cards) + 1
        DB.update_issue_status_and_position!(m.db, id, new_status, new_pos)
        load_board!(m)
        m.selected_col = cidx + 1
        newc = get(m.cards_by_status, new_status, [])
        m.selected_idx = clamp(length(newc), 1, max(1, length(newc)))
        m.message = "moved → $(new_status)"
    elseif dir == :up && idx > 1
        prev_card = cards[idx-1]
        DB.update_issue_status_and_position!(m.db, id, status, prev_card["position"])
        DB.update_issue_status_and_position!(m.db, prev_card["id"], status, card["position"])
        load_board!(m)
        newc = get(m.cards_by_status, status, [])
        m.selected_idx = clamp(idx - 1, 1, max(1, length(newc)))
        m.message = "reordered ↑"
    elseif dir == :down && idx < length(cards)
        next_card = cards[idx+1]
        DB.update_issue_status_and_position!(m.db, id, status, next_card["position"])
        DB.update_issue_status_and_position!(m.db, next_card["id"], status, card["position"])
        load_board!(m)
        newc = get(m.cards_by_status, status, [])
        m.selected_idx = clamp(idx + 1, 1, max(1, length(newc)))
        m.message = "reordered ↓"
    end
    # final clamp for safety (empty cols, Backlog edge)
    c = clamp(m.selected_col, 1, length(cols))
    nc = get(m.cards_by_status, cols[c], [])
    m.selected_col = c
    m.selected_idx = clamp(m.selected_idx, 1, max(1, length(nc)))
end

function open_edit_modal!(m::KanbanModel; new::Bool=false)
    ensure_db!(m)
    m.modal = :card_edit
    if new
        m.editing_id = nothing
        m.edit_title = TextInput(; focused=true)
        m.edit_desc = TextArea(; focused=false)
        m.edit_priority = "Medium"
        m.message = "NEW CARD"
    else
        cols = BOARD_COLUMNS
        cidx = clamp(m.selected_col, 1, length(cols))
        cards = get(m.cards_by_status, cols[cidx], [])
        idx = clamp(m.selected_idx, 1, length(cards))
        isempty(cards) && return
        card = cards[idx]
        m.editing_id = card["id"]
        m.edit_title = TextInput(text = get(card, "title", ""); focused = true)
        desc = get(card, "description", "")
        m.edit_desc = TextArea(text = desc; focused = false)
        m.edit_priority = get(card, "priority", "Medium")
        m.message = "EDIT $(get(card,"key",""))"
    end
end

function save_modal!(m::KanbanModel)
    title = strip(text(m.edit_title))
    isempty(title) && (m.modal = :none; return)

    desc = text(m.edit_desc)
    prio = m.edit_priority

    if m.editing_id === nothing
        # create
        ensure_db!(m)
        new_id = DB.create_issue!(m.db; title=title, description=desc, status="Backlog", priority=prio,
                                   assignee_id = m.current_user_id, position=999)
        load_board!(m)
        # select the new one in Backlog (col 1 per kanban-func-plan)
        m.selected_col = 1
        bl = get(m.cards_by_status, "Backlog", [])
        m.selected_idx = max(1, length(bl))
        m.message = "created $(get(DB.get_issue(m.db, new_id), "key", ""))"
    else
        DB.update_issue!(m.db, m.editing_id; title=title, description=desc, priority=prio)
        load_board!(m)
        m.message = "saved"
    end
    m.modal = :none
    m.editing_id = nothing
end

function close_modal!(m::KanbanModel)
    m.modal = :none
    m.editing_id = nothing
end

function delete_selected!(m::KanbanModel)
    ensure_db!(m)
    cols = BOARD_COLUMNS
    cidx = clamp(m.selected_col, 1, length(cols))
    cards = get(m.cards_by_status, cols[cidx], [])
    idx = clamp(m.selected_idx, 1, length(cards))
    isempty(cards) && return
    id = cards[idx]["id"]
    DB.delete_issue!(m.db, id)
    load_board!(m)
    m.selected_idx = clamp(m.selected_idx, 1, max(1, length(get(m.cards_by_status, cols[cidx], []))))
    m.message = "deleted"
end

# Screen-relevant key tips for bottom of non-modal screens (side-effect free, testable directly)
function screen_key_tips(view_mode::Symbol)
    if view_mode == :board
        "h/l j/k < > n Enter d u ?"
    elseif view_mode == :calendar
        "h/l mo j/k b ?"
    else
        "b c L ?"
    end
end

# Minimal JWT-shaped token (no real crypto; for future DB hook simulation per plan)
function jwt_encode(user_id::AbstractString, name::AbstractString)::String
    hdr = replace(String(base64encode("""{"alg":"none","typ":"JWT"}""")), "=" => "")
    pay = replace(String(base64encode("""{"sub":"$user_id","name":"$name"}""")), "=" => "")
    sig = replace(String(base64encode("local")), "=" => "")
    "$hdr.$pay.$sig"
end

# Pure helper: filter cards by case-insensitive contains on title or key.
# Returns all (copy) when query empty/stripped. Preserves input order. No side effects.
function apply_filters_and_sort(cards::Vector{Dict{String,Any}}, query::AbstractString)
    apply_filters_and_sort(cards, query, Set{String}(), nothing)
end

function apply_filters_and_sort(cards::Vector{Dict{String,Any}}, query::AbstractString, active_filters::Set{String}, current_user_id::Union{String,Nothing})
    q = strip(query)
    res = copy(cards)
    if !isempty(q)
        ql = lowercase(q)
        res = [c for c in res if occursin(ql, lowercase(get(c, "title", ""))) || occursin(ql, lowercase(get(c, "key", "")))]
    end
    if "High" in active_filters
        res = [c for c in res if get(c, "priority", "") == "High"]
    end
    if "Due Soon" in active_filters
        today = Dates.today()
        res = [c for c in res if begin
            ds = get(c, "due_date", nothing)
            if ds === nothing || ismissing(ds); false
            else
                try
                    dd = Date(string(ds))
                    dd <= today + Dates.Day(7) && dd >= today - Dates.Day(1)
                catch; false end
            end
        end]
    end
    if "Mine" in active_filters && current_user_id !== nothing
        res = [c for c in res if get(c, "assignee_id", nothing) == current_user_id]
    end
    res
end

# Pure function for swimlane grouping (for PR7)
function group_cards_by_swimlane(cards_by_status::Dict{String,Vector{Dict{String,Any}}}, swimlane_by::Symbol)::Vector{Pair{String,Vector{Dict{String,Any}}}}
    groups = Dict{String, Vector{Dict{String,Any}}}()
    for (status, cards) in cards_by_status
        for c in cards
            rawkey = if swimlane_by == :priority
                get(c, "priority", "Medium")
            else
                get(c, "assignee_id", "unassigned")
            end
            key = string(rawkey)  # ensure String key (assignee_id may be missing in data)
            if !haskey(groups, key)
                groups[key] = []
            end
            push!(groups[key], c)
        end
    end
    collect(groups)
end

# Pure planner for gate modal layout. Enforces invariants so render cannot violate containment.
# Returns rect sized to fit, and exact (y, text) for each line strictly inside the inner area.
function plan_gate_modal_layout(content_area, body_lines::Vector{String}, hint_text::String = "")
    # AC1 prompt must NEVER be truncated. Prioritize its width requirement over hint and ca limits for the rect.
    is_prompt = !isempty(body_lines) && occursin("No users", body_lines[1])
    p = is_prompt ? length(body_lines[1]) : 0
    prompt_needed = is_prompt ? (p + 2) : 0   # at least borders around the exact prompt

    all_lines = vcat(body_lines, isempty(hint_text) ? String[] : [hint_text])
    max_line_w = maximum(length(l) for l in all_lines; init=20)
    needed_w = max_line_w + 4
    base_w = content_area.width <= 50 ? max(30, content_area.width - 2) : max(30, content_area.width - 6)
    w = min( max(base_w, needed_w), content_area.width )
    w = min(w, 58)

    n_b = length(body_lines)
    n_h = isempty(hint_text) ? 0 : 1
    min_h = 4 + n_b + n_h
    h = min( max(min_h, 7), content_area.height )
    if content_area.height > 15
        h = min(h, 11)
    end
    if content_area.height < 15
        h = content_area.height
    end
    h = max(h, min_h)

    x = content_area.x + (content_area.width - w) ÷ 2
    offset = max(1, (content_area.height - h) ÷ 4)
    y = content_area.y + offset
    r = Rect(x, y, w, h)

    # Force for full AC1 prompt (shipped string must appear complete inside borders on all sizes incl 40x12)
    if is_prompt && w < prompt_needed
        w = prompt_needed
        # On narrow frames, align left (x=1) to give maximum usable width for the prompt + borders
        x = max(1, content_area.x - (w - content_area.width) ÷ 2)
        r = Rect(x, y, w, h)
    end

    # Also ensure the *passed* hint (short on narrow, long on wide) is not truncated in plan.hint_row / render
    if !isempty(hint_text)
        needed_for_hint = length(hint_text) + 2
        if w < needed_for_hint
            w = needed_for_hint
            x = max(1, content_area.x - (w - content_area.width) ÷ 2)
            r = Rect(x, y, w, h)
        end
    end

    inner_first = r.y + 1
    inner_last = r.y + r.height - 3
    avail = max(0, w - 2)

    body_rows = Tuple{Int,String}[]
    cur = inner_first
    for bl in body_lines
        if cur > inner_last; break; end
        if is_prompt && bl == body_lines[1]
            s = bl  # never truncate the exact AC1 prompt
        else
            s = length(bl) > avail ? bl[1:avail] : bl
        end
        push!(body_rows, (cur, s))
        cur += 1
    end

    hint_r = nothing
    if !isempty(hint_text)
        hy = inner_last
        hs = length(hint_text) > avail ? hint_text[1:avail] : hint_text
        hint_r = (hy, hs)
    end

    (rect = r, body_rows = body_rows, hint_row = hint_r)
end

# Unified gate modal layout (compat wrapper around planner)
function gate_modal_rect(content_area; n_body_lines::Int = 0, hint::Bool = true, body_lines::Vector{String}=String[], hint_text::String="")
    if isempty(body_lines) && n_body_lines > 0
        body_lines = ["x" for _ in 1:n_body_lines]  # length only for budget
    end
    if hint && isempty(hint_text)
        hint_text = "x"  # length only
    end
    plan = plan_gate_modal_layout(content_area, body_lines, hint_text)
    r = plan.rect
    hy = plan.hint_row !== nothing ? plan.hint_row[1] : r.y + r.height - 2
    (rect = r, hint_y = hy, inner_y = r.y + 1, inner_bottom = r.y + r.height - 2)
end

function render_gate_modal!(buf, content_area, title; body_lines::Vector{String} = String[], hint_text::String = "")
    plan = plan_gate_modal_layout(content_area, body_lines, hint_text)
    r = plan.rect
    # clear under the rect
    for yy in r.y:(r.y + r.height - 1)
        set_string!(buf, r.x, yy, repeat(" ", r.width))
    end
    blk = Block(title=title, border_style=Style(; fg=QCI_CYAN), title_style=Style(; fg=QCI_CYAN, bold=true))
    inn = render(blk, r, buf)
    # Center the txt (body + hint) inside the LOGIN modal rect (r-based inner for visual center in box).
    # Use r (our allocated modal) inner so test expected matches and text is centered regardless of Block inn offset.
    for (yy, line) in plan.body_rows
        cx = r.x + 1 + (r.width - 2 - length(line)) ÷ 2
        set_string!(buf, cx, yy, line, Style(; fg=QCI_SECONDARY))
    end
    if plan.hint_row !== nothing
        hy, ht = plan.hint_row
        cx = r.x + 1 + (r.width - 2 - length(ht)) ÷ 2
        set_string!(buf, cx, hy, ht, Style(; fg=QCI_CYAN, dim = true))
    end
end

"""
    render_rich_card!(buf, x, y, card, col_inner, users, is_sel) -> lines_used::Int

PR3 Rich Card Render Contract helper (extracted).
- 2-line when col_inner.width >=20 and height allows (y+1 inside bounds): 
  line1: [prefix] glyph(key colored) key title
  line2:   [avatar] due
- 1-line fallback (narrow col<20 or insufficient height): full glyph+key+title+[a]due minimal.
- Always: overflow guard `if y > bottom(col_inner)-1 return 0`
- Uses PRIORITY_GLYPHS + PRIORITY_COLORS.
- Returns # of y steps taken (1 or 2). Caller does y += delta.
Preserves Elm, col_inner, no-bleed.
"""
function render_rich_card!(buf::Buffer, x::Int, y::Int, card::Dict{String,Any}, col_inner::Rect, users::Vector{Dict{String,Any}}, is_sel::Bool, is_bulk::Bool=false)::Int
    if y > bottom(col_inner) - 1
        return 0
    end
    prefix = (is_bulk ? "*" : "") * (is_sel ? "▶ " : "  ")
    key = get(card, "key", "?")
    title = get(card, "title", "")
    # assignee
    aid = get(card, "assignee_id", nothing)
    a_initial = "·"
    if aid !== nothing && !ismissing(aid)
        au = findfirst(u -> get(u,"id",nothing) == aid, users)
        if au !== nothing
            nm = users[au]["name"]
            a_initial = length(nm) > 0 ? string(first(nm)) : "?"
        end
    end
    due = get(card, "due_date", nothing)
    due_str = (due === nothing || ismissing(due)) ? "" : string(due)
    due_s = isempty(due_str) ? "" : " " * string(last(split(due_str, "-")))
    prio = get(card, "priority", "Medium")
    glyph = get(PRIORITY_GLYPHS, prio, "▌")
    gcol = get(PRIORITY_COLORS, prio, QCI_SECONDARY)
    avail = max(6, col_inner.width - 4)
    sty = is_sel ? Style(; fg = QCI_CYAN, bold = true) : Style(; fg = QCI_SECONDARY)

    col_w = col_inner.width
    can_multi = (col_w >= 20) && (y + 1 <= bottom(col_inner) - 1)
    if can_multi
        # line 1: glyph + key + title (no suffix)
        title_trunc = length(title) > (avail - 3) ? title[1:max(0, avail-4)]*"…" : title
        # draw prefix then colored glyph then rest (order to not clobber glyph)
        set_string!(buf, x, y, prefix, sty)
        set_char!(buf, x + length(prefix), y, glyph[1], Style(; fg = gcol))
        set_string!(buf, x + length(prefix) + 1, y, " " * key * " " * title_trunc, sty)
        y += 1
        if y <= bottom(col_inner) - 1
            line2 = "  [" * a_initial * "]" * due_s
            set_string!(buf, x, y, line2, Style(; fg = QCI_SECONDARY))
            y += 1
            return 2
        end
        return 1
    else
        # 1-line fallback + minimal
        suffix = " [" * a_initial * "]" * due_s
        base = key * " " * (length(title) > (avail - length(suffix) - 1) ? title[1:max(0, avail - length(suffix) - 2)] * "…" : title)
        display = glyph * " " * base * suffix
        if length(display) > avail
            display = display[1:avail-1] * "…"
        end
        set_string!(buf, x, y, prefix, sty)
        set_char!(buf, x + length(prefix), y, glyph[1], Style(; fg = gcol))
        set_string!(buf, x + length(prefix) + 1, y, " " * base * suffix, sty)
        return 1
    end
end

# Extracted exclusive render for columns (PR restructure)
function render_column_board!(buf::Buffer, m::KanbanModel, content_area::Rect, use_bar::Bool)
    n = length(BOARD_COLUMNS)
    col_width = max(14, content_area.width ÷ n)
    constraints = [Fixed(col_width) for _ in 1:n]
    col_areas = split_layout(Layout(Horizontal, constraints), content_area)

    for (i, status) in enumerate(BOARD_COLUMNS)
        ca = i <= length(col_areas) ? col_areas[i] : content_area
        cards = get(m.cards_by_status, status, Dict{String,Any}[])
        displayed = apply_filters_and_sort(cards, m.search, m.active_filters, m.current_user_id)

        lim = get(m.wip_limits, status, 0)
        wip_str = lim > 0 ? "($(length(displayed))/$lim)" : "($(length(displayed)))"
        col_block = Block(
            title = "$status $wip_str",
            border_style = Style(; fg = (i == m.selected_col ? QCI_CYAN : (length(displayed) > lim && lim > 0 ? ColorRGB(0xe0,0x3c,0x31) : QCI_NAVY))),
            title_style = Style(; fg = QCI_CYAN, bold = (i == m.selected_col)),
        )
        col_inner = render(col_block, ca, buf)

        y = col_inner.y + 1
        sel = (i == m.selected_col) ? m.selected_idx : 0
        for (ci, card) in enumerate(displayed)
            if y > bottom(col_inner) - 1
                break
            end
            is_sel = (ci == sel)
            cid = get(card, "id", "")
            is_bulk = cid in m.selected_ids
            delta = render_rich_card!(buf, col_inner.x + 1, y, card, col_inner, m.users, is_sel, is_bulk)
            if delta <= 0
                break
            end
            y += delta
        end

        if isempty(displayed)
            set_string!(buf, col_inner.x + 2, y, "— empty —", Style(; fg = QCI_SECONDARY, dim = true))
        end
    end
end

# Extracted exclusive render for swimlanes (PR restructure)
function render_swimlane_board!(buf::Buffer, m::KanbanModel, content_area::Rect)
    # Apply filters like columns do (address gap: swim must respect search/active_filters, not raw)
    filtered_status = Dict{String,Vector{Dict{String,Any}}}()
    for (st, cs) in m.cards_by_status
        filtered_status[st] = apply_filters_and_sort(cs, m.search, m.active_filters, m.current_user_id)
    end
    groups = group_cards_by_swimlane(filtered_status, m.swimlane_by)
    # stable order for priorities (High first) and deterministic output
    if m.swimlane_by == :priority
        order = ["High", "Medium", "Low"]
        sort!(groups, by = p -> let k=p.first; i=findfirst(==(k), order); i===nothing ? 999 : i end)
    else
        sort!(groups, by = p -> string(p.first))
    end
    # determine current selected id from column state so we can show ▶ even in swim
    current_id = nothing
    cols = BOARD_COLUMNS
    cidx = clamp(m.selected_col, 1, length(cols))
    cards = get(m.cards_by_status, cols[cidx], [])
    if !isempty(cards)
        current_id = cards[clamp(m.selected_idx, 1, length(cards))]["id"]
    end
    y = content_area.y + 1
    for (g, cs) in groups
        if y > bottom(content_area) - 1; break; end
        set_string!(buf, content_area.x + 2, y, "SWIM " * string(m.swimlane_by) * ": " * string(g), Style(; fg = QCI_CYAN))
        y += 1
        for c in cs
            if y > bottom(content_area) - 1; break; end
            cid = get(c, "id", "")
            is_sel = (cid == current_id)
            is_bulk = cid in m.selected_ids
            delta = render_rich_card!(buf, content_area.x + 4, y, c, content_area, m.users, is_sel, is_bulk)
            y += max(delta, 1)
        end
    end
end

should_quit(m::KanbanModel) = m.quit

function update!(m::KanbanModel, evt::KeyEvent)
    if evt.key == :char && evt.char == 'q'
        # Guard against key conflicts: when a text input is focused (login create name,
        # search bar, or card edit title/desc), 'q' must be inserted as a character
        # rather than quitting. This mirrors the fix for 'r' and other mapped letters.
        # Only quit when no input field is consuming the key.
        typing_in_input = false
        if m.modal == :login_create
            typing_in_input = true  # login_name is active during create
        elseif m.search_input.focused
            typing_in_input = true
        elseif m.modal == :card_edit && (m.edit_title.focused || m.edit_desc.focused)
            typing_in_input = true
        end
        if !typing_in_input
            m.quit = true
            return
        end
        # fallthrough: gate create or early input handlers will feed 'q' via handle_key!
    end

    # === LOGIN GATE: when no current_user_id, only 'q' (already handled) + login selection keys allowed ===
    # All other keys (incl. 'r' reload, board nav, card actions, view switches) are ignored; no board load, no current_user set.
    # This enforces the gate before ANY board load (AC4).
    # Extended for create ('c'), admin ('a'/'w' wipe), JWT on auth.
    if m.current_user_id === nothing
        if m.modal == :login_create
            if evt.key == :enter
                name = strip(text(m.login_name))
                if !isempty(name)
                    ensure_db!(m)
                    newid = DB.create_user!(m.db, name)
                    load_users!(m)
                    idx = findfirst(i -> get(m.users[i], "id", "") == newid, 1:length(m.users))
                    if idx !== nothing
                        m.user_selected = idx
                    end
                    select_current_user!(m)
                    load_board!(m)
                    m.login_name = TextInput()
                    m.search_input.focused = false
                    m.search = ""
                    m.message = "created and logged in"
                    return
                else
                    m.modal = :none
                    m.login_name = TextInput()
                    return
                end
            elseif evt.key == :escape
                m.modal = :none
                m.login_name = TextInput()
                return
            else
                if handle_key!(m.login_name, evt)
                    return
                end
                m.tick += 1
                return
            end
        elseif m.modal == :admin
            if (evt.key == :char && evt.char == 'w')
                wipe_test_users!(m)
                return
            elseif evt.key == :escape || (evt.key == :char && evt.char == 'a')
                m.modal = :none
                return
            end
            m.tick += 1
            return
        end
        # normal gated list selection (pre any create/admin)
        nu = length(m.users)
        if nu > 0
            if evt.key == :up || (evt.key == :char && evt.char == 'k')
                m.user_selected = max(1, m.user_selected - 1)
                return
            elseif evt.key == :down || (evt.key == :char && evt.char == 'j')
                m.user_selected = min(nu, m.user_selected + 1)
                return
            elseif evt.key == :enter
                select_current_user!(m)
                load_board!(m)  # now safe to load board/cards after login
                m.search_input.focused = false
                m.search = ""
                m.message = "logged in"
                return
            elseif evt.key == :escape
                # stay gated; do not quit or transition (only 'q' quits)
                m.tick += 1
                return
            end
        else
            # nu==0 first-time branch (per plan): plain :enter, nav, esc leave gate (require 'c' create); no board load
            if evt.key == :enter || evt.key == :up || evt.key == :down ||
               (evt.key == :char && evt.char in ('j','k'))
                m.tick += 1
                return
            elseif evt.key == :escape
                m.tick += 1
                return
            end
        end
        if evt.key == :char && evt.char == 'c'
            m.modal = :login_create
            m.login_name = TextInput(; focused = true)
            return
        elseif evt.key == :char && evt.char == 'a'
            load_users!(m)
            m.modal = :admin
            return
        elseif evt.key == :char && evt.char == 'w'
            wipe_test_users!(m)
            return
        end
        # ignore every other key while gated (no board state mutation, no modals, no view change)
        m.tick += 1
        return
    end

    # === EARLY FOCUSED INPUT CONSUMPTION (fix for key conflicts) ===
    # Offer search_input and card_edit fields the KeyEvent FIRST so printable chars
    # (e.g. 'r' for reload, 'j'/'k' nav, 'b'/'c' views, etc.) type into the widget
    # instead of firing global/board commands. Non-focused paths still reach original branches.
    # This must be immediately post-gate and before 'r', view switches, board nav char ifs.
    if m.search_input.focused
        if evt.key == :escape
            m.search_input.focused = false
            return
        end
        if handle_key!(m.search_input, evt)
            m.search = text(m.search_input)
            return
        end
        m.tick += 1
        return
    end

    if m.modal == :card_edit
        if evt.key == :enter
            save_modal!(m)
            return
        elseif evt.key == :escape
            close_modal!(m)
            return
        elseif evt.key == :tab
            # cycle title <-> desc (consume, do not feed to inputs)
            if m.edit_title.focused
                m.edit_title.focused = false
                m.edit_desc.focused = true
            else
                m.edit_title.focused = true
                m.edit_desc.focused = false
            end
            return
        elseif evt.key == :backtab
            # reverse cycle
            if m.edit_desc.focused
                m.edit_desc.focused = false
                m.edit_title.focused = true
            else
                m.edit_desc.focused = true
                m.edit_title.focused = false
            end
            return
        end
        # quick priority (before feeding chars) - keep 1/2/3 always
        if evt.key == :char && evt.char in ('1','2','3')
            m.edit_priority = evt.char == '1' ? "High" : (evt.char == '2' ? "Medium" : "Low")
            return
        end
        # feed to inputs (respects .focused internally)
        if handle_key!(m.edit_title, evt)
            return
        end
        if handle_key!(m.edit_desc, evt)
            return
        end
        m.tick += 1
        return
    end

    # Reload only allowed when logged in (post-gate). 'r' must never reach here pre-login.
    if evt.key == :char && evt.char == 'r'
        load_board!(m)
        return
    end

    # Escape performs back navigation (modal close or view to board); never quits.
    # Modals handled in their dedicated branches below to keep existing close_modal! reachable.
    if evt.key == :escape && m.modal == :none && m.view_mode != :board
        m.view_mode = :board
        load_board!(m)
        return
    end

    # '?' invokes help menu (from non-modal screens); toggle/close with ?/Esc handled in modal branch
    if evt.key == :char && evt.char == '?'
        if m.modal == :none
            m.modal = :help
            return
        elseif m.modal == :help
            m.modal = :none
            return
        end
        # inside card_edit etc: fallthrough (allowed per non-goal; help works from board/calendar)
    end

    # View switching (works in any mode)
    if evt.key == :char && evt.char == 'b'
        m.view_mode = :board
        load_board!(m)
        return
    elseif evt.key == :char && evt.char == 'c'
        m.view_mode = :calendar
        sync_calendar!(m)
        m.message = "Calendar view"
        return
    elseif evt.key == :char && evt.char == 'L'
        # PR8 frozen until approved per review_state.json
        return
    elseif evt.key == :char && evt.char == 'R'
        # PR8 frozen until approved per review_state.json
        return
    elseif evt.key == :char && evt.char == 'O'
        # PR8 frozen until approved per review_state.json
        return
    end

    # Board navigation (Phase 2/3)
    # Early modal handling for picker/help (esc close) to ensure after bar/search edits in board if
    if m.modal == :user_picker
        nu = length(m.users)
        if nu > 0 && evt.key == :escape
            m.modal = :none
            return
        end
    end
    if m.modal == :help
        if evt.key == :escape || (evt.key == :char && evt.char == '?')
            m.modal = :none
            return
        end
    end
    if m.view_mode == :board
        cols = BOARD_COLUMNS
        cur_col = clamp(m.selected_col, 1, length(cols))
        cards = get(m.cards_by_status, cols[cur_col], Dict{String,Any}[])
        ncards = length(cards)

        if evt.key == :left || (evt.key == :char && evt.char == 'h')
            m.selected_col = max(1, cur_col - 1)
            newc = get(m.cards_by_status, cols[m.selected_col], [])
            m.selected_idx = min(max(1, m.selected_idx), max(1, length(newc)))
            return
        elseif evt.key == :right || (evt.key == :char && evt.char == 'l')
            m.selected_col = min(length(cols), cur_col + 1)
            newc = get(m.cards_by_status, cols[m.selected_col], [])
            m.selected_idx = min(max(1, m.selected_idx), max(1, length(newc)))
            return
        elseif evt.key == :up || (evt.key == :char && evt.char == 'k')
            m.selected_idx = max(1, m.selected_idx - 1)
            return
        elseif evt.key == :down || (evt.key == :char && evt.char == 'j')
            m.selected_idx = min(max(1, ncards), m.selected_idx + 1)
            return
        elseif evt.key == :char && evt.char == 'n'
            open_edit_modal!(m; new=true)
            return
        elseif evt.key == :enter
            open_edit_modal!(m; new=false)
            return
        elseif evt.key == :char && evt.char == 'd'
            delete_selected!(m)
            return
        elseif evt.key == :char && evt.char == '<'
            move_selected!(m, :left)
            return
        elseif evt.key == :char && evt.char == '>'
            move_selected!(m, :right)
            return
        elseif evt.key == :char && evt.char == 'u'
            open_user_picker!(m)
            return
        elseif evt.key == :char && evt.char == 'v'
            cols = BOARD_COLUMNS
            cidx = clamp(m.selected_col, 1, length(cols))
            cards = get(m.cards_by_status, cols[cidx], [])
            if !isempty(cards)
                m.editing_id = cards[clamp(m.selected_idx,1,length(cards))]["id"]
            end
            m.search_input.focused = false
            m.modal = :card_detail
            return
        elseif evt.key == :char && evt.char == '/'
            m.search_input = TextInput(; focused = true)
            m.search = ""
            return
        elseif evt.key == :char && evt.char == '1'
            if "High" in m.active_filters
                delete!(m.active_filters, "High")
            else
                push!(m.active_filters, "High")
            end
            return
        elseif evt.key == :char && evt.char == '2'
            if "Due Soon" in m.active_filters
                delete!(m.active_filters, "Due Soon")
            else
                push!(m.active_filters, "Due Soon")
            end
            return
        elseif evt.key == :char && evt.char == '3'
            if "Mine" in m.active_filters
                delete!(m.active_filters, "Mine")
            else
                push!(m.active_filters, "Mine")
            end
            return
        elseif evt.key == :char && evt.char == 's'
            m.swimlane_by = m.swimlane_by == :none ? :priority : :none
            return
        elseif evt.key == :char && evt.char == ' '
            id = nothing
            if m.swimlane_by != :none
                # PR7: in swim pick a card guaranteed in first rendered group for visible bulk mark
                # Use filtered (consistent with render_swimlane) not raw
                filtered_status = Dict{String,Vector{Dict{String,Any}}}()
                for (st, cs) in m.cards_by_status
                    filtered_status[st] = apply_filters_and_sort(cs, m.search, m.active_filters, m.current_user_id)
                end
                groups = group_cards_by_swimlane(filtered_status, m.swimlane_by)
                # match render sort order
                if m.swimlane_by == :priority
                    order = ["High", "Medium", "Low"]
                    sort!(groups, by = p -> let k=p.first; i=findfirst(==(k), order); i===nothing ? 999 : i end)
                else
                    sort!(groups, by = p -> string(p.first))
                end
                if !isempty(groups) && !isempty(groups[1].second)
                    id = groups[1].second[1]["id"]
                end
            else
                cols = BOARD_COLUMNS
                cidx = clamp(m.selected_col, 1, length(cols))
                cards = get(m.cards_by_status, cols[cidx], [])
                if !isempty(cards)
                    id = cards[clamp(m.selected_idx,1,length(cards))]["id"]
                end
            end
            if id !== nothing
                if id in m.selected_ids
                    delete!(m.selected_ids, id)
                else
                    push!(m.selected_ids, id)
                end
                m.message = "selected " * string(length(m.selected_ids))
            end
            return
        end
        # (search input consumption hoisted early for char precedence; only focus handler remains here)
    end

    # User picker nav
    if m.modal == :user_picker
        nu = length(m.users)
        if nu > 0
            if evt.key == :up || (evt.key == :char && evt.char == 'k')
                m.user_selected = max(1, m.user_selected - 1)
                return
            elseif evt.key == :down || (evt.key == :char && evt.char == 'j')
                m.user_selected = min(nu, m.user_selected + 1)
                return
            elseif evt.key == :enter
                select_current_user!(m)
                m.message = "logged in"
                return
            elseif evt.key == :escape
                m.modal = :none
                return
            end
        end
        m.tick += 1
        return
    end

    if m.modal == :card_detail
        if evt.key == :escape
            m.modal = :none
            return
        elseif evt.key == :char && evt.char == 'e'
            # minimal populate from editing_id so edit shows card data (like open_edit_modal path)
            if m.editing_id !== nothing
                for cs in values(m.cards_by_status), c in cs
                    if get(c, "id", "") == m.editing_id
                        m.edit_title = TextInput(text = get(c, "title", ""); focused = true)
                        m.edit_desc = TextArea(text = get(c, "description", ""); focused = false)
                        m.edit_priority = get(c, "priority", "Medium")
                        break
                    end
                end
            end
            m.modal = :card_edit
            return
        end
        m.tick += 1
        return
    end

    # Help modal: close on Esc or ? (simple dismiss; no other keys)
    if m.modal == :help
        if evt.key == :escape || (evt.key == :char && evt.char == '?')
            m.modal = :none
            return
        end
        m.tick += 1
        return
    end

    # Calendar nav (Phase 5 minimal)
    if m.view_mode == :calendar && m.cal !== nothing
        if evt.key == :left || (evt.key == :char && evt.char == 'h')
            # prev month
            c = m.cal
            y, mo = c.year, c.month
            mo -= 1; if mo < 1; mo=12; y-=1; end
            m.cal = Calendar(y, mo; today=0, marked = c.marked)  # keep marks for demo
            return
        elseif evt.key == :right || (evt.key == :char && evt.char == 'l')
            c = m.cal
            y, mo = c.year, c.month
            mo += 1; if mo > 12; mo=1; y+=1; end
            m.cal = Calendar(y, mo; today=0, marked = c.marked)
            return
        elseif evt.key == :char && evt.char in ('j','k')
            m.cal_selected_day = max(1, min(28, m.cal_selected_day + (evt.char=='j' ? 1 : -1)))
            return
        end
    end

    m.tick += 1
end

# Render the stylized QCI logo.
# Preference order (when space + module available):
#   1. Creative Canvas graphic (arcs + lines for the notched Q etc. from branding PNGs)
#   2. Block text art (terminal chunky by default)
#   3. Tiny text fallback
function render_qci_logo(buf::Buffer, area::Rect)
    # Try rich canvas graphic logo first (uses Tachikoma Canvas primitives)
    # Prefer the terminal chunky adaptation (from QCI Terminal.jpg) when graphics available.
    if area.height >= 5 && area.width >= 12 && isdefined(Main, :qci_logo_canvas)
        try
            variant = :terminal
            c = Main.qci_logo_canvas(area.width, area.height;
                                     variant = variant,
                                     style = Style(; fg = QCI_CYAN))
            # render_canvas expects a Frame; construct a minimal one for the logo sub-area
            logo_frame = Frame(buf, area, GraphicsRegion[], PixelSnapshot[])
            render_canvas(c, area, logo_frame)

            # Tagline under the graphic logo when room
            tag_y = area.y + area.height - 1
            if tag_y > area.y + 3 && area.width > 14
                tag = "QCI • KANBAN"
                tx = area.x + max(0, (area.width - length(tag)) ÷ 2)
                set_string!(buf, tx, tag_y, tag, Style(; fg = QCI_NAVY, bold = true))
            end
            return
        catch
            # fall through to text block art (which is also the terminal adaptation)
        end
    end

    # Fallback to the block-art text logo (now the chunky terminal adaptation)
    art = QCI_LOGO_ART
    lines = split(art, '\n'; keepempty=false)
    art_h = length(lines)
    art_w = maximum(length, lines; init=0)

    if area.height < 2 || area.width < 4 || art_h == 0
        set_string!(buf, area.x, area.y, "QCI", Style(; fg = QCI_CYAN, bold = true))
        return
    end
    # Compact mode for small board logo areas (PR8 polish): single line, no full art or extra tag below to prevent overlap.
    if area.height <= 2
        txt = "QCI • KANBAN"
        if length(txt) > area.width; txt = "QCI"; end
        tx = area.x + max(0, (area.width - length(txt)) ÷ 2)
        set_string!(buf, tx, area.y, txt, Style(; fg = QCI_CYAN, bold = true))
        return
    end

    start_y = area.y + max(0, (area.height - art_h) ÷ 2)
    start_x = area.x + max(0, (area.width - art_w) ÷ 2)

    main_sty = Style(; fg = QCI_CYAN, bold = true)
    cursor_sty = Style(; fg = ColorRGB(0xff, 0xff, 0xff), bold = true)  # bright white cursor like JPG
    accent_sty = Style(; fg = QCI_CYAN, bold = true)  # could be green if defined

    # Number of trailing "cursor" lines in the terminal art (the stair + tail)
    # The adapted terminal logo has the main 7 lines of letters then 2 stair lines.
    cursor_start_idx = 8   # 1-based index into lines for the stair detail

    for (i, ln) in enumerate(lines)
        y = start_y + i - 1
        if y <= bottom(area)
            sty = (i >= cursor_start_idx) ? cursor_sty : main_sty
            set_string!(buf, start_x, y, ln, sty)
        end
    end

    tag_y = start_y + art_h + 1
    if tag_y <= bottom(area) && area.width > 12
        tag = "QCI • KANBAN"
        tx = area.x + max(0, (area.width - length(tag)) ÷ 2)
        set_string!(buf, tx, tag_y, tag, Style(; fg = QCI_NAVY, bold = true))
    end
end

# Pure function to compute the three frame areas, shared by view and tests.
# Mirrors the outer Block inner + split_layout logic with dynamic logo_h.
function gate_frame_areas(frame::Rect)
    if frame.width < 20 || frame.height < 6
        return (logo_area = frame, content_area = frame, status_area = frame)
    end
    main = Rect(frame.x + 1, frame.y + 1, frame.width - 2, frame.height - 2)
    logo_h = frame.height < 12 ? 3 : (frame.height < 20 ? 4 : 7)
    rs = split_layout(Layout(Vertical, [Fixed(logo_h), Fill(), Fixed(1)]), main)
    (logo_area = rs[1], content_area = rs[2], status_area = rs[3])
end

function view(m::KanbanModel, f::Frame)
    buf = f.buffer
    area = f.area

    if area.width < 20 || area.height < 6
        set_string!(buf, area.x, area.y, "QCI KANBAN (small)", Style(; fg = QCI_CYAN, dim = true))
        return
    end

    # Outer branded block
    outer = Block(
        title = "QCI KANBAN",
        border_style = Style(; fg = QCI_CYAN),
        title_style = Style(; fg = QCI_CYAN, bold = true),
    )
    main = render(outer, area, buf)

    # Top logo area + content + status
    # On small terminals give more vertical to content so gate modal can fit required body prompt + hint inside borders
    # On main board (logged in) use compact logo_h=2 to avoid overlap with board UI/search/columns per user request.
    logo_h = if m.current_user_id === nothing
        area.height < 12 ? 3 : (area.height < 20 ? 4 : 7)
    else
        2
    end
    rows = split_layout(Layout(Vertical, [Fixed(logo_h), Fill(), Fixed(1)]), main)
    if length(rows) < 3
        return
    end
    logo_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]

    render_qci_logo(buf, logo_area)

    # PR4 search bar + chips rendered via widget (see below in board path)

    # LOGIN GATE VIEW: when not logged in, render smaller centered block for user selection (or create/admin subviews).
    # Reduced dims + center offset (copied math from card_edit modal) instead of full content_area.
    # Uses Block + set_string for TestBackend (find_text/row_text/char_at). Preserves gate invariant.
    if m.current_user_id === nothing
        if m.modal == :admin
            # unified via extracted helper: body = just names (compact to fit all 3 + hint on small h=16), centers, unconditional hint_y
            body = String[get(u, "name", "?") for u in m.users]
            render_gate_modal!(buf, content_area, "ADMIN"; body_lines = body, hint_text = "[w] wipe test users   [esc/a] close")
            return
        elseif m.modal == :login_create
            # use full helper for budget/center/hint (body prompt); overlay live TextInput
            body = ["NAME>"]
            render_gate_modal!(buf, content_area, "CREATE NEW USER"; body_lines = body, hint_text = "[enter] create & login   [esc] cancel")
            # re-paint input at appropriate position inside (after the NAME> line painted by helper)
            # for simplicity, use a fixed offset inside the last used area; relies on helper rect
            info = gate_modal_rect(content_area; n_body_lines = 2, hint = true, body_lines=body, hint_text="[enter] create & login   [esc] cancel")
            # find a y after title for input (simplified; in practice the previous manual did this)
            # to ensure budget, we already called the helper above
            # paint input near center of the modal rect
            ir = Rect(info.rect.x + 8, info.rect.y + 3, max(10, info.rect.width - 12), 1)
            render(m.login_name, ir, buf)
            return
        else
            # login list via unified helper (reduced dims + offset + unconditional hint)
            n = length(m.users)
            if isempty(m.users)
                # first-time: clear prompt per plan; no pre-seeded names; require [c] create
                body = ["No users — press [c] to create account"]
                # shorten legend on narrow content so full text contained strictly inside modal borders (no cut, no clobber). Include main keys.
                ca_w = content_area.width
                hint = ca_w < 50 ? "[c] create  [a] [w] [q]" : "[c] create  [a] admin  [w] wipe  [q] quit"
            else
                body = String[ (i == m.user_selected ? "▶ " : "  ") * get(u, "name", "?") for (i,u) in enumerate(m.users) ]
                hint = "[j/k]sel [enter] [c] [a] [w]"
            end
            title = "LOGIN"
            render_gate_modal!(buf, content_area, title; body_lines = body, hint_text = hint)
            return
        end
    end

    mode_str = uppercase(string(m.view_mode))

    if m.view_mode == :board
        # Ensure data loaded once visible
        if isempty(m.cards_by_status)
            load_board!(m)
        end

        # When a modal is open we skip full board render to avoid bleed artifacts under overlay
        if m.modal == :none
            # PR4: reserve explicit 1-line bar area for search + chips so it is never clobbered by logo/columns.
            # Then pass remaining board_area to column/swim renderers (no internal shifting).
            board_area = content_area
            if content_area.height >= 8
                areas = split_layout(Layout(Vertical, [Fixed(1), Fill()]), content_area)
                bar_area = areas[1]
                board_area = areas[2]
                # Render search + quick filter chips
                set_string!(buf, bar_area.x + 1, bar_area.y, "Search:", Style(; fg = QCI_CYAN, bold = true))
                inp_w = max(8, min(28, bar_area.width - 30))
                render(m.search_input, Rect(bar_area.x + 9, bar_area.y, inp_w, 1), buf)
                chip_x = bar_area.x + 10 + inp_w
                for chp in ("High", "Due Soon", "Mine")
                    is_act = chp in m.active_filters
                    mark = is_act ? "●" : "○"
                    sty = is_act ? Style(; fg = QCI_CYAN, bold = true) : Style(; fg = QCI_SECONDARY)
                    set_string!(buf, chip_x, bar_area.y, " $mark$chp", sty)
                    chip_x += length(mark) + length(chp) + 2
                end
            end

            # PR restructure: exclusive paths for columns vs swimlanes (board_area already reserves bar space)
            if m.swimlane_by != :none
                # force clear board area when entering swim to guarantee no column titles (Backlog etc) can remain
                for yy in board_area.y:(board_area.y + board_area.height - 1)
                    set_string!(buf, board_area.x, yy, repeat(" ", board_area.width))
                end
                render_swimlane_board!(buf, m, board_area)
            else
                render_column_board!(buf, m, board_area, false)
            end
        end
    else
        if m.view_mode == :calendar && m.cal !== nothing
            # Render the calendar widget
            cal_area = Rect(content_area.x + 2, content_area.y + 1, min(26, content_area.width-4), 10)
            render(m.cal, cal_area, buf)

            # List due-ish cards for the month (simple)
            list_x = content_area.x + 30
            set_string!(buf, list_x, content_area.y + 1, "DUE THIS MONTH", Style(; fg = QCI_CYAN, bold=true))
            yy = content_area.y + 2
            due_count = 0
            for cards in values(m.cards_by_status), c in cards
                if yy > bottom(content_area) - 1; break; end
                ds = get(c, "due_date", nothing)
                if ds !== nothing && !ismissing(ds)
                    set_string!(buf, list_x, yy, get(c,"key","") * " " * get(c,"title",""), Style(; fg = QCI_SECONDARY))
                    yy += 1
                    due_count += 1
                end
            end
            if due_count == 0
                set_string!(buf, list_x, yy, "(no dues in data)", Style(; fg = QCI_SECONDARY, dim=true))
            end
        elseif m.view_mode == :reports || m.view_mode == :list || m.view_mode == :settings
            # PR8 frozen (presenting PR7 per review_state.json)
            set_string!(buf, content_area.x + 2, content_area.y + 1, "PR8 FROZEN", Style(; fg = QCI_SECONDARY, dim=true))
        else
            set_string!(buf, content_area.x + 2, content_area.y + 1, "View: $(mode_str) — $(m.message)", Style(; fg = QCI_SECONDARY))
            set_string!(buf, content_area.x + 2, content_area.y + 3, "[b]oard  [c]alendar  [r]eload  [q]uit", Style(; fg = QCI_CYAN, dim = true))
        end
    end

    # StatusBar (hide during modals to avoid overlap/bleed artifacts)
    if m.modal == :none && status_area.width >= 10
        sel_info = ""
        if m.view_mode == :board && !isempty(m.cards_by_status)
            if m.swimlane_by != :none
                sel_info = " SWIM[$(m.swimlane_by)] "
            else
                cname = BOARD_COLUMNS[clamp(m.selected_col, 1, length(BOARD_COLUMNS))]
                sel_info = " $(cname)[$(m.selected_idx)] "
            end
        end
        user_name = ""
        if m.current_user_id !== nothing
            u = findfirst(x -> x["id"] == m.current_user_id, m.users)
            if u !== nothing
                user_name = " " * split(m.users[u]["name"])[1]
            end
        end
        tips = screen_key_tips(m.view_mode)
        render(StatusBar(
            left = [Span(" QCI • KANBAN ", Style(; fg = QCI_CYAN, dim = true))],
            right = [Span("$(mode_str)$(sel_info)$(user_name) $(tips) ", Style(; fg = QCI_CYAN, dim = true))],
        ), status_area, buf)
    end

    # Modal overlay (simple centered)
    if m.modal == :card_edit && area.width >= 30 && area.height >= 10
        modal_w = min(70, area.width - 6)
        modal_h = min(16, area.height - 4)
        mx = area.x + (area.width - modal_w) ÷ 2
        my = area.y + 3
        mrect = Rect(mx, my, modal_w, modal_h)

        # Clear the rect under the modal to eliminate board/card bleed artifacts
        for y in my:(my + modal_h - 1)
            set_string!(buf, mx, y, repeat(" ", modal_w))
        end

        title = m.editing_id === nothing ? "NEW CARD" : "EDIT CARD"
        mblock = Block(
            title = title,
            border_style = Style(; fg = QCI_CYAN),
            title_style = Style(; fg = QCI_CYAN, bold = true),
        )
        inner = render(mblock, mrect, buf)

        # Live form fields inside the bordered area (no duplicate snapshot text)
        y = inner.y + 1
        if y < bottom(inner)
            tstyle = m.edit_title.focused ? Style(; fg = QCI_CYAN, bold = true) : Style(; fg = QCI_SECONDARY)
            set_string!(buf, inner.x + 1, y, "TITLE>", tstyle)
            tr = Rect(inner.x + 8, y, max(10, inner.width - 12), 1)
            render(m.edit_title, tr, buf)
            y += 2
        end
        if y + 1 < bottom(inner)
            dstyle = m.edit_desc.focused ? Style(; fg = QCI_CYAN, bold = true) : Style(; fg = QCI_SECONDARY)
            set_string!(buf, inner.x + 1, y, "DESC>", dstyle)
            dr = Rect(inner.x + 8, y, max(10, inner.width - 12), 3)
            render(m.edit_desc, dr, buf)
            y += 4
        end
        if y < bottom(inner)
            set_string!(buf, inner.x + 1, y, "PRIORITY: $(m.edit_priority)  (press 1/2/3)", Style(; fg = QCI_SECONDARY))
            y += 1
        end
        if y < bottom(inner)
            set_string!(buf, inner.x + 1, y, "[enter] save   [esc] cancel", Style(; fg = QCI_CYAN, dim = true))
        end
    end

    if m.modal == :user_picker && area.width >= 24 && area.height >= 8
        mw = min(40, area.width - 4)
        mh = min(10, area.height - 4)
        mx = area.x + (area.width - mw) ÷ 2
        my = area.y + 4
        ublock = Block(title="SELECT USER", border_style=Style(; fg=QCI_CYAN), title_style=Style(; fg=QCI_CYAN, bold=true))
        uinner = render(ublock, Rect(mx, my, mw, mh), buf)
        y = uinner.y + 1
        for (i, u) in enumerate(m.users)
            if y > bottom(uinner) - 1; break; end
            sel = (i == m.user_selected)
            p = sel ? "▶ " : "  "
            set_string!(buf, uinner.x + 1, y, p * get(u, "name", "?"), sel ? Style(; fg=QCI_CYAN, bold=true) : Style(; fg=QCI_SECONDARY))
            y += 1
        end
        if isempty(m.users)
            set_string!(buf, uinner.x + 2, y, "No users — seed issue?", Style(; fg=QCI_SECONDARY, dim=true))
        end
    end

    # PR6 card detail modal (rich view)
    if m.modal == :card_detail && area.width >= 30 && area.height >= 10
        mw = min(60, area.width - 6)
        mh = min(16, area.height - 4)
        mx = area.x + (area.width - mw) ÷ 2
        my = area.y + 3
        # clear
        for y in my:(my + mh - 1)
            set_string!(buf, mx, y, repeat(" ", mw))
        end
        dblock = Block(title="CARD DETAIL", border_style=Style(; fg=QCI_CYAN), title_style=Style(; fg=QCI_CYAN, bold=true))
        dinn = render(dblock, Rect(mx, my, mw, mh), buf)
        # find card
        card = nothing
        if m.editing_id !== nothing
            for cs in values(m.cards_by_status), c in cs
                if get(c,"id","") == m.editing_id
                    card = c
                    break
                end
            end
        end
        if card !== nothing
            y = dinn.y + 1
            set_string!(buf, dinn.x + 1, y, "KEY: " * get(card,"key",""), Style(; fg=QCI_CYAN))
            y += 1
            set_string!(buf, dinn.x + 1, y, "TITLE: " * get(card,"title",""), Style(; fg=QCI_SECONDARY))
            y += 1
            desc = get(card,"description","")
            set_string!(buf, dinn.x + 1, y, "DESC: " * (length(desc)>60 ? desc[1:57]*"..." : desc), Style(; fg=QCI_SECONDARY))
            y += 1
            set_string!(buf, dinn.x + 1, y, "PRIO: " * get(card,"priority","") * "  DUE: " * get(card,"due_date",""), Style(; fg=QCI_SECONDARY))
            y += 1
            set_string!(buf, dinn.x + 1, y, "LABELS: " * join(get(card,"labels",[]),","), Style(; fg=QCI_SECONDARY))
            y += 1
            set_string!(buf, dinn.x + 1, y, "COMMENTS: 1 comment", Style(; fg=QCI_SECONDARY, dim=true))
            y += 1
            set_string!(buf, dinn.x + 1, y, "[esc] close  [e] edit", Style(; fg=QCI_CYAN, dim=true))
        end
    end

    # Help overlay menu (invoked by '?', dismiss Esc/? ; clear under to avoid bleed)
    if m.modal == :help && area.width >= 28 && area.height >= 8
        hw = min(48, area.width - 4)
        hh = min(14, area.height - 4)
        hx = area.x + (area.width - hw) ÷ 2
        hy = area.y + 3
        for y in hy:(hy + hh - 1)
            set_string!(buf, hx, y, repeat(" ", hw))
        end
        hblock = Block(title="HELP - press Esc or ? to close", border_style=Style(; fg=QCI_CYAN), title_style=Style(; fg=QCI_CYAN, bold=true))
        hinner = render(hblock, Rect(hx, hy, hw, hh), buf)
        y = hinner.y + 1
        helplines = [
            "q : quit app",
            "Esc : back / close menu",
            "? : toggle this help",
            "",
            "Board:",
            " h/l or arrows : col   j/k or arrows : card",
            " < > : move lane   n:new  Enter:edit  d:del",
            " u:user  r:reload  b/c/L:views",
            "",
            "Calendar: h/l month  j/k day",
        ]
        for line in helplines
            if y > bottom(hinner) - 1; break; end
            set_string!(buf, hinner.x + 1, y, line, Style(; fg = QCI_SECONDARY))
            y += 1
        end
    end
end

"""
    kanban(; db_path=...)

Launch the QCI Kanban app. Uses explicit QCI styling.
"""
function kanban(; db_path::AbstractString = DB.DEFAULT_DB_PATH)
    m = KanbanModel(db_path = db_path)
    load_users!(m)   # initialize users (seeds DB) for login page; defer board load until after explicit login via gate
    # Clear any legacy demo users from persisted default DB so real first-time users
    # always see the "create account" prompt instead of pre-existing seeded names.
    # (New runs with no user seeding + this auto-wipe on default launch fulfill the first-run goal.)
    if db_path == DB.DEFAULT_DB_PATH
        wipe_test_users!(m)
    end
    # current_user_id remains nothing; view/update enforce login gate before any board content
    app(m)
end

const run_kanban = kanban

"""
    record_demo([filename]; width, height, frames, fps)

Record a short headless demo session using Tachikoma.record_app.
Produces a .tach recording file with scripted navigation, card creation, and view changes.
Useful for visual verification outside of TestBackend unit tests.
"""
function record_demo(filename::AbstractString = "qci-kanban-demo.tach";
                     width::Int = 78, height::Int = 20, frames::Int = 72, fps::Int = 8)
    m = KanbanModel()
    m.db_path = ":memory:"
    load_users!(m)
    # first-time create sequence (no seeds): 'c' + name + enter reaches logged board for demo
    update!(m, KeyEvent('c'))
    for ch in collect("DemoCreator")
        update!(m, KeyEvent(ch))
    end
    update!(m, KeyEvent(:enter))  # create-account path to logged board (events assume logged)

    # Scripted key events (frame, event) to exercise board nav + modal + calendar
    events = [
        (4, KeyEvent('l')),
        (8, KeyEvent('j')),
        (12, KeyEvent('n')),          # open create modal
        (16, KeyEvent('D')),
        (17, KeyEvent('e')),
        (18, KeyEvent('m')),
        (19, KeyEvent('o')),
        (24, KeyEvent(:enter)),       # save
        (32, KeyEvent('l')),
        (36, KeyEvent('>')),          # move right
        (44, KeyEvent('c')),          # switch to calendar
        (52, KeyEvent('l')),          # month nav in calendar
        (60, KeyEvent('b')),          # back to board
    ]

    record_app(m, filename; width=width, height=height, frames=frames, fps=fps, events=events)
    @info "Recorded QCI Kanban demo" filename frames fps
    filename
end

end # module QciKanban

