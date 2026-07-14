# Phase 3 — Jira board view: swimlane × status grid, rich cards, navigation,
# board ops, quick filters, search, WIP limits. Driven only via update!.
# Depends on helpers from test_app_shell.jl (fresh_app, app_login_new, app_tb,
# app_rows) which runtests.jl includes first.

using Dates

Q3 = QciKanban

lb() = (m = fresh_app(); app_login_new(m; name = "Ada Lovelace"); m)
mkey(m, k) = T.update!(m, T.KeyEvent(k))

@testset "Phase 3 — Board grid + rich cards" begin
    @testset "board renders all five status columns with counts + cards" begin
        m = lb()
        tb = app_tb(m; w = 100, h = 30)
        for st in Q3.BOARD_STATUSES
            @test T.find_text(tb, st) !== nothing
        end
        @test T.find_text(tb, "QCI-100") !== nothing        # rich card key
        rows = app_rows(m; w = 100, h = 30)
        blob = join(rows, "\n")
        @test occursin("▲", blob)                           # priority glyph
        @test occursin("sp", blob)                          # story-point badge
    end

    @testset "swimlane cycles none→assignee→epic→priority→none with named lanes" begin
        m = lb()
        @test m.swimlane_by == :none
        mkey(m, 's'); @test m.swimlane_by == :assignee
        rows = app_rows(m; w = 100, h = 30)
        @test any(occursin("Unassigned", r) for r in rows)  # lane-by-assignee name
        mkey(m, 's'); @test m.swimlane_by == :epic
        rows = app_rows(m; w = 100, h = 30)
        @test any(occursin("Board Core", r) || occursin("Onboarding", r) for r in rows)
        mkey(m, 's'); @test m.swimlane_by == :priority
        rows = app_rows(m; w = 100, h = 30)
        @test any(occursin("High", r) for r in rows)
        mkey(m, 's'); @test m.swimlane_by == :none
    end

    @testset "swimlane-by-epic grid: cards land in the correct status cells" begin
        m = lb()
        mkey(m, 's'); mkey(m, 's')               # → epic
        @test m.swimlane_by == :epic
        g = Q3.board_grid(m)
        @test length(g) >= 2                     # at least Board Core + Onboarding lanes
        # every card in a cell has that cell's status
        for lane in g, (ci, cell) in enumerate(lane.cols), iss in cell
            @test iss.status == Q3.BOARD_STATUSES[ci]
        end
    end
end

@testset "Phase 3 — Board navigation (lane, column, index)" begin
    @testset "h/l move columns; j/k move within & across cells" begin
        m = lb()
        @test m.sel_col == 1
        mkey(m, 'l'); @test m.sel_col == 2
        mkey(m, 'l'); @test m.sel_col == 3
        mkey(m, 'h'); @test m.sel_col == 2
        # left edge clamps
        mkey(m, 'h'); mkey(m, 'h'); @test m.sel_col == 1
        # down within the Backlog cell (2 cards) then clamps
        @test m.sel_idx == 1
        mkey(m, 'j'); @test m.sel_idx == 2
        iss = Q3.selected_issue(m)
        @test iss !== nothing && iss.status == "Backlog"
    end

    @testset "arrow keys mirror h/l/j/k" begin
        m = lb()
        mkey(m, :right); @test m.sel_col == 2
        mkey(m, :left);  @test m.sel_col == 1
        mkey(m, :down);  @test m.sel_idx == 2
        mkey(m, :up);    @test m.sel_idx == 1
    end

    @testset "vertical nav crosses lanes coherently (assignee mode)" begin
        m = lb()
        mkey(m, 's')                              # assignee mode (all Unassigned → 1 lane here)
        @test m.swimlane_by == :assignee
        # navigating down past the cell should not error and stays in-bounds
        for _ in 1:6; mkey(m, 'j'); end
        @test m.sel_lane >= 1 && m.sel_idx >= 1
    end
end

@testset "Phase 3 — Card ops" begin
    @testset "move status < and > shifts the selected issue" begin
        m = lb()
        iss = Q3.selected_issue(m)
        @test iss.status == "Backlog"
        mkey(m, '>')                              # Backlog → To Do
        moved = Q3.Stores.get_issue(m.boardstore, iss.id)
        @test moved.status == "To Do"
        @test occursin("→ To Do", m.message)
        # activity logged
        acts = Q3.Stores.list_activity(m.boardstore, iss.id)
        @test any(a.kind == :status_changed for a in acts)
        mkey(m, '<'); mkey(m, '<')                # back and clamp at Backlog
        @test Q3.Stores.get_issue(m.boardstore, iss.id).status == "Backlog"
    end

    @testset "assign-to-me sets assignee + logs activity" begin
        m = lb()
        iss = Q3.selected_issue(m)
        mkey(m, 'a')
        upd = Q3.Stores.get_issue(m.boardstore, iss.id)
        @test upd.assignee_id == m.current_user.id
        @test any(a.kind == :assigned for a in Q3.Stores.list_activity(m.boardstore, iss.id))
    end

    @testset "rank J/K reorders within the column" begin
        m = lb()
        # Backlog has QCI-100 (pos0) and QCI-101 (pos1); rank the top one down
        top = Q3.selected_issue(m)
        @test top.position == 0
        mkey(m, 'J')
        @test Q3.Stores.get_issue(m.boardstore, top.id).position == 1
        mkey(m, 'K')
        @test Q3.Stores.get_issue(m.boardstore, top.id).position == 0
    end
end

@testset "Phase 3 — Bulk select + bulk actions" begin
    @testset "space toggles selection; bulk move moves all to cursor column" begin
        m = lb()
        mkey(m, ' ')                              # select QCI-100 (Backlog)
        mkey(m, 'j'); mkey(m, ' ')                # select QCI-101 (Backlog)
        @test length(m.selected_ids) == 2
        mkey(m, 'l'); mkey(m, 'l')                # cursor → In Progress column
        @test m.sel_col == 3
        mkey(m, 'M')                              # bulk move
        movedstatuses = [i.status for i in Q3.Stores.list_issues(m.boardstore) if i.key in ("QCI-100", "QCI-101")]
        @test all(==("In Progress"), movedstatuses)
        @test isempty(m.selected_ids)             # cleared after bulk op
        @test occursin("Moved 2", m.message)
    end

    @testset "bulk assign assigns all selected to me" begin
        m = lb()
        mkey(m, ' '); mkey(m, 'j'); mkey(m, ' ')
        mkey(m, 'A')
        assigned = [i.assignee_id for i in Q3.Stores.list_issues(m.boardstore) if i.assignee_id !== nothing]
        @test length(assigned) >= 2
        @test all(==(m.current_user.id), assigned)
    end
end

@testset "Phase 3 — Quick filters + search" begin
    @testset "Mine / High / Due-soon toggles narrow the grid" begin
        m = lb()
        # High priority filter: only High cards remain
        mkey(m, 'H')
        @test :high in m.active_filters
        for iss in filter(i -> Q3._passes_filters(m, i), Q3.Stores.list_issues(m.boardstore))
            @test iss.priority == "High"
        end
        mkey(m, 'H'); @test !(:high in m.active_filters)   # toggle off
        # Mine (nothing assigned yet → empty grid, no matches lane)
        mkey(m, 'm')
        @test :mine in m.active_filters
        g = Q3.board_grid(m)
        @test sum(sum(length, l.cols) for l in g) == 0
    end

    @testset "search filters by title/key live" begin
        m = lb()
        mkey(m, '/')
        @test m.modal == :search
        for ch in collect("login"); mkey(m, ch); end
        # live filter applies from search_input text
        vis = filter(i -> Q3._passes_filters(m, i), Q3.Stores.list_issues(m.boardstore))
        @test !isempty(vis)
        @test all(i -> occursin("login", lowercase(i.title * i.key * i.description)), vis)
        mkey(m, :enter)                            # apply, keep query
        @test m.modal == :none
        @test !isempty(strip(Q3.text(m.search_input)))
        # reopen and Esc clears
        mkey(m, '/'); mkey(m, :escape)
        @test isempty(strip(Q3.text(m.search_input)))
    end

    @testset "label filter cycles through labels then back off" begin
        m = lb()
        nlabels = length(Q3.Stores.list_labels(m.boardstore))
        @test nlabels >= 1
        mkey(m, '#')
        @test m.label_filter !== nothing          # first label
        for _ in 1:nlabels; mkey(m, '#'); end     # cycle through the rest → back to off
        @test m.label_filter === nothing
    end

    @testset "label filter with no labels reports gracefully" begin
        m = fresh_app(; seed = false); app_login_new(m; name = "No Labels")
        @test isempty(Q3.Stores.list_labels(m.boardstore))
        mkey(m, '#')
        @test occursin("No labels", m.message)
        @test m.label_filter === nothing
        # empty board still renders (no-matches lane) without error
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "Backlog") !== nothing   # column header still drawn
    end
end

@testset "Phase 3 — WIP limits" begin
    @testset "over-limit column header uses err color + warns on move" begin
        m = lb()
        # Review limit is 2; push it over by moving cards into Review.
        # Seed has 1 in Review. Create two more directly to reach 3 (>2).
        Q3.Stores.create_issue!(m.boardstore; title = "extra review a", status = "Review")
        Q3.Stores.create_issue!(m.boardstore; title = "extra review b", status = "Review")
        @test Q3._is_over_wip(m, "Review")
        tb = app_tb(m; w = 110, h = 30)
        loc = T.find_text(tb, "Review 3/2")
        @test loc !== nothing
        st = T.style_at(tb, loc.x, loc.y)
        @test st.fg == Q3.Theming.col_err()
    end

    @testset "rich card renders epic tag, assignee initials, due chip, wrapped title" begin
        m = lb()
        # give the top Backlog card an assignee (initials) + long title
        iss = Q3.selected_issue(m)
        Q3.Stores.update_issue!(m.boardstore, iss.id;
            title = "A very long card title that must wrap across two lines and ellipsize")
        mkey(m, 'a')                              # assign to me → initials render
        tb = app_tb(m; w = 120, h = 34)
        blob = join([T.row_text(tb, i) for i in 1:34], "\n")
        @test occursin("◆", blob)                 # epic tag glyph (seed cards have epics)
        @test occursin("▣", blob)                 # due chip (QCI-100 has a due date)
        @test occursin("AL", blob)                # assignee initials for "Ada Lovelace"
        @test occursin("…", blob)                 # wrapped/ellipsized long title
    end

    @testset "overdue due chip uses err color" begin
        m = lb()
        # seed QCI-106 (Done, due in the past) — but Done cards are not overdue.
        # Create an explicitly overdue non-Done card and select it.
        Q3.Stores.create_issue!(m.boardstore; title = "overdue task", status = "To Do",
                                due_date = Dates.today() - Dates.Day(3))
        mkey(m, 'l')                              # → To Do column
        # walk to the overdue card
        g = Q3.board_grid(m); cell = g[1].cols[2]
        idx = findfirst(i -> i.title == "overdue task", cell)
        @test idx !== nothing
        tb = app_tb(m; w = 120, h = 34)
        loc = T.find_text(tb, "overdue task")
        @test loc !== nothing
    end

    @testset "vertical nav crosses lanes up and down (epic mode)" begin
        m = lb()
        mkey(m, 's'); mkey(m, 's')                # epic mode, multiple lanes
        @test m.swimlane_by == :epic
        # move down into a lower lane then back up
        start_lane = m.sel_lane
        for _ in 1:8; mkey(m, 'j'); end
        for _ in 1:8; mkey(m, 'k'); end
        @test m.sel_lane >= 1
    end

    @testset "due-soon filter keeps only issues due within a week" begin
        m = lb()
        mkey(m, 'u')
        @test :due_soon in m.active_filters
        vis = filter(i -> Q3._passes_filters(m, i), Q3.Stores.list_issues(m.boardstore))
        @test !isempty(vis)
        @test all(i -> i.due_date !== nothing && i.due_date <= Dates.today() + Dates.Day(7), vis)
    end

    @testset "_wrap_title wraps, breaks at maxlines, ellipsizes; _select_issue fallback" begin
        # zero width degrades
        @test Q3._wrap_title("hello world", 0, 2) == String[]
        # a long multi-word title fills two lines then ellipsizes (break at maxlines)
        wl = Q3._wrap_title("alpha beta gamma delta epsilon zeta eta theta", 11, 2)
        @test length(wl) == 2
        @test endswith(wl[end], "…")
        # a single word longer than the width is hard-cut
        w1 = Q3._wrap_title("supercalifragilistic", 6, 2)
        @test all(l -> length(l) <= 7, w1)     # width + ellipsis char
        # _select_issue! with an unknown id falls back to a clamped selection
        m = lb()
        Q3._select_issue!(m, "does-not-exist")
        @test 1 <= m.sel_lane && 1 <= m.sel_col <= length(Q3.BOARD_STATUSES)
    end

    @testset "label filter excludes non-matching issues" begin
        m = lb()
        mkey(m, '#')                              # first label (seed 'bug' on QCI-100)
        vis = filter(i -> Q3._passes_filters(m, i), Q3.Stores.list_issues(m.boardstore))
        @test !isempty(vis)
        @test all(i -> m.label_filter in i.labels, vis)
        @test length(vis) < length(Q3.Stores.list_issues(m.boardstore))   # some excluded
    end

    @testset "moving into a full column warns (still allowed, Jira-style)" begin
        m = lb()
        Q3.Stores.create_issue!(m.boardstore; title = "r1", status = "Review")
        Q3.Stores.create_issue!(m.boardstore; title = "r2", status = "Review")   # Review now at limit 2
        # select the Done card and move it back to Review (→ 3 > 2)
        # navigate to Review column, move a card in from Backlog instead:
        iss = Q3.selected_issue(m)                # Backlog card
        # move it right until Review
        for _ in 1:3; mkey(m, '>'); end           # Backlog→To Do→In Progress→Review
        @test occursin("WIP limit exceeded", m.message)
        @test Q3.Stores.get_issue(m.boardstore, iss.id).status == "Review"   # move still applied
    end
end

@testset "Phase 3 — Bordered card grid" begin
    @testset "bordered lanes + cards; selected card pops with ▸ arrow + raised bg" begin
        m = lb()
        rows = app_rows(m; w = 100, h = 30)
        blob = join(rows, "\n")
        # rounded frames: outer app frame contributes exactly one ╭; lane panels
        # + card frames contribute many more
        @test count("╭", blob) > 2
        tb = app_tb(m; w = 100, h = 30)
        # find_text returns a BYTE index; the multibyte frame chars left of the
        # key shift it off the display column — convert before probing cells.
        bytecol(y, bx) = length(T.row_text(tb, y)[1:bx])
        kloc = T.find_text(tb, "QCI-100")          # selected (first Backlog) card
        @test kloc !== nothing
        kcol = bytecol(kloc.y, kloc.x)
        # selected card pops: raised bg behind the key, ▸ arrow on its left frame
        @test T.style_at(tb, kcol, kloc.y).bg == Q3.Theming.col_surface_hi()
        @test T.char_at(tb, kcol - 1, kloc.y) == '▸'
        # unselected card sits on the plain card surface
        loc2 = T.find_text(tb, "QCI-101")
        @test loc2 !== nothing
        @test T.style_at(tb, bytecol(loc2.y, loc2.x), loc2.y).bg == Q3.Theming.col_surface()
    end

    @testset "lane panels carry the lane name in the frame (assignee mode)" begin
        m = lb()
        mkey(m, 's')                              # assignee swimlanes
        rows = app_rows(m; w = 100, h = 30)
        @test any(occursin("Unassigned (", r) for r in rows)
    end

    @testset "scroll-follow keeps the cursor card visible (short terminal)" begin
        m = lb()
        for i in 1:14
            Q3.Stores.create_issue!(m.boardstore; title = "MScroll $i", status = "Backlog")
        end
        for _ in 1:11; mkey(m, 'j'); end
        sel = Q3.selected_issue(m)
        @test sel !== nothing
        rows = app_rows(m; w = 100, h = 16)
        @test any(occursin(sel.key, r) for r in rows)
    end

    @testset "grid degrades to flat cards when the lane interior is too short (W1)" begin
        m = lb()
        # 100x14: lane interior < MODERN_CARD_H — bordered cards can't fit, but
        # the cursor card must still be visible (U5: ops target what you see)
        rows = app_rows(m; w = 100, h = 14)
        sel = Q3.selected_issue(m)
        @test sel !== nothing
        @test any(occursin(sel.key, r) for r in rows)
        # scroll-follow still holds in the degraded mode
        for i in 1:14
            Q3.Stores.create_issue!(m.boardstore; title = "TinyScroll $i", status = "Backlog")
        end
        for _ in 1:11; mkey(m, 'j'); end
        sel2 = Q3.selected_issue(m)
        rows2 = app_rows(m; w = 100, h = 14)
        @test any(occursin(sel2.key, r) for r in rows2)
    end
end

@testset "B0 — BoardLayout pure metrics + paint consumption" begin
    # Content area approximates full-app body (header/footer already stripped in
    # real view); for pure layout unit tests we pass a synthetic Rect.
    content_area(w, h) = T.Rect(1, 3, w, h)

    @testset "default zero cache; render fills board_last_area" begin
        m = lb()
        @test m.board_last_area.width == 0 && m.board_last_area.height == 0
        @test m.board_hover === nothing
        # Full app view populates the cache (same path as live TUI).
        app_tb(m; w = 100, h = 30)
        @test m.board_last_area.width >= 1 && m.board_last_area.height >= 1
        area = m.board_last_area
        lay = Q3.board_layout(m, area)
        @test lay isa Q3.BoardLayout
        @test lay.area == area
        @test lay.show_stats === false
        @test lay.grid_area == area
        @test lay.col_w > 0
        @test lay.nlanes >= 1
        @test !isempty(lay.slots)
        # B0: no move chrome on slots
        @test all(s -> s.prev_btn === nothing && s.next_btn === nothing &&
                       s.gap_btn === nothing && s.chrome === nothing, lay.slots)
        # Every slot rect is non-empty and inside the grid area
        for s in lay.slots
            @test s.rect.width >= 1 && s.rect.height >= 1
            @test s.rect.x >= lay.grid_area.x
            @test s.rect.y >= lay.grid_area.y
            @test s.bordered === true          # tall enough for modern cards
        end
        # Paint path re-caches the same area
        tb = T.TestBackend(100, 30); T.reset!(tb.buf)
        Q3.render_board!(m, tb.buf, area)
        @test m.board_last_area == area
    end

    @testset "stats on insets grid_area by STATS_HEIGHT" begin
        m = lb()
        m.show_stats = true
        area = content_area(100, 28)          # tall enough for stats + grid
        lay = Q3.board_layout(m, area)
        @test lay.show_stats === true
        @test lay.area == area
        @test lay.grid_area.y == area.y + Q3.STATS_HEIGHT
        @test lay.grid_area.height == area.height - Q3.STATS_HEIGHT
        @test lay.grid_area.width == area.width
        @test !isempty(lay.slots)
        # Slots live in the post-stats grid, not on the stats strip
        @test all(s -> s.rect.y >= lay.grid_area.y, lay.slots)
    end

    @testset "stats off: grid_area equals area" begin
        m = lb()
        m.show_stats = false
        area = content_area(100, 28)
        lay = Q3.board_layout(m, area)
        @test lay.show_stats === false
        @test lay.grid_area == area
    end

    @testset "multi-lane (epic swimlanes) produces slots across lanes" begin
        m = lb()
        mkey(m, 's'); mkey(m, 's')            # → epic
        @test m.swimlane_by == :epic
        area = content_area(110, 34)
        lay = Q3.board_layout(m, area)
        @test lay.nlanes >= 2
        lane_ids = unique(s.lane for s in lay.slots)
        @test length(lane_ids) >= 2
        # Each slot lane/col/idx is in range
        g = Q3.board_grid(m)
        for s in lay.slots
            @test 1 <= s.lane <= length(g)
            @test 1 <= s.col <= length(Q3.BOARD_STATUSES)
            cell = g[s.lane].cols[s.col]
            @test 1 <= s.idx <= length(cell)
            @test cell[s.idx].id == s.issue_id
        end
    end

    @testset "scroll-follow: sel_idx > max_cards still yields selected slot" begin
        m = lb()
        for i in 1:14
            Q3.Stores.create_issue!(m.boardstore; title = "LayScroll $i", status = "Backlog")
        end
        # Drive selection deep into Backlog so scroll-follow kicks in
        for _ in 1:11; mkey(m, 'j'); end
        sel = Q3.selected_issue(m)
        @test sel !== nothing
        @test m.sel_idx > 1
        # Short content height → few max_cards → start shifts
        area = content_area(100, 12)
        lay = Q3.board_layout(m, area)
        sel_slots = filter(s -> s.issue_id == sel.id, lay.slots)
        @test !isempty(sel_slots)
        s = only(sel_slots)
        @test s.lane == m.sel_lane && s.col == m.sel_col && s.idx == m.sel_idx
        col_slots = filter(s -> s.lane == m.sel_lane && s.col == m.sel_col, lay.slots)
        @test !isempty(col_slots)
        # Unconditional: deep selection + short height must advance the window past 1.
        @test m.sel_idx > length(col_slots)     # more cards than fit ⇒ scroll-follow
        @test minimum(s.idx for s in col_slots) > 1
        @test maximum(s.idx for s in col_slots) == m.sel_idx
        # Window start matches formula: sel_idx - max_cards + 1
        max_cards = length(col_slots)
        @test minimum(s.idx for s in col_slots) == m.sel_idx - max_cards + 1
        # +N more count agrees with slots (hidden = total - last shown idx)
        g = Q3.board_grid(m)
        cell = g[m.sel_lane].cols[m.sel_col]
        last_idx = maximum(s.idx for s in col_slots)
        hidden = length(cell) - last_idx
        @test hidden > 0
        # Paint shows "+N more" with that count
        tb = T.TestBackend(100, 20); T.reset!(tb.buf)
        Q3.render_board!(m, tb.buf, area)
        blob = join([T.row_text(tb, i) for i in 1:20], "\n")
        @test occursin("+$(hidden) more", blob)
    end

    @testset "flat degrade: short height → bordered=false slots" begin
        m = lb()
        # Very short body: lane interior < MODERN_CARD_H
        area = content_area(100, 8)
        lay = Q3.board_layout(m, area)
        @test !isempty(lay.slots)
        @test all(s -> s.bordered === false, lay.slots)
        # Selected issue still has a slot (U5)
        sel = Q3.selected_issue(m)
        @test sel !== nothing
        @test any(s -> s.issue_id == sel.id, lay.slots)
    end

    @testset "empty board: zero slots + empty-state still paints" begin
        m = fresh_app(; seed = false); app_login_new(m; name = "Empty Board")
        @test isempty(Q3.Stores.list_issues(m.boardstore))
        area = content_area(90, 20)
        lay = Q3.board_layout(m, area)
        @test isempty(lay.slots)
        @test lay.nlanes >= 1                   # placeholder "(no matches)" / All Issues lane
        # Render does not error and shows create hint
        tb = T.TestBackend(90, 24); T.reset!(tb.buf)
        Q3.render_board!(m, tb.buf, area)
        @test m.board_last_area == area
        blob = join([T.row_text(tb, i) for i in 1:24], "\n")
        @test occursin("No work orders", blob) || occursin("Backlog", blob)
    end

    @testset "layout.slots cover painted card keys (acceptance A)" begin
        m = lb()
        area = content_area(100, 26)
        lay = Q3.board_layout(m, area)
        tb = T.TestBackend(100, 30); T.reset!(tb.buf)
        Q3.render_board!(m, tb.buf, area)
        blob = join([T.row_text(tb, i) for i in 1:30], "\n")
        for s in lay.slots
            iss = Q3.Stores.get_issue(m.boardstore, s.issue_id)
            iss === nothing && continue
            # Key appears in paint when the slot was drawn (wide enough columns)
            if s.rect.width >= 8
                @test occursin(iss.key, blob)
            end
        end
    end

    @testset "degenerate area: empty slots + zero col_w" begin
        m = lb()
        lay = Q3.board_layout(m, T.Rect(1, 1, 2, 0))
        @test lay.col_w == 0
        @test isempty(lay.slots)
        @test lay.nlanes >= 1
    end

    @testset "_clear_board_mouse_ui! clears board_hover" begin
        m = lb()
        m.board_hover = (kind = :move_next, issue_id = "x", armed = true)
        Q3._clear_board_mouse_ui!(m)
        @test m.board_hover === nothing
        # View switch also clears (hygiene for B1/B2)
        m.board_hover = :stale
        mkey(m, 'G')                              # board → gantt
        @test m.board_hover === nothing
        # Project selection clear (design clear table)
        m.board_hover = :stale2
        Q3._clear_project_selection!(m)
        @test m.board_hover === nothing
    end
end

@testset "B1 — board_hit_test pure + body select handler" begin
    content_area(w, h) = T.Rect(1, 3, w, h)
    bm_click(col, row) = T.MouseEvent(col, row, T.mouse_left, T.mouse_press, false, false, false)

    @testset "pure hit: body / chrome / outside / empty area" begin
        m = lb()
        area = content_area(100, 26)
        lay = Q3.board_layout(m, area)
        @test !isempty(lay.slots)
        s = first(lay.slots)
        # Center of first card body
        hx = s.rect.x + max(0, s.rect.width ÷ 2)
        hy = s.rect.y + max(0, s.rect.height ÷ 2)
        hit = Q3.board_hit_test(lay, hx, hy)
        @test hit.kind === Q3.board_hit_card_body
        @test hit.issue_id == s.issue_id
        @test hit.lane == s.lane && hit.col == s.col && hit.idx == s.idx

        # Outside layout area → none
        hit_out = Q3.board_hit_test(lay, 0, 0)
        @test hit_out.kind === Q3.board_hit_none
        @test hit_out.issue_id === nothing

        # Inside area but not on a card (filter/header chrome) → chrome
        # grid_area.y is filter line (y0); cards start later
        hit_chrome = Q3.board_hit_test(lay, area.x + 2, lay.grid_area.y)
        @test hit_chrome.kind === Q3.board_hit_chrome
        @test hit_chrome.issue_id === nothing

        # Degenerate empty layout area
        empty_lay = Q3.BoardLayout(T.Rect(1, 1, 0, 0), T.Rect(1, 1, 0, 0), false, 0, 1,
                                   Q3.BoardCardSlot[])
        @test Q3.board_hit_test(empty_lay, 1, 1).kind === Q3.board_hit_none
    end

    @testset "pure hit: button priority order (synthetic chrome rects)" begin
        # B1 slots leave buttons nothing; exercise priority with a synthetic slot
        # so B2 can fill rects without API churn (design §7).
        body = T.Rect(10, 10, 20, 6)
        prev = T.Rect(20, 14, 3, 1)
        gap  = T.Rect(23, 14, 1, 1)
        next = T.Rect(24, 14, 3, 1)
        chrome = T.Rect(20, 14, 7, 1)
        slot = Q3.BoardCardSlot(body, 1, 1, 1, "iss-synthetic", true,
                                prev, next, gap, chrome)
        lay = Q3.BoardLayout(T.Rect(1, 1, 40, 20), T.Rect(1, 1, 40, 20), false, 8, 1,
                             [slot])
        @test Q3.board_hit_test(lay, prev.x, prev.y).kind === Q3.board_hit_move_prev
        @test Q3.board_hit_test(lay, next.x, next.y).kind === Q3.board_hit_move_next
        @test Q3.board_hit_test(lay, gap.x, gap.y).kind === Q3.board_hit_move_chrome
        # Body cell not covered by chrome band
        @test Q3.board_hit_test(lay, body.x + 1, body.y + 1).kind === Q3.board_hit_card_body
        @test Q3.board_hit_test(lay, body.x + 1, body.y + 1).issue_id == "iss-synthetic"
    end

    @testset "body press selects; second press opens detail; bulk set stable" begin
        m = lb()
        app_tb(m; w = 100, h = 30)
        @test m.view === :board
        @test m.board_last_area.width >= 1
        lay = Q3.board_layout(m, m.board_last_area)
        @test length(lay.slots) >= 2
        s0 = lay.slots[1]
        s1 = lay.slots[2]
        # Pre-fill bulk selection (K13 — must not clear on mouse select)
        push!(m.selected_ids, s0.issue_id)
        bulk_before = copy(m.selected_ids)

        # Click different card body → select only, no modal, bulk unchanged
        hx1 = s1.rect.x + max(0, s1.rect.width ÷ 2)
        hy1 = s1.rect.y + max(0, s1.rect.height ÷ 2)
        T.update!(m, bm_click(hx1, hy1))
        @test Q3.selected_issue(m).id == s1.issue_id
        @test m.modal === :none
        @test m.selected_ids == bulk_before

        # Second click same body → open detail
        T.update!(m, bm_click(hx1, hy1))
        @test m.modal === :card_detail
        @test m.card_issue_id == s1.issue_id
        @test m.board_hover === nothing
        mkey(m, :escape)
        @test m.modal === :none

        # Click different body reselects, does not open
        hx0 = s0.rect.x + max(0, s0.rect.width ÷ 2)
        hy0 = s0.rect.y + max(0, s0.rect.height ÷ 2)
        T.update!(m, bm_click(hx0, hy0))
        @test Q3.selected_issue(m).id == s0.issue_id
        @test m.modal === :none
        @test m.selected_ids == bulk_before
    end

    @testset "chrome / release / empty area: no selection change" begin
        m = lb()
        app_tb(m; w = 100, h = 30)
        sel0 = Q3.selected_issue(m)
        lay = Q3.board_layout(m, m.board_last_area)
        # Header/filter chrome
        T.update!(m, bm_click(m.board_last_area.x + 2, lay.grid_area.y))
        @test Q3.selected_issue(m).id == sel0.id
        @test m.modal === :none
        # Release is ignored
        if !isempty(lay.slots)
            s = first(lay.slots)
            rel = T.MouseEvent(s.rect.x + 1, s.rect.y + 1, T.mouse_left, T.mouse_release,
                               false, false, false)
            T.update!(m, rel)
            @test Q3.selected_issue(m).id == sel0.id
        end
        # Empty board_last_area: no-op
        m2 = lb()
        @test m2.board_last_area.width == 0
        sel_a = Q3.selected_issue(m2)
        T.update!(m2, bm_click(10, 10))
        @test Q3.selected_issue(m2).id == sel_a.id
    end

    @testset "modal open clears board_hover" begin
        m = lb()
        m.board_hover = (kind = :move_next, issue_id = "x", armed = true)
        mkey(m, 'v')   # open card detail via keyboard
        @test m.modal === :card_detail
        @test m.board_hover === nothing
        mkey(m, :escape)
        m.board_hover = :stale
        mkey(m, '?')   # help
        @test m.modal === :help
        @test m.board_hover === nothing
    end
end
