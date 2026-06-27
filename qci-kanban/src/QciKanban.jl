# ═══════════════════════════════════════════════════════════════════════
# QciKanban — QCI Jira-Inspired Kanban TUI (Tachikoma)
#
# Self-contained sub-project. Run with: julia --project=qci-kanban ...
#
# Elm-style: mutable struct <: Model, should_quit, update!, view.
# Full TestBackend required for all UI (AGENTS.md).
#
# Branding: QCI navy + cyan from branding/bg-light-top-right.png
# Logo: BigText + stylized QCI mark (to be expanded).
# ═══════════════════════════════════════════════════════════════════════

module QciKanban

using Tachikoma
using Dates
using UUIDs
@tachikoma_app

include("db.jl")
using .DB

# QCI branding (copied from ai_metrics_dashboard patterns for consistency)
const QCI_CYAN = ColorRGB(UInt8(0), UInt8(188), UInt8(212))
const QCI_NAVY = ColorRGB(UInt8(30), UInt8(32), UInt8(75))
const QCI_SECONDARY = ColorRGB(UInt8(100), UInt8(110), UInt8(165))  # lighter navy for unselected/secondary text (contrast on black)

export QCI_CYAN, QCI_NAVY, QCI_SECONDARY
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
    # Modal / edit (Phase 3)
    modal::Symbol = :none          # :none | :card_edit | :user_picker
    editing_id::Union{String,Nothing} = nothing
    edit_title::TextInput = TextInput()
    edit_desc::TextArea = TextArea()
    edit_priority::String = "Medium"
    # Users (Phase 4)
    current_user_id::Union{String,Nothing} = nothing
    users::Vector{Dict{String,Any}} = Dict{String,Any}[]
    user_selected::Int = 1
    # Login on startup (PR1: fields + guard skeleton; default :logged_in keeps direct paths)
    login_state::Symbol = :logged_in
    login_selected::Int = 1
    login_input::TextInput = TextInput(; focused=true)
    # Calendar (Phase 5)
    cal::Union{Calendar, Nothing} = nothing
    cal_selected_day::Int = Dates.day(Dates.today())
end

# ── Board loading (Phase 2) ─────────────────────────────────────────────

function ensure_db!(m::KanbanModel; seed::Bool = true)
    if m.db === nothing
        m.db = DB.open_db(m.db_path)
        if seed
            DB.seed_demo!(m.db)  # seed_demo! self-guards; kanban() uses parallel both-empty check for startup semantics (see design)
        end
    end
end

function load_board!(m::KanbanModel)
    ensure_db!(m)
    empty!(m.cards_by_status)
    for status in BOARD_COLUMNS
        m.cards_by_status[status] = DB.list_issues(m.db; status=status)
    end
    load_users!(m; auto_select=true)
    # clamp selection
    m.selected_col = clamp(m.selected_col, 1, length(BOARD_COLUMNS))
    n = length(get(m.cards_by_status, BOARD_COLUMNS[m.selected_col], []))
    m.selected_idx = clamp(m.selected_idx, 1, max(1, n))
    sync_calendar!(m)
    m.message = "loaded $(sum(length(v) for v in values(m.cards_by_status))) cards"
    m.login_state = :logged_in  # narrow PR1 compat shim for direct KanbanModel+load_board! paths + record_demo (harmless)
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

function load_users!(m::KanbanModel; auto_select::Bool = true)
    ensure_db!(m)
    m.users = DB.list_users(m.db)
    if auto_select && m.current_user_id === nothing && !isempty(m.users)
        m.current_user_id = m.users[1]["id"]
    end
end

# Login helpers (PR1 stubs: set state or minimal action; full create/login + seeding later)
function select_user_and_login!(m::KanbanModel)
    if !isempty(m.users)
        idx = clamp(m.login_selected, 1, length(m.users))
        m.current_user_id = m.users[idx]["id"]
    end
    m.login_state = :logged_in
    load_board!(m)  # ensures cards + shim
end

function create_and_login!(m::KanbanModel, name::AbstractString)
    # PR1 stub (skeleton only): ignores name, does NOT call DB.create_user! or first-user demo seed (deferred).
    # Sets :logged_in so guard passes and direct paths stay runnable.
    # On empty-users path (test covered), current_user remains nothing and no cards auto-added here.
    # Real create + select + conditional seed per design-login-startup.md happens in follow-up PRs.
    m.login_state = :logged_in
    load_board!(m)  # harmless for logged; may populate if users present
end

function switch_to_create_user!(m::KanbanModel)
    m.login_state = :create_user
    m.login_input = TextInput(; focused = true)
end

function open_user_picker!(m::KanbanModel)
    load_users!(m; auto_select=true)
    m.modal = :user_picker
    m.user_selected = 1
end

function select_current_user!(m::KanbanModel)
    if !isempty(m.users)
        idx = clamp(m.user_selected, 1, length(m.users))
        m.current_user_id = m.users[idx]["id"]
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

should_quit(m::KanbanModel) = m.quit

function update!(m::KanbanModel, evt::KeyEvent)
    if evt.key == :char && evt.char == 'q'
        m.quit = true
        return
    elseif evt.key == :escape
        m.quit = true
        return
    end

    if m.login_state != :logged_in
        # full early guard (PR1 wiring+safety): pass-through only for :logged_in or direct paths
        # prevents all board/view/mode/modal bleed until login; q/esc handled above; 'r' ignored pre-login (handled only after guard)
        if m.login_state == :create_user
            if evt.key == :enter
                name = strip(text(m.login_input))
                if !isempty(name)
                    create_and_login!(m, name)
                end
                return
            elseif evt.key == :escape
                if !isempty(m.users)
                    m.login_state = :select_user
                    m.login_selected = 1
                else
                    m.quit = true
                end
                return
            end
            if handle_key!(m.login_input, evt)
                return
            end
            return
        else  # :select_user
            nu = length(m.users)
            if nu > 0
                if evt.key == :up || (evt.key == :char && evt.char == 'k')
                    m.login_selected = max(1, m.login_selected - 1)
                    return
                elseif evt.key == :down || (evt.key == :char && evt.char == 'j')
                    m.login_selected = min(nu, m.login_selected + 1)
                    return
                elseif evt.key == :enter
                    select_user_and_login!(m)
                    return
                elseif evt.key == :char && evt.char in ('n', 'c')
                    switch_to_create_user!(m)
                    return
                end
            end
            if evt.key == :escape
                m.quit = true
            end
            return
        end
    end

    # 'r' reload (only reachable for :logged_in; pre-login 'r' ignored by early guard above per design)
    if evt.key == :char && evt.char == 'r'
        load_board!(m)
        return
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
        m.view_mode = :list
        m.message = "List (stub)"
        return
    end

    # Modal input routing first (Phase 3)
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

    # Board navigation (Phase 2/3)
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
        end
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

# Simple QCI logo render using BigText + accent line (logo translation MVP)
function render_qci_logo(buf::Buffer, area::Rect)
    # Centered BigText "QCI"
    bt = BigText("QCI"; style = Style(; fg = QCI_CYAN, bold = true))
    tw, th = intrinsic_size(bt)
    tx = area.x + max(0, (area.width - tw) ÷ 2)
    title_r = Rect(tx, area.y, min(tw, area.width), min(th, area.height))
    if area.height >= 1 && area.width >= 3
        render(bt, title_r, buf)
    end
    # Small stylized tagline / mark hint under logo
    y2 = area.y + 5
    if y2 < bottom(area) && area.width > 10
        tag = "QCI KANBAN"
        sx = area.x + max(0, (area.width - length(tag)) ÷ 2)
        set_string!(buf, sx, y2, tag, Style(; fg = QCI_NAVY, bold = true))
    end
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
    rows = split_layout(Layout(Vertical, [Fixed(7), Fill(), Fixed(1)]), main)
    if length(rows) < 3
        return
    end
    logo_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]

    render_qci_logo(buf, logo_area)

    if m.login_state != :logged_in
        # PR2 skeleton (minimal): Block title + simple list/NAME> stub. Reuses split-derived content_area + logo.
        # Full instructions, narrow handling, dynamic title, animations deferred to PR3. Early return gates board.
        is_create = m.login_state == :create_user
        title = is_create ? "CREATE USER" : "SELECT USER"
        lblock = Block(
            title = title,
            border_style = Style(; fg = QCI_CYAN),
            title_style = Style(; fg = QCI_CYAN, bold = true),
        )
        lw = min(44, content_area.width - 4)
        lh = min(12, content_area.height - 2)
        lx = content_area.x + (content_area.width - lw) ÷ 2
        ly = content_area.y + 1
        linner = render(lblock, Rect(lx, ly, lw, lh), buf)
        y = linner.y + 1
        if is_create
            set_string!(buf, linner.x + 1, y, "NAME>", Style(; fg = QCI_CYAN, bold = true))
        else
            for (i, u) in enumerate(m.users)
                if y > bottom(linner) - 2; break; end
                sel = (i == m.login_selected)
                p = sel ? "▶ " : "  "
                sty = sel ? Style(; fg = QCI_CYAN, bold = true) : Style(; fg = QCI_SECONDARY)
                set_string!(buf, linner.x + 1, y, p * get(u, "name", "?"), sty)
                y += 1
            end
        end
        return
    end

    mode_str = uppercase(string(m.view_mode))

    if m.view_mode == :board
        # Ensure data loaded once visible.
        # PR1: only when logged_in; prevents lazy load_board! (which forces login_state=:logged_in + auto current via shim) from mutating state on kanban() startup path (select/create).
        if isempty(m.cards_by_status) && m.login_state == :logged_in
            load_board!(m)
        end

        # When a modal is open we skip full board render to avoid bleed artifacts under overlay
        if m.modal == :none
            # Horizontal columns
            n = length(BOARD_COLUMNS)
            col_width = max(14, content_area.width ÷ n)
            constraints = [Fixed(col_width) for _ in 1:n]
            col_areas = split_layout(Layout(Horizontal, constraints), content_area)

            for (i, status) in enumerate(BOARD_COLUMNS)
                ca = i <= length(col_areas) ? col_areas[i] : content_area
                cards = get(m.cards_by_status, status, Dict{String,Any}[])

                # Column header block
                col_block = Block(
                    title = status,
                    border_style = Style(; fg = (i == m.selected_col ? QCI_CYAN : QCI_NAVY)),
                    title_style = Style(; fg = QCI_CYAN, bold = (i == m.selected_col)),
                )
                col_inner = render(col_block, ca, buf)

                # Cards list (simple stacked text)
                y = col_inner.y + 1
                sel = (i == m.selected_col) ? m.selected_idx : 0
                for (ci, card) in enumerate(cards)
                    if y > bottom(col_inner) - 1
                        break
                    end
                    is_sel = (ci == sel)
                    prefix = is_sel ? "▶ " : "  "
                    key = get(card, "key", "?")
                    title = get(card, "title", "")
                    # assignee initial
                    aid = get(card, "assignee_id", nothing)
                    a_initial = "·"
                    if aid !== nothing && !ismissing(aid)
                        au = findfirst(u -> u["id"] == aid, m.users)
                        if au !== nothing
                            nm = m.users[au]["name"]
                            a_initial = length(nm) > 0 ? string(first(nm)) : "?"
                        end
                    end
                    due = get(card, "due_date", nothing)
                    due_str = (due === nothing || ismissing(due)) ? "" : string(due)
                    due_s = isempty(due_str) ? "" : " " * string(last(split(due_str, "-")))
                    # truncate to fit (include suffix, clamp whole display)
                    avail = max(6, col_inner.width - 4)
                    suffix = " [" * a_initial * "]" * due_s
                    base = key * " " * (length(title) > (avail - length(suffix) - 1) ? title[1:max(0, avail - length(suffix) - 2)] * "…" : title)
                    display = base * suffix
                    if length(display) > avail
                        display = display[1:avail-1] * "…"
                    end

                    sty = is_sel ? Style(; fg = QCI_CYAN, bold = true) : Style(; fg = QCI_SECONDARY)
                    set_string!(buf, col_inner.x + 1, y, prefix * display, sty)
                    y += 1
                end

                if isempty(cards)
                    set_string!(buf, col_inner.x + 2, y, "— empty —", Style(; fg = QCI_SECONDARY, dim = true))
                end
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
        else
            # Other views stub
            set_string!(buf, content_area.x + 2, content_area.y + 1, "View: $(mode_str) — $(m.message)", Style(; fg = QCI_SECONDARY))
            set_string!(buf, content_area.x + 2, content_area.y + 3, "[b]oard  [c]alendar  [r]eload  [q]uit", Style(; fg = QCI_CYAN, dim = true))
        end
    end

    # StatusBar (hide during modals to avoid overlap/bleed artifacts)
    if m.modal == :none && status_area.width >= 10
        sel_info = ""
        if m.view_mode == :board && !isempty(m.cards_by_status)
            cname = BOARD_COLUMNS[clamp(m.selected_col, 1, length(BOARD_COLUMNS))]
            sel_info = " $(cname)[$(m.selected_idx)] "
        end
        user_name = ""
        if m.current_user_id !== nothing
            u = findfirst(x -> x["id"] == m.current_user_id, m.users)
            if u !== nothing
                user_name = " " * split(m.users[u]["name"])[1]
            end
        end
        render(StatusBar(
            left = [Span(" QCI • KANBAN ", Style(; fg = QCI_CYAN, dim = true))],
            right = [Span("$(mode_str)$(sel_info)$(user_name) [u]ser r=reload ", Style(; fg = QCI_CYAN, dim = true))],
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
end

"""
    kanban(; db_path=...)

Launch the QCI Kanban app. Uses explicit QCI styling.
"""
function kanban(; db_path::AbstractString = DB.DEFAULT_DB_PATH)
    m = KanbanModel(db_path = db_path)
    if m.db === nothing
        m.db = DB.open_db(m.db_path)
    end
    # conditional seed only if both users+issues empty (absolute first run)
    # (dupe of ensure logic is minor; kept explicit for PR1 startup path; nit addressed via comment)
    pre_users = DB.list_users(m.db)
    pre_issues = DB.list_issues(m.db)
    if isempty(pre_users) && isempty(pre_issues)
        DB.seed_demo!(m.db)
    end
    load_users!(m; auto_select = false)
    if isempty(m.users)
        m.login_state = :create_user
        m.login_input = TextInput(; focused = true)
    else
        m.login_state = :select_user
        m.login_selected = 1
    end
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
    load_board!(m)

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

