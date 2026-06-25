# ═══════════════════════════════════════════════════════════════════════
# Cyberdeck ── Tachikoma Neural Interface (OUTRUN Cyberpunk Demo)
#
# Phases 1 (scaff) + 2(keys/cmds) + 3(full view/widgets/layouts/Canvas) + 4(runner)
# Elm-style @kwdef mutable struct + should_quit + update! + view.
# Uses: tick+split_layout+Block+Gauge/BarChart/Sparkline/BigText/SelectableList/TextInput/StatusBar
# Canvas: create_canvas + clear + line!/arc!/set_point! + sin + fbm/noise/pulse for mesh
# Cmds: pulse/hack/boost/clear/step/run/pause (+ direct keys); styled logs via ListItem
# Full TestBackend coverage in test_cyberdeck.jl
# Theme: OUTRUN (synthwave magenta/cyan)
# Run via: julia --project=. -e 'using TachikomaUITest; TachikomaUITest.cyberdeck()'
# ═══════════════════════════════════════════════════════════════════════

using Tachikoma
@tachikoma_app

@kwdef mutable struct Cyberdeck <: Model
    quit::Bool = false
    tick::Int = 0
    paused::Bool = false  # minor: synced to running for pause/run; used in view guards; was previously dead
    running::Bool = true
    pulse_ttl::Int = 0
    hacked::Bool = false
    boost::Float64 = 1.0

    # Input + logs (Phase 2) — use ListItem for styled appends
    input::TextInput = TextInput(; focused=true)
    logs::Vector{ListItem} = ListItem[]
    log_selected::Int = 1

    # Live sim state (Phase 3)
    sync::Float64 = 0.92
    cpu::Float64 = 0.47
    firewall::Float64 = 0.81
    packet_history::Vector{Float64} = fill(0.4, 24)
    neural_history::Vector{Float64} = zeros(Float64, 48)
end

should_quit(m::Cyberdeck) = m.quit

# ── Core Elm callbacks (stubs for Phase 1) ─────────────────────────────

function update!(m::Cyberdeck, evt::KeyEvent)
    # Phase 2+: routing fixed for input priority. list nav (j/k/arrows) kept for nav.
    # Input handle moved first so typing always reaches input (fixes hotkeys stealing 'p' for "pulse" etc).
    # Special hotkey (space) only if text empty before input handling; letter hotkeys r/p/a removed to allow typing cmds.
    if evt.key == :escape || (evt.key == :char && evt.char == 'q')
        m.quit = true
        return
    end

    # List nav (for logs): arrows + vim j/k ; page/home  -- kept before input
    nlogs = length(m.logs)
    if nlogs > 0
        if evt.key == :up || (evt.key == :char && evt.char == 'k')
            m.log_selected = max(1, m.log_selected - 1)
            return
        elseif evt.key == :down || (evt.key == :char && evt.char == 'j')
            m.log_selected = min(nlogs, m.log_selected + 1)
            return
        elseif evt.key == :home
            m.log_selected = 1
            return
        elseif evt.key == :end_key
            m.log_selected = nlogs
            return
        end
    end

    # Special hotkey space only (step) -- triggers only if text(m.input) empty *before handling* (to input).
    # Letters r/p/a not intercepted here (moved input first) so they reach typing for "pulse","run",etc.
    if evt.key == :char && evt.char == ' ' && isempty(text(m.input))
        step!(m)
        append_log!(m, "STEP", tstyle(:accent))
        return
    end

    # Route to input FIRST (critical: move before would-be letter hotkeys) -- typing chars always reach
    if handle_key!(m.input, evt)
        return
    end

    # Parse on enter (if not consumed earlier)
    if evt.key == :enter
        cmd = strip(text(m.input))
        clear!(m.input)
        if !isempty(cmd)
            handle_command!(m, lowercase(cmd))
        end
        return
    end
end

# ── Command parser + log helper (Phase 2) ──────────────────────────────

function append_log!(m::Cyberdeck, msg::AbstractString, sty::Style = tstyle(:text))
    push!(m.logs, ListItem(String(msg), sty))
    # cap ~32
    while length(m.logs) > 32
        popfirst!(m.logs)
    end
    m.log_selected = length(m.logs)
end

function handle_command!(m::Cyberdeck, cmd::AbstractString)
    if cmd == "pulse"
        m.pulse_ttl = max(m.pulse_ttl, 25)
        append_log!(m, "PULSE triggered", tstyle(:accent))
    elseif cmd == "hack"
        m.hacked = !m.hacked
        append_log!(m, m.hacked ? "HACK ENGAGED" : "HACK DISENGAGED", tstyle(:error))
    elseif cmd == "boost"
        m.boost = min(2.0, m.boost + 0.3)
        append_log!(m, "BOOST applied ($(round(m.boost;digits=1))x)", tstyle(:primary))
    elseif cmd == "clear"
        empty!(m.logs)
        m.log_selected = 1
        push!(m.logs, ListItem("logs cleared", tstyle(:text_dim)))  # one entry
    elseif cmd == "step"
        step!(m)
        append_log!(m, "STEP executed", tstyle(:accent))
    elseif cmd == "run"
        m.running = true
        m.paused = false
        append_log!(m, "RUN engaged", tstyle(:success))
    elseif cmd == "pause"
        m.running = false
        m.paused = true
        append_log!(m, "PAUSED", tstyle(:warning))
    else
        append_log!(m, "unknown cmd: $cmd", tstyle(:text_dim))
    end
end

function view(m::Cyberdeck, f::Frame)
    # Phase 3 full rich: tick, step if running, split_layouts, all widgets, Canvas mesh, Blocks
    buf = f.buffer
    area = f.area

    # Small area early return (per plan) -- mutations now after guard (address review)
    if area.width < 20 || area.height < 8
        set_string!(buf, area.x, area.y, "CYBERDECK (small area)", tstyle(:text_dim))
        return
    end

    # tick/step mutations after guard (Tachikoma demo style ok; tests invoke view on sizes that pass)
    if !m.paused
        m.tick += 1
    end
    if m.running && !m.paused
        step!(m)
    end


    # ── Outer block ──
    outer = Block(
        title = "TACHIKOMA NEURAL INTERFACE",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold=true),
    )
    main = render(outer, area, buf)

    # Layout rows: header( BigText ~6), gauges(~3), viz(Fill), bottom(~7 logs+input), status(1)
    row_layout = Layout(Vertical, [Fixed(6), Fixed(3), Fill(), Fixed(7), Fixed(1)])
    rows = split_layout(row_layout, main)
    length(rows) < 5 && return

    header_area = rows[1]
    gauge_area = rows[2]
    viz_area = rows[3]
    bottom_area = rows[4]
    status_area = rows[5]

    # ── Header: BigText TACHIKOMA (centered) + tick info ──
    bt = BigText("TACHIKOMA"; style = tstyle(:primary, bold=true))
    tw, _ = intrinsic_size(bt)
    tx = header_area.x + max(0, (header_area.width - tw) ÷ 2)
    title_r = Rect(tx, header_area.y, min(tw, header_area.width), 5)
    render(bt, title_r, buf)

    # subtitle line
    sub_y = header_area.y + 5
    if sub_y <= bottom(header_area)
        sub = "OUTRUN  •  tick=$(m.tick)  •  $(m.running ? "RUN" : "PAUSE")$(m.hacked ? "  [HACKED]" : "")"
        sx = header_area.x + max(0, (header_area.width - length(sub)) ÷ 2)
        set_string!(buf, sx, sub_y, sub, tstyle(:accent, dim=true))
    end

    # ── Gauges row (SYNC / CPU / FIREWALL) ──
    gcols = split_layout(Layout(Horizontal, [Fill(), Fixed(1), Fill(), Fixed(1), Fill()]), gauge_area)
    if length(gcols) >= 5
        function _render_gauge(ga, val, label, sty)
            if ga.height >= 1 && ga.width >= 6
                render(Gauge(val;
                    label = "$(label) $(round(Int, val*100))%",
                    filled_style = sty,
                    empty_style = tstyle(:text_dim, dim=true),
                    tick = m.tick),
                    ga, buf)
            end
        end
        _render_gauge(gcols[1], m.sync,     "SYNC",     tstyle(:primary))
        _render_gauge(gcols[3], m.cpu,      "CPU",      tstyle(:secondary))
        _render_gauge(gcols[5], m.firewall, "FIREWALL", tstyle(:accent))
    end

    # ── Viz split: Canvas (left) + charts (right: Bar packets + Spark neural) ──
    viz_cols = split_layout(Layout(Horizontal, [Fill(), Fixed(1), Percent(38)]), viz_area)
    if length(viz_cols) >= 3
        canvas_area = viz_cols[1]
        charts_area = viz_cols[3]

        # Canvas mesh: pulsing grid + arcs + fbm/noise points + pulse ttl effect
        if canvas_area.width >= 6 && canvas_area.height >= 4
            cstyle = m.pulse_ttl > 0 ? tstyle(:accent) : tstyle(:primary)
            c = create_canvas(canvas_area.width, canvas_area.height; style = cstyle)
            dw, dh = canvas_dot_size(c)
            clear!(c)

            # Pulsing grid
            gp = pulse(m.tick; period=18, lo=0.6, hi=1.0)
            gstep = max(3, round(Int, 6 - 2 * gp))
            for x in 0:gstep:dw-1
                for y in 0:2:dh-1
                    set_point!(c, x, y)
                end
            end
            for y in 0:gstep:dh-1
                for x in 0:3:dw-1
                    set_point!(c, x, y)
                end
            end

            # Arcs (2-3) using sin(tick)
            cx, cy = dw ÷ 2, dh ÷ 2
            for i in 1:3
                r = max(3, round(Int, min(dw, dh) * (0.2 + 0.12*i + 0.03*sin(m.tick/11.0 + i))))
                arc!(c, cx + (i-2)*2, cy -1, r, 30.0 + i*8, 150.0 - i*5)
            end

            # Randomish points via fbm + noise + tick
            dens = 0.12 + 0.06 * pulse(m.tick; period=27)
            for x in 0:2:dw-1, y in 0:1:dh-1
                if fbm(x*0.09 + m.tick*0.007, y*0.11 + m.tick*0.004; octaves=2) > (0.72 - dens)
                    set_point!(c, x, y)
                end
                if noise(x*0.17 + m.tick*0.013, y*0.19) > 0.86
                    set_point!(c, x+1, y)
                end
            end

            # Pulse ttl effect: extra rings
            if m.pulse_ttl > 0
                pr = pulse(m.tick; period=6, lo=0.4, hi=1.0)
                prr = round(Int, 4 + pr*3 + m.pulse_ttl*0.15)
                arc!(c, cx, cy, prr, 0.0, 360.0; steps=24)
                arc!(c, cx-1, cy+1, max(2, prr-5), 0.0, 360.0; steps=12)
            end

            render_canvas(c, canvas_area, f)
        end

        # Right: BarChart packets + Sparkline neural (stacked)
        if charts_area.width >= 8 && charts_area.height >= 5
            ch_rows = split_layout(Layout(Vertical, [Fixed(1), Fill(), Fixed(1), Fill()]), charts_area)
            if length(ch_rows) >= 4
                set_string!(buf, ch_rows[1].x + 1, ch_rows[1].y, "PACKETS", tstyle(:text, bold=true))
                # BarEntry for packets (last 6 samples as bars for viz)
                n = length(m.packet_history)
                take = min(6, n)
                bars = [BarEntry("$(i)", m.packet_history[n-take+i]; style = (i==take ? tstyle(:accent) : tstyle(:primary))) for i in 1:take]
                render(BarChart(bars; max_val=1.0, label_width=2, show_values=false), ch_rows[2], buf)

                set_string!(buf, ch_rows[3].x + 1, ch_rows[3].y, "NEURAL", tstyle(:text, bold=true))
                render(Sparkline(m.neural_history; style = tstyle(:secondary), max_val=1.0), ch_rows[4], buf)
            end
        end
    end

    # ── Bottom: logs (SelectableList) + input row ──
    bot_rows = split_layout(Layout(Vertical, [Fill(), Fixed(1)]), bottom_area)
    if length(bot_rows) >= 2
        log_area = bot_rows[1]
        inp_area = bot_rows[2]

        # SelectableList for logs (capped already)
        log_items = isempty(m.logs) ? [ListItem("— no logs —", tstyle(:text_dim))] : m.logs
        sel = clamp(m.log_selected, 1, length(log_items))
        render(SelectableList(log_items;
            selected = sel,
            block = Block(title="LOGS", border_style=tstyle(:border), title_style=tstyle(:text_dim)),
            highlight_style = tstyle(:accent, bold=true),
            tick = m.tick,
        ), log_area, buf)

        # TextInput at bottom
        if inp_area.width >= 4
            set_string!(buf, inp_area.x, inp_area.y, ">", tstyle(:accent))
            render(m.input, Rect(inp_area.x + 2, inp_area.y, max(1, inp_area.width-2), 1), buf)
        end
    end

    # ── StatusBar ──
    help = "[j/k/↑↓]nav [enter]cmd [pulse|hack|boost|clear|step|run|pause] [r/p/ ] [q]quit"
    stats = "sync=$(round(m.sync*100)) cpu=$(round(m.cpu*100)) fw=$(round(m.firewall*100)) p$(m.pulse_ttl)"
    render(StatusBar(
        left = [Span(" " * help, tstyle(:text_dim))],
        right = [Span(stats * " ", tstyle(:text_dim))],
    ), status_area, buf)
end

# ── Reset + Step stubs (for sim control, called from later phases) ─────

function reset!(m::Cyberdeck)
    # Reset sim and UI state
    m.tick = 0
    m.paused = false
    m.running = true
    # paused synced; running is primary control (pause cmd/hotkey set both)
    m.pulse_ttl = 0
    m.hacked = false
    m.boost = 1.0
    m.sync = 0.92
    m.cpu = 0.47
    m.firewall = 0.81
    empty!(m.logs)
    m.log_selected = 1
    m.packet_history = fill(0.4, 24)
    m.neural_history = zeros(Float64, 48)
    # leave input focused
    m.input = TextInput(; focused=true)
end

function step!(m::Cyberdeck)
    # Advance sim data: histories, slight gauge drift. Called when running in view, and on step cmds.
    # (tick advanced by view for animation consistency)

    t = m.tick / 28.0
    b = m.boost

    # Gauge drift + sin + noise, boosted
    m.sync = clamp(0.78 + 0.18 * sin(t * 0.9) + 0.05 * noise(t * 2.1) * b, 0.1, 0.99)
    m.cpu = clamp(0.35 + 0.25 * sin(t * 1.3) + 0.08 * fbm(t * 0.7) * b, 0.05, 0.98)
    m.firewall = clamp(0.70 + 0.22 * cos(t * 0.6) + (m.hacked ? -0.15 : 0.08) * noise(t), 0.2, 0.99)

    # Packet (use for Bar) and neural (Spark) histories
    pval = clamp(0.35 + 0.45 * sin(t * 1.6) + 0.12 * noise(t * 3.3 + 7) + 0.05 * (rand() - 0.5) * 2, 0.05, 0.98)
    push!(m.packet_history, pval)
    if length(m.packet_history) > 24
        popfirst!(m.packet_history)
    end

    nval = clamp(0.25 + 0.55 * sin(t * 0.8) + 0.2 * fbm(t * 1.1, t * 0.4) * b, 0.0, 0.95)
    push!(m.neural_history, nval)
    if length(m.neural_history) > 48
        popfirst!(m.neural_history)
    end

    # Decay pulse ttl
    if m.pulse_ttl > 0
        m.pulse_ttl -= 1
    end
end

# ── Runner (Phase 4) ───────────────────────────────────────────────────

"""
    cyberdeck()

Launch the Cyberdeck demo. Sets OUTRUN theme and runs the app.
"""
function cyberdeck()
    set_theme!(OUTRUN)
    app(Cyberdeck())
end

const run_cyberdeck = cyberdeck

# In module: export the runner (see TachikomaUITest.jl)
