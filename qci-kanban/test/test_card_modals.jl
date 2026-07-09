# Phase 3 — card detail / create / edit / confirm / search / new-sprint modals.
# All text entry goes through the focus router; Tab cycles; digits type into
# every field. Driven only via update!. Helpers from test_app_shell.jl.

Qm = QciKanban
lbm() = (m = Qm.AppModel(; token_path = tempname(), secret = "s"); app_login_new(m; name = "Grace H"); m)
k!(m, x) = T.update!(m, T.KeyEvent(x))
typ!(m, s) = (for ch in collect(s); T.update!(m, T.KeyEvent(ch)); end)

@testset "Phase 3 — Create card modal" begin
    @testset "n opens NEW CARD; save creates an issue (digits type into points)" begin
        m = lbm()
        n0 = length(Qm.Stores.list_issues(m.boardstore))
        k!(m, 'n')
        @test m.modal == :card_edit
        @test m.card_issue_id === nothing
        tb = app_tb(m; w = 100, h = 30)
        @test T.find_text(tb, "NEW CARD") !== nothing
        typ!(m, "Write the tests")           # title (focused first)
        k!(m, :tab)                          # → description
        typ!(m, "cover everything")
        k!(m, :tab)                          # → priority selector
        k!(m, :tab)                          # → points input
        typ!(m, "8")                         # DIGIT types into the field (v1 bug impossible)
        @test Qm.text(m.edit_form.points_input) == "8"
        k!(m, :enter)                        # save
        @test m.modal == :none
        issues = Qm.Stores.list_issues(m.boardstore)
        @test length(issues) == n0 + 1
        made = first(filter(i -> i.title == "Write the tests", issues))
        @test made.story_points == 8
        @test made.description == "cover everything"
        @test any(a.kind == :created for a in Qm.Stores.list_activity(m.boardstore, made.id))
    end

    @testset "empty title is rejected (no issue, modal stays)" begin
        m = lbm()
        n0 = length(Qm.Stores.list_issues(m.boardstore))
        k!(m, 'n'); k!(m, :enter)
        @test m.modal == :card_edit
        @test occursin("Title is required", m.message)
        @test length(Qm.Stores.list_issues(m.boardstore)) == n0
        k!(m, :escape)
        @test m.modal == :none
    end

    @testset "selectors cycle with arrows; priority selector changes value" begin
        m = lbm()
        k!(m, 'n')
        typ!(m, "Prio card")
        # jump focus to priority selector (index 3)
        Qm.focus_index!(m.focus, 3)
        before = Qm.sel_current_value(m.edit_form.priority_sel)
        k!(m, :right)
        after = Qm.sel_current_value(m.edit_form.priority_sel)
        @test before != after
        k!(m, :left)
        @test Qm.sel_current_value(m.edit_form.priority_sel) == before
    end

    @testset "labels multi-select toggles the highlighted chip on space" begin
        m = lbm()
        k!(m, 'n'); typ!(m, "Labeled")
        Qm.focus_index!(m.focus, 10)         # labels multiselect is last
        ms = m.edit_form.labels_ms
        if !isempty(ms.options)
            @test !ms.checked[ms.cursor]
            k!(m, ' ')
            @test ms.checked[ms.cursor]
            k!(m, :enter)
            made = first(filter(i -> i.title == "Labeled", Qm.Stores.list_issues(m.boardstore)))
            @test !isempty(made.labels)
        end
    end
end

@testset "Phase 3 — Edit card modal" begin
    @testset "e loads the selected issue; save updates it" begin
        m = lbm()
        iss = Qm.selected_issue(m)
        k!(m, 'e')
        @test m.modal == :card_edit
        @test m.card_issue_id == iss.id
        @test Qm.text(m.edit_form.title_input) == iss.title
        # append to the title
        typ!(m, "!")
        k!(m, :enter)
        @test m.modal == :none
        @test Qm.Stores.get_issue(m.boardstore, iss.id).title == iss.title * "!"
        @test any(a.kind == :updated for a in Qm.Stores.list_activity(m.boardstore, iss.id))
    end
end

@testset "Phase 3 — Card detail + comments + activity" begin
    @testset "v opens detail; Enter submits a comment; activity tail shows" begin
        m = lbm()
        iss = Qm.selected_issue(m)
        k!(m, 'a')                            # generate an activity entry (assign)
        k!(m, 'v')
        @test m.modal == :card_detail
        tb = app_tb(m; w = 100, h = 30)
        @test T.find_text(tb, iss.key) !== nothing
        @test T.find_text(tb, "COMMENTS") !== nothing
        @test T.find_text(tb, "ACTIVITY") !== nothing
        typ!(m, "looks good")
        k!(m, :enter)                         # submit comment
        cs = Qm.Stores.list_comments(m.boardstore, iss.id)
        @test any(c.body == "looks good" for c in cs)
        @test isempty(Qm.text(m.comment_input))   # cleared after submit
        k!(m, :escape)
        @test m.modal == :none
    end

    @testset "empty comment is not stored" begin
        m = lbm()
        iss = Qm.selected_issue(m)
        k!(m, 'v'); k!(m, :enter)
        @test isempty(Qm.Stores.list_comments(m.boardstore, iss.id))
    end

    # Enter opens the same detail modal as 'v'. The overlay must be a compact,
    # centered panel — not a near-fullscreen sheet — and must not leave modern
    # board-card surface backgrounds showing through as colored rectangles.
    @testset "Enter opens compact centered detail; no board color-rect bleed" begin
        m = lbm()
        iss = Qm.selected_issue(m)
        k!(m, :enter)
        @test m.modal == :card_detail
        W, H = 100, 30
        tb = app_tb(m; w = W, h = H)
        loc = T.find_text(tb, iss.key)
        @test loc !== nothing
        # measure the modal box on the title row (╭ … ╮)
        left_x = right_x = 0
        for x in 1:W
            c = T.char_at(tb, x, loc.y)
            c == '╭' && (left_x = x)
            c == '╮' && (right_x = x)
        end
        @test left_x > 0 && right_x > left_x
        modal_w = right_x - left_x + 1
        @test modal_w <= 72                          # compact, not near-fullscreen
        @test modal_w < W - 10
        # horizontally centered inside the outer frame (cols 2 .. W-1)
        left_margin = left_x - 2
        right_margin = (W - 1) - right_x
        @test abs(left_margin - right_margin) <= 2
        # vertical: box has a bottom ╰ and is shorter than the content band
        bottom_y = loc.y
        for y in loc.y:H
            if T.char_at(tb, left_x, y) == '╰'
                bottom_y = y
                break
            end
        end
        modal_h = bottom_y - loc.y + 1
        @test modal_h <= 18
        @test modal_h < H - 10
        # board card surfaces must not paint through (Tachikoma preserves bg on
        # NoColor writes — a space-only clear leaves colored rectangles)
        surf = Qm.Theming.col_surface()
        surf_hi = Qm.Theming.col_surface_hi()
        n_card_bg = count(xy -> begin
            bg = T.style_at(tb, xy[1], xy[2]).bg
            bg == surf || bg == surf_hi
        end, [(x, y) for y in 1:H for x in 1:W])
        @test n_card_bg == 0
        # content still present
        @test T.find_text(tb, "COMMENTS") !== nothing
    end
end

@testset "Phase 3 — Delete confirm (single + bulk)" begin
    @testset "d asks to confirm; y deletes, n cancels" begin
        m = lbm()
        iss = Qm.selected_issue(m)
        n0 = length(Qm.Stores.list_issues(m.boardstore))
        k!(m, 'd')
        @test m.modal == :confirm
        tb = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb, "CONFIRM") !== nothing
        k!(m, 'n')                            # cancel
        @test m.modal == :none
        @test length(Qm.Stores.list_issues(m.boardstore)) == n0
        # now really delete
        k!(m, 'd'); k!(m, 'y')
        @test m.modal == :none
        @test Qm.Stores.get_issue(m.boardstore, iss.id) === nothing
        @test length(Qm.Stores.list_issues(m.boardstore)) == n0 - 1
    end

    @testset "bulk delete D removes all selected after confirm" begin
        m = lbm()
        k!(m, ' '); k!(m, 'j'); k!(m, ' ')     # select 2 in Backlog
        n0 = length(Qm.Stores.list_issues(m.boardstore))
        k!(m, 'D')
        @test m.modal == :confirm
        k!(m, :enter)                          # confirm via Enter
        @test length(Qm.Stores.list_issues(m.boardstore)) == n0 - 2
        @test isempty(m.selected_ids)
    end
end

@testset "Phase 3 — Modal no-bleed at 3 sizes" begin
    for (w, h) in [(80, 24), (100, 30), (60, 18)]
        @testset "card_edit clears board bleed at $(w)x$(h)" begin
            m = lbm(); k!(m, 'n'); typ!(m, "X")
            tb = app_tb(m; w = w, h = h)
            @test T.find_text(tb, "NEW CARD") !== nothing
            @test T.find_text(tb, "QCI-100") === nothing        # board card must not bleed
            @test T.find_text(tb, "Set up project") === nothing
        end
        @testset "card_detail clears board bleed at $(w)x$(h)" begin
            m = lbm(); k!(m, 'v')
            tb = app_tb(m; w = w, h = h)
            @test T.find_text(tb, "COMMENTS") !== nothing
            @test T.find_text(tb, "QCI-101") === nothing
        end
        @testset "confirm clears board bleed at $(w)x$(h)" begin
            m = lbm(); k!(m, 'd')
            tb = app_tb(m; w = w, h = h)
            @test T.find_text(tb, "CONFIRM") !== nothing
            @test T.find_text(tb, "QCI-100") === nothing
        end
    end
end

@testset "Phase 3 — Modal edge cases" begin
    @testset "invalid / empty story points parse to nothing" begin
        @test Qm._parse_points("") === nothing
        @test Qm._parse_points("abc") === nothing
        @test Qm._parse_points("-2") === nothing
        @test Qm._parse_points("7") == 7
    end

    @testset "bulk delete with empty selection is a no-op (no confirm modal)" begin
        m = lbm()
        k!(m, 'D')
        @test m.modal == :none
        @test m.confirm_kind == :none
    end

    @testset "confirm modal renders bulk + close-sprint messages" begin
        m = lbm()
        k!(m, ' '); k!(m, 'j'); k!(m, ' ')          # select 2
        k!(m, 'D')
        tb = app_tb(m; w = 90, h = 26)
        @test T.find_text(tb, "Delete 2 selected") !== nothing
        k!(m, 'n')
        # close-sprint confirm message
        m2 = lbm(); k!(m2, 'C'); k!(m2, 'K')        # backlog
        k!(m2, 'S'); k!(m2, 'X')                    # start then request close
        @test m2.modal == :confirm
        tb2 = app_tb(m2; w = 90, h = 26)
        @test T.find_text(tb2, "roll back") !== nothing
    end

    @testset "comment submit is a no-op when no card is open" begin
        m = lbm()
        Qm._submit_comment!(m)                      # card_issue_id === nothing
        @test m.modal == :none
    end

    @testset "save with empty edit_form closes safely" begin
        m = lbm()
        m.edit_form = nothing
        Qm._save_edit!(m)
        @test m.modal == :none
    end

    @testset "editing assignee enqueues an assigned notification" begin
        m = Qm.AppModel(; token_path = tempname(), secret = "s")
        m.notifier = Qm.Notify.OutboxNotifier(m.boardstore)
        app_login_new(m; name = "Router R")
        iss = Qm.selected_issue(m)                 # unassigned
        k!(m, 'e')
        Qm.focus_index!(m.focus, 11)               # assignee selector (after WO fields)
        k!(m, :right)                              # (none) → the one user
        @test Qm.sel_current_value(m.edit_form.assignee_sel) !== nothing
        k!(m, :enter)                              # save
        pend = Qm.Stores.pending_outbox(m.boardstore)
        @test any(r["event_kind"] == "assigned" for r in pend)
        @test Qm.Stores.get_issue(m.boardstore, iss.id).assignee_id == m.current_user.id
    end

    @testset "new-sprint empty name is rejected" begin
        m = lbm(); k!(m, 'C'); k!(m, 'K')          # backlog
        k!(m, 'n')                                 # new sprint modal
        @test m.modal == :new_sprint
        k!(m, :enter)                              # empty name
        @test occursin("Sprint name required", m.message)
    end

    @testset "search + detail-with-description + comments actually render" begin
        m = lbm()
        # search modal renders
        k!(m, '/'); typ!(m, "board")
        tb = app_tb(m; w = 90, h = 24)
        @test T.find_text(tb, "SEARCH") !== nothing
        @test T.find_text(tb, "Query") !== nothing
        k!(m, :escape)
        # add a description to the selected card, then view + comment + render
        iss = Qm.selected_issue(m)
        k!(m, 'e'); typ!(m, " more")               # tweak title (form focused on title)
        Qm.focus_index!(m.focus, 2); typ!(m, "detailed description here")
        T.update!(m, T.KeyEvent(:ctrl, 's'))       # Desc is a TextArea: Enter=newline, ^S saves (U6)
        k!(m, 'v'); typ!(m, "first comment"); k!(m, :enter)   # comment stored
        tb2 = app_tb(m; w = 100, h = 30)                      # re-render with comment present
        @test T.find_text(tb2, "COMMENTS") !== nothing
        @test T.find_text(tb2, "first comment") !== nothing
        @test T.find_text(tb2, "detailed description") !== nothing
    end
end

@testset "Phase 3 — PROPERTY: focused editor absorbs J/K/M/A/D/s + digits (card_edit)" begin
    # In the edit form, printable chars (incl. would-be shortcuts and digits)
    # must only mutate the focused text editor, never board/modal state.
    m = lbm(); k!(m, 'n')                     # card_edit, title focused (index 1)
    for ch in ['J', 'K', 'M', 'A', 'D', 's', 'q', '<', '>', '1', '9', '0']
        before = Qm.text(m.edit_form.title_input)
        snap = (m.modal, m.view, m.quit)
        k!(m, ch)
        @test Qm.text(m.edit_form.title_input) == before * string(ch)
        @test (m.modal, m.view, m.quit) == snap
    end
    # description field (index 2) — digits included
    Qm.focus_index!(m.focus, 2)
    for ch in ['5', 'd', 'K']
        before = Qm.text(m.edit_form.desc_area)
        k!(m, ch)
        @test Qm.text(m.edit_form.desc_area) == before * string(ch)
    end
end

@testset "Phase 3 — bad date format in new card: popup warning, can save anyway, informs YYYY-MM-DD format" begin
    # RED test for the required behavior (currently blocks with status msg only, no popup, no save-allow)
    m = lbm()
    n0 = length(Qm.Stores.list_issues(m.boardstore))
    k!(m, 'n')
    @test m.modal == :card_edit
    typ!(m, "BadFormatDate")
    # jump to start date field (editors: 1 title… 12 start, 13 due — see design §4.4)
    Qm.focus_index!(m.focus, 12)
    typ!(m, "not-a-valid-date")
    k!(m, :enter)   # trigger save attempt
    # Should show popup (confirm modal) with warning, not just status + block
    @test m.modal == :confirm
    @test m.confirm_kind == :bad_date
    tb = app_tb(m; w = 80, h = 20)
    @test T.find_text(tb, "WARNING") !== nothing || T.find_text(tb, "Invalid") !== nothing
    @test T.find_text(tb, "YYYY-MM-DD") !== nothing || T.find_text(tb, "format") !== nothing
    # can save anyway with 'y'
    k!(m, 'y')
    @test m.modal == :none
    issues = Qm.Stores.list_issues(m.boardstore)
    @test length(issues) == n0 + 1
    made = first(filter(i -> i.title == "BadFormatDate", issues))
    @test made.start_date === nothing  # bad date not persisted
    @test occursin("BadFormatDate", m.message) || m.message == "" || occursin("Created", m.message)  # saved
end
