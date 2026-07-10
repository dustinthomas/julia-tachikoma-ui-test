#!/usr/bin/env julia
# ═══════════════════════════════════════════════════════════════════════
# seed_playground.jl — rich multi-project / multi-person demo data
#
# Seeds people + projects + epics/sprints/labels/issues scheduled across
# ~3.5 months so board / backlog / calendar / Gantt are fun to explore.
#
# Usage (from qci-kanban/):
#   julia --project=. scripts/seed_playground.jl
#   julia --project=. scripts/seed_playground.jl --fresh   # wipe DBs first
#
# Then:
#   julia --project=. -e 'using QciKanban; QciKanban.kanban2()'
#
# Login (any account; password is the same for all):
#   email:    alex@qci.demo
#   password: demo
#
# Other people: sam@, jordan@, morgan@, casey@, riley@, taylor@  @qci.demo
# ═══════════════════════════════════════════════════════════════════════

using Dates
using QciKanban
using QciKanban.Config
using QciKanban.Stores

const DEMO_PASSWORD = "demo"
const PLAYGROUND_MARKER = "PLAYGROUND_SEED_V1"

# ── CLI ─────────────────────────────────────────────────────────────────
const FRESH = "--fresh" in ARGS || "-f" in ARGS
const HELP  = "--help" in ARGS || "-h" in ARGS

if HELP
    println("""
    seed_playground.jl — multi-project playground data (3+ months schedule)

      julia --project=. scripts/seed_playground.jl
      julia --project=. scripts/seed_playground.jl --fresh

    --fresh / -f   delete users.db + board.db, then seed from scratch
    --help  / -h   this message
    """)
    exit(0)
end

# ── Paths ───────────────────────────────────────────────────────────────
cfg = load_config()
users_path = cfg.users_db_path
board_path = cfg.board_db_path

if FRESH
    println("── fresh mode: removing existing DBs ──")
    for p in (users_path, board_path)
        if isfile(p)
            rm(p)
            println("  removed $p")
        end
        # SQLite WAL companions
        for suf in ("-wal", "-shm")
            wp = p * suf
            isfile(wp) && rm(wp)
        end
    end
    # Drop session so login gate is clean
    tok = cfg.session_token_path
    isfile(tok) && rm(tok)
end

mkpath(dirname(users_path))
us, bs = open_sqlite_stores(cfg)

# ── Helpers ─────────────────────────────────────────────────────────────
function ensure_user!(us; email, name, role, password = DEMO_PASSWORD)
    for u in list_users(us)
        if u.email == email
            return u
        end
    end
    create_user!(us; email = email, name = name, password = password, role = role)
end

function ensure_project!(bs; key, name, description, color)
    for p in list_projects(bs; include_archived = true)
        p.key == key && return p
    end
    create_project!(bs; key = key, name = name, description = description, color = color)
end

function ensure_label!(bs, pid, name, color)
    for l in list_labels(bs; project_id = pid)
        l.name == name && return l
    end
    create_label!(bs; name = name, color = color, project_id = pid)
end

"""True if this project already has playground-seeded issues (idempotent guard)."""
function already_seeded(bs, pid)::Bool
    for iss in list_issues(bs; project_id = pid)
        occursin(PLAYGROUND_MARKER, iss.description) && return true
    end
    return false
end

function add_issue!(bs; title, description = "", status = "Backlog", priority = "Medium",
                    story_points = nothing, epic_id = nothing, sprint_id = nothing,
                    assignee_id = nothing, reporter_id = nothing,
                    start_date = nothing, due_date = nothing,
                    labels = String[], project_id, asset_tag = nothing,
                    location = nothing, work_type = nothing)
    desc = isempty(description) ? PLAYGROUND_MARKER :
           description * "\n\n[" * PLAYGROUND_MARKER * "]"
    create_issue!(bs; title = title, description = desc, status = status,
                  priority = priority, story_points = story_points,
                  epic_id = epic_id, sprint_id = sprint_id,
                  assignee_id = assignee_id, reporter_id = reporter_id,
                  start_date = start_date, due_date = due_date,
                  labels = labels, project_id = project_id,
                  asset_tag = asset_tag, location = location, work_type = work_type)
end

# date helpers relative to "today"
t0 = Dates.today()
d(n) = t0 + Day(n)
span(start_off, end_off) = (d(start_off), d(end_off))

# ── People ──────────────────────────────────────────────────────────────
println("── people ──")
people = [
    ensure_user!(us; email = "alex@qci.demo",   name = "Alex Rivera",  role = "admin"),
    ensure_user!(us; email = "sam@qci.demo",    name = "Sam Chen",     role = "supervisor"),
    ensure_user!(us; email = "jordan@qci.demo", name = "Jordan Lee",   role = "technician"),
    ensure_user!(us; email = "morgan@qci.demo", name = "Morgan Patel", role = "technician"),
    ensure_user!(us; email = "casey@qci.demo",  name = "Casey Brooks", role = "supervisor"),
    ensure_user!(us; email = "riley@qci.demo",  name = "Riley Nguyen", role = "technician"),
    ensure_user!(us; email = "taylor@qci.demo", name = "Taylor Kim",   role = "viewer"),
]
by_email = Dict(u.email => u for u in people)
for u in people
    println("  $(u.role)  $(u.email)  —  $(u.name)")
end
println("  password for all: $DEMO_PASSWORD")

alex   = by_email["alex@qci.demo"]
sam    = by_email["sam@qci.demo"]
jordan = by_email["jordan@qci.demo"]
morgan = by_email["morgan@qci.demo"]
casey  = by_email["casey@qci.demo"]
riley  = by_email["riley@qci.demo"]
taylor = by_email["taylor@qci.demo"]  # viewer — mostly unassigned observer

# ── Projects ────────────────────────────────────────────────────────────
println("── projects ──")
# Keep / refresh Default (QCI) as software product work
qci = only(filter(p -> p.key == "QCI", list_projects(bs; include_archived = true)))
mnt = ensure_project!(bs; key = "MNT", name = "Plant Maintenance",
                      description = "Preventive + corrective work orders for shop floor assets",
                      color = "orange")
rnd = ensure_project!(bs; key = "RND", name = "Product R&D",
                      description = "Next-gen controller firmware and sensor stack",
                      color = "violet")
ops = ensure_project!(bs; key = "OPS", name = "Line Operations",
                      description = "Day-to-day production line support and changeovers",
                      color = "teal")
for p in (qci, mnt, rnd, ops)
    println("  $(p.key)  $(p.name)")
end

# ═══════════════════════════════════════════════════════════════════════
# QCI — software platform (calendar/gantt friendly schedule)
# ═══════════════════════════════════════════════════════════════════════
function seed_qci!(bs)
    pid = qci.id
    already_seeded(bs, pid) && (println("  QCI already playground-seeded — skip"); return)

    existing = list_issues(bs; project_id = pid)
    if !isempty(existing)
        # Replace only the tiny auto seed_demo board; leave real user data alone.
        demo_titles = Set([
            "Set up project board", "Design login screen", "Implement card model",
            "Add QCI colors + logo", "Board column rendering", "Calendar view + due marks",
            "Initial DB schema",
        ])
        if all(i -> i.title in demo_titles, existing)
            for iss in existing
                delete_issue!(bs, iss.id)
            end
            for e in list_epics(bs; project_id = pid)
                delete_epic!(bs, e.id)
            end
            println("  QCI: replaced minimal seed_demo content")
        else
            println("  QCI: has non-demo issues — leave as-is (use --fresh to rebuild)")
            return
        end
    end

    e_onboard = create_epic!(bs; name = "Onboarding", color = "violet", project_id = pid)
    e_board   = create_epic!(bs; name = "Board Core", color = "teal", project_id = pid)
    e_timeline = create_epic!(bs; name = "Timeline Views", color = "cyan", project_id = pid)
    e_auth    = create_epic!(bs; name = "Auth & Sessions", color = "navy", project_id = pid)

    lbl_bug = ensure_label!(bs, pid, "bug", "red")
    lbl_ui  = ensure_label!(bs, pid, "ui", "cyan")
    lbl_perf = ensure_label!(bs, pid, "perf", "yellow")
    lbl_docs = ensure_label!(bs, pid, "docs", "blue")

    # Sprints: past closed, active current, two futures (~3 months)
    s_past = create_sprint!(bs; name = "Sprint 0 — Foundation",
                            goal = "Schema + login gate",
                            start_date = d(-28), end_date = d(-15), project_id = pid)
    start_sprint!(bs, s_past.id)
    close_sprint!(bs, s_past.id)

    s_now = create_sprint!(bs; name = "Sprint 1 — Board Polish",
                           goal = "Swimlanes, WIP, rich cards",
                           start_date = d(-7), end_date = d(7), project_id = pid)
    start_sprint!(bs, s_now.id)

    s_next = create_sprint!(bs; name = "Sprint 2 — Calendar/Gantt",
                            goal = "Timeline UX + edit flows",
                            start_date = d(8), end_date = d(21), project_id = pid)
    s_m2 = create_sprint!(bs; name = "Sprint 3 — Multi-project",
                          goal = "Project switcher + export",
                          start_date = d(22), end_date = d(35), project_id = pid)
    s_m3 = create_sprint!(bs; name = "Sprint 4 — Hardening",
                          goal = "Roles, idle logout, plant config",
                          start_date = d(50), end_date = d(63), project_id = pid)
    s_m4 = create_sprint!(bs; name = "Sprint 5 — Ship",
                          goal = "Release candidate + docs",
                          start_date = d(78), end_date = d(91), project_id = pid)

    # Done (past)
    add_issue!(bs; title = "Initial DB schema", status = "Done", priority = "High",
               story_points = 5, epic_id = e_board.id, sprint_id = s_past.id,
               assignee_id = alex.id, reporter_id = alex.id,
               start_date = d(-26), due_date = d(-20), project_id = pid,
               labels = [lbl_docs.id])
    add_issue!(bs; title = "Scaffold QciKanban package", status = "Done", priority = "High",
               story_points = 3, epic_id = e_onboard.id, sprint_id = s_past.id,
               assignee_id = sam.id, reporter_id = alex.id,
               start_date = d(-25), due_date = d(-18), project_id = pid)
    add_issue!(bs; title = "JWT session restore", status = "Done", priority = "High",
               story_points = 5, epic_id = e_auth.id, sprint_id = s_past.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(-22), due_date = d(-16), project_id = pid)

    # Active sprint work
    add_issue!(bs; title = "Board column rendering", status = "In Progress", priority = "High",
               story_points = 8, epic_id = e_board.id, sprint_id = s_now.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(-5), due_date = d(3), project_id = pid,
               labels = [lbl_ui.id])
    add_issue!(bs; title = "Implement card model", status = "To Do", priority = "High",
               story_points = 5, epic_id = e_board.id, sprint_id = s_now.id,
               assignee_id = morgan.id, reporter_id = sam.id,
               start_date = d(-2), due_date = d(5), project_id = pid)
    add_issue!(bs; title = "WIP limit gauges", status = "Review", priority = "Medium",
               story_points = 3, epic_id = e_board.id, sprint_id = s_now.id,
               assignee_id = riley.id, reporter_id = casey.id,
               start_date = d(-4), due_date = d(1), project_id = pid,
               labels = [lbl_ui.id, lbl_perf.id])
    add_issue!(bs; title = "Keyboard nav between columns", status = "In Progress", priority = "Medium",
               story_points = 3, epic_id = e_board.id, sprint_id = s_now.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(-1), due_date = d(6), project_id = pid)

    # Near-term backlog / upcoming sprints
    add_issue!(bs; title = "Calendar view + due marks", status = "To Do", priority = "High",
               story_points = 8, epic_id = e_timeline.id, sprint_id = s_next.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(9), due_date = d(18), project_id = pid,
               labels = [lbl_ui.id])
    add_issue!(bs; title = "Gantt bar density + weekends", status = "Backlog", priority = "High",
               story_points = 5, epic_id = e_timeline.id, sprint_id = s_next.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(10), due_date = d(20), project_id = pid)
    add_issue!(bs; title = "Edit modal date fields", status = "Backlog", priority = "Medium",
               story_points = 3, epic_id = e_timeline.id, sprint_id = s_next.id,
               assignee_id = riley.id, reporter_id = sam.id,
               start_date = d(12), due_date = d(19), project_id = pid)

    add_issue!(bs; title = "Project switcher (P)", status = "Backlog", priority = "High",
               story_points = 5, epic_id = e_board.id, sprint_id = s_m2.id,
               assignee_id = sam.id, reporter_id = alex.id,
               start_date = d(23), due_date = d(32), project_id = pid)
    add_issue!(bs; title = "CSV export for board", status = "Backlog", priority = "Medium",
               story_points = 3, epic_id = e_board.id, sprint_id = s_m2.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(25), due_date = d(34), project_id = pid)
    add_issue!(bs; title = "Ops labels template on create", status = "Backlog", priority = "Low",
               story_points = 2, epic_id = e_onboard.id, sprint_id = s_m2.id,
               assignee_id = riley.id, reporter_id = casey.id,
               start_date = d(28), due_date = d(33), project_id = pid)

    # Mid-horizon
    add_issue!(bs; title = "Role matrix enforcement toggle", status = "Backlog", priority = "High",
               story_points = 8, epic_id = e_auth.id, sprint_id = s_m3.id,
               assignee_id = alex.id, reporter_id = alex.id,
               start_date = d(52), due_date = d(61), project_id = pid)
    add_issue!(bs; title = "Idle logout timer", status = "Backlog", priority = "Medium",
               story_points = 3, epic_id = e_auth.id, sprint_id = s_m3.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(54), due_date = d(60), project_id = pid)
    add_issue!(bs; title = "Plant maintenance.toml docs", status = "Backlog", priority = "Low",
               story_points = 2, epic_id = e_onboard.id, sprint_id = s_m3.id,
               assignee_id = sam.id, reporter_id = casey.id,
               start_date = d(55), due_date = d(62), project_id = pid,
               labels = [lbl_docs.id])

    # Far horizon (~3 months)
    add_issue!(bs; title = "Release candidate checklist", status = "Backlog", priority = "High",
               story_points = 5, epic_id = e_onboard.id, sprint_id = s_m4.id,
               assignee_id = alex.id, reporter_id = alex.id,
               start_date = d(80), due_date = d(90), project_id = pid)
    add_issue!(bs; title = "Performance pass on large boards", status = "Backlog", priority = "Medium",
               story_points = 8, epic_id = e_board.id, sprint_id = s_m4.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(82), due_date = d(91), project_id = pid,
               labels = [lbl_perf.id])
    add_issue!(bs; title = "Design login screen polish", status = "Backlog", priority = "Low",
               story_points = 3, epic_id = e_onboard.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(70), due_date = d(85), project_id = pid,
               labels = [lbl_ui.id])
    add_issue!(bs; title = "Set up project board defaults", status = "Backlog", priority = "Medium",
               story_points = 2, epic_id = e_board.id,
               assignee_id = riley.id, reporter_id = sam.id,
               start_date = d(40), due_date = d(48), project_id = pid)
    # Overdue open bug for filter play
    add_issue!(bs; title = "Fix overdue badge contrast", status = "To Do", priority = "High",
               story_points = 1, epic_id = e_board.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(-10), due_date = d(-3), project_id = pid,
               labels = [lbl_bug.id, lbl_ui.id])

    println("  QCI seeded ($(length(list_issues(bs; project_id = pid))) issues)")
end

# ═══════════════════════════════════════════════════════════════════════
# MNT — plant maintenance (work orders, assets, PM/CM)
# ═══════════════════════════════════════════════════════════════════════
function seed_mnt!(bs)
    pid = mnt.id
    already_seeded(bs, pid) && (println("  MNT already playground-seeded — skip"); return)

    seed_ops_template!(bs, pid)
    e_pm   = create_epic!(bs; name = "Preventive PM", color = "green", project_id = pid)
    e_cm   = create_epic!(bs; name = "Corrective CM", color = "red", project_id = pid)
    e_safe = create_epic!(bs; name = "Safety", color = "yellow", project_id = pid)
    e_imp  = create_epic!(bs; name = "Improvements", color = "cyan", project_id = pid)

    labels = Dict(l.name => l for l in list_labels(bs; project_id = pid))
    # extras
    lbl_line = ensure_label!(bs, pid, "Line-A", "teal")
    lbl_util = ensure_label!(bs, pid, "Utilities", "blue")

    # Planning windows: monthly-ish across ~3 months
    w0 = create_sprint!(bs; name = "WO Window Jun", goal = "Catch-up backlog",
                        start_date = d(-30), end_date = d(-1), project_id = pid)
    start_sprint!(bs, w0.id); close_sprint!(bs, w0.id)
    w1 = create_sprint!(bs; name = "WO Window Current", goal = "Live maintenance",
                        start_date = d(0), end_date = d(30), project_id = pid)
    start_sprint!(bs, w1.id)
    w2 = create_sprint!(bs; name = "WO Window +1mo", goal = "Q-scheduled PMs",
                        start_date = d(31), end_date = d(60), project_id = pid)
    w3 = create_sprint!(bs; name = "WO Window +2mo", goal = "Major outage prep",
                        start_date = d(61), end_date = d(90), project_id = pid)

    # Closed / done history
    add_issue!(bs; title = "PM-1001: Compressor oil change", status = "Done", priority = "Medium",
               work_type = "PM", asset_tag = "CMP-12", location = "Bay 2",
               story_points = 2, epic_id = e_pm.id, sprint_id = w0.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(-20), due_date = d(-18), project_id = pid,
               labels = [labels["PM"].id, lbl_line.id])
    add_issue!(bs; title = "CM-884: Conveyor belt splice", status = "Done", priority = "High",
               work_type = "CM", asset_tag = "CNV-03", location = "Line A",
               story_points = 5, epic_id = e_cm.id, sprint_id = w0.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(-14), due_date = d(-12), project_id = pid,
               labels = [labels["CM"].id, lbl_line.id])

    # Current window
    add_issue!(bs; title = "PM-1012: HVAC filter bank", status = "In Progress", priority = "Medium",
               work_type = "PM", asset_tag = "HVAC-1", location = "Roof / AHU",
               story_points = 3, epic_id = e_pm.id, sprint_id = w1.id,
               assignee_id = riley.id, reporter_id = sam.id,
               start_date = d(-2), due_date = d(5), project_id = pid,
               labels = [labels["PM"].id, lbl_util.id])
    add_issue!(bs; title = "CM-901: Leak at hydraulic pack", status = "To Do", priority = "High",
               work_type = "CM", asset_tag = "HYD-07", location = "Press cell",
               story_points = 5, epic_id = e_cm.id, sprint_id = w1.id,
               assignee_id = jordan.id, reporter_id = casey.id,
               start_date = d(0), due_date = d(3), project_id = pid,
               labels = [labels["CM"].id, labels["Critical"].id])
    add_issue!(bs; title = "Safety: LOTO audit Bay 3", status = "Review", priority = "High",
               work_type = "Safety", asset_tag = "BAY-3", location = "Bay 3",
               story_points = 2, epic_id = e_safe.id, sprint_id = w1.id,
               assignee_id = sam.id, reporter_id = alex.id,
               start_date = d(-5), due_date = d(2), project_id = pid,
               labels = [labels["Safety"].id])
    add_issue!(bs; title = "PM-1018: Robot grease cycle R2", status = "To Do", priority = "Medium",
               work_type = "PM", asset_tag = "RBT-02", location = "Cell 4",
               story_points = 2, epic_id = e_pm.id, sprint_id = w1.id,
               assignee_id = morgan.id, reporter_id = sam.id,
               start_date = d(4), due_date = d(12), project_id = pid,
               labels = [labels["PM"].id, lbl_line.id])
    add_issue!(bs; title = "CM-910: Door interlock fault", status = "In Progress", priority = "High",
               work_type = "CM", asset_tag = "SAFE-19", location = "Cell 1",
               story_points = 3, epic_id = e_cm.id, sprint_id = w1.id,
               assignee_id = riley.id, reporter_id = casey.id,
               start_date = d(-1), due_date = d(4), project_id = pid,
               labels = [labels["CM"].id, labels["Safety"].id])

    # +1 month
    add_issue!(bs; title = "PM-1100: Annual crane inspection", status = "Backlog", priority = "High",
               work_type = "PM", asset_tag = "CRN-01", location = "Warehouse",
               story_points = 8, epic_id = e_pm.id, sprint_id = w2.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(35), due_date = d(45), project_id = pid,
               labels = [labels["PM"].id, labels["Critical"].id])
    add_issue!(bs; title = "Improvement: spare-parts kanban rack", status = "Backlog", priority = "Low",
               work_type = "Improvement", location = "Stores",
               story_points = 5, epic_id = e_imp.id, sprint_id = w2.id,
               assignee_id = sam.id, reporter_id = casey.id,
               start_date = d(40), due_date = d(55), project_id = pid,
               labels = [labels["PM"].id])
    add_issue!(bs; title = "PM-1112: Chiller seasonal service", status = "Backlog", priority = "Medium",
               work_type = "PM", asset_tag = "CHL-02", location = "Utilities",
               story_points = 5, epic_id = e_pm.id, sprint_id = w2.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(42), due_date = d(50), project_id = pid,
               labels = [labels["PM"].id, lbl_util.id])
    add_issue!(bs; title = "Safety: fire extinguisher tour", status = "Backlog", priority = "Medium",
               work_type = "Safety", location = "Plant-wide",
               story_points = 2, epic_id = e_safe.id, sprint_id = w2.id,
               assignee_id = morgan.id, reporter_id = alex.id,
               start_date = d(48), due_date = d(58), project_id = pid,
               labels = [labels["Safety"].id])

    # +2–3 months
    add_issue!(bs; title = "Major outage: Line A gearbox swap", status = "Backlog", priority = "High",
               work_type = "CM", asset_tag = "GBX-A1", location = "Line A",
               story_points = 13, epic_id = e_cm.id, sprint_id = w3.id,
               assignee_id = jordan.id, reporter_id = casey.id,
               start_date = d(70), due_date = d(78), project_id = pid,
               labels = [labels["CM"].id, labels["Critical"].id, lbl_line.id])
    add_issue!(bs; title = "PM-1200: Substation IR scan", status = "Backlog", priority = "High",
               work_type = "PM", asset_tag = "SUB-1", location = "Electrical",
               story_points = 5, epic_id = e_pm.id, sprint_id = w3.id,
               assignee_id = riley.id, reporter_id = sam.id,
               start_date = d(75), due_date = d(85), project_id = pid,
               labels = [labels["PM"].id, lbl_util.id])
    add_issue!(bs; title = "Improvement: CMMS barcode pilot", status = "Backlog", priority = "Low",
               work_type = "Improvement", location = "Stores",
               story_points = 8, epic_id = e_imp.id, sprint_id = w3.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(80), due_date = d(95), project_id = pid)
    add_issue!(bs; title = "PM-1210: Dock leveler PM set", status = "Backlog", priority = "Medium",
               work_type = "PM", asset_tag = "DOCK-1..4", location = "Shipping",
               story_points = 3, epic_id = e_pm.id,
               assignee_id = morgan.id, reporter_id = sam.id,
               start_date = d(88), due_date = d(98), project_id = pid,
               labels = [labels["PM"].id])
    # Unassigned backlog item
    add_issue!(bs; title = "CM-950: Mystery vibration on pump P-4", status = "Backlog", priority = "Medium",
               work_type = "CM", asset_tag = "PMP-04", location = "Utilities",
               story_points = 3, epic_id = e_cm.id,
               reporter_id = taylor.id,
               start_date = d(15), due_date = d(25), project_id = pid,
               labels = [labels["CM"].id, lbl_util.id])

    println("  MNT seeded ($(length(list_issues(bs; project_id = pid))) issues)")
end

# ═══════════════════════════════════════════════════════════════════════
# RND — product R&D (firmware / sensors)
# ═══════════════════════════════════════════════════════════════════════
function seed_rnd!(bs)
    pid = rnd.id
    already_seeded(bs, pid) && (println("  RND already playground-seeded — skip"); return)

    e_fw  = create_epic!(bs; name = "Firmware v3", color = "violet", project_id = pid)
    e_sns = create_epic!(bs; name = "Sensor Stack", color = "teal", project_id = pid)
    e_qa  = create_epic!(bs; name = "Validation", color = "yellow", project_id = pid)

    lbl_hw  = ensure_label!(bs, pid, "hardware", "orange")
    lbl_fw  = ensure_label!(bs, pid, "firmware", "violet")
    lbl_lab = ensure_label!(bs, pid, "lab", "cyan")

    sp_a = create_sprint!(bs; name = "R&D Alpha", goal = "Bring-up boards",
                          start_date = d(-10), end_date = d(4), project_id = pid)
    start_sprint!(bs, sp_a.id)
    sp_b = create_sprint!(bs; name = "R&D Beta", goal = "Sensor fusion",
                          start_date = d(5), end_date = d(32), project_id = pid)
    sp_c = create_sprint!(bs; name = "R&D Gamma", goal = "Field trials",
                          start_date = d(33), end_date = d(60), project_id = pid)
    sp_d = create_sprint!(bs; name = "R&D Delta", goal = "Cert prep",
                          start_date = d(61), end_date = d(95), project_id = pid)

    add_issue!(bs; title = "Bootloader bring-up on rev B", status = "In Progress", priority = "High",
               story_points = 8, epic_id = e_fw.id, sprint_id = sp_a.id,
               assignee_id = jordan.id, reporter_id = alex.id,
               start_date = d(-8), due_date = d(2), project_id = pid,
               labels = [lbl_fw.id, lbl_hw.id])
    add_issue!(bs; title = "I2C mux driver", status = "Review", priority = "Medium",
               story_points = 5, epic_id = e_sns.id, sprint_id = sp_a.id,
               assignee_id = riley.id, reporter_id = sam.id,
               start_date = d(-6), due_date = d(1), project_id = pid,
               labels = [lbl_fw.id])
    add_issue!(bs; title = "Lab fixture for temp chamber", status = "To Do", priority = "Medium",
               story_points = 3, epic_id = e_qa.id, sprint_id = sp_a.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(-3), due_date = d(4), project_id = pid,
               labels = [lbl_lab.id])

    add_issue!(bs; title = "IMU fusion algorithm v2", status = "Backlog", priority = "High",
               story_points = 13, epic_id = e_sns.id, sprint_id = sp_b.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(8), due_date = d(28), project_id = pid,
               labels = [lbl_fw.id])
    add_issue!(bs; title = "Power budget measurement", status = "Backlog", priority = "Medium",
               story_points = 5, epic_id = e_fw.id, sprint_id = sp_b.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(10), due_date = d(22), project_id = pid,
               labels = [lbl_hw.id, lbl_lab.id])
    add_issue!(bs; title = "OTA update protocol draft", status = "Backlog", priority = "High",
               story_points = 8, epic_id = e_fw.id, sprint_id = sp_b.id,
               assignee_id = riley.id, reporter_id = alex.id,
               start_date = d(14), due_date = d(30), project_id = pid,
               labels = [lbl_fw.id])

    add_issue!(bs; title = "Pilot install at customer site A", status = "Backlog", priority = "High",
               story_points = 8, epic_id = e_qa.id, sprint_id = sp_c.id,
               assignee_id = sam.id, reporter_id = alex.id,
               start_date = d(38), due_date = d(55), project_id = pid)
    add_issue!(bs; title = "EMI pre-scan", status = "Backlog", priority = "Medium",
               story_points = 5, epic_id = e_qa.id, sprint_id = sp_c.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(40), due_date = d(50), project_id = pid,
               labels = [lbl_lab.id])
    add_issue!(bs; title = "Firmware freeze candidate", status = "Backlog", priority = "High",
               story_points = 3, epic_id = e_fw.id, sprint_id = sp_c.id,
               assignee_id = jordan.id, reporter_id = alex.id,
               start_date = d(52), due_date = d(58), project_id = pid,
               labels = [lbl_fw.id])

    add_issue!(bs; title = "Certification paperwork pack", status = "Backlog", priority = "Medium",
               story_points = 5, epic_id = e_qa.id, sprint_id = sp_d.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(65), due_date = d(85), project_id = pid)
    add_issue!(bs; title = "Long-run soak test 30 days", status = "Backlog", priority = "High",
               story_points = 8, epic_id = e_qa.id, sprint_id = sp_d.id,
               assignee_id = riley.id, reporter_id = sam.id,
               start_date = d(62), due_date = d(92), project_id = pid,
               labels = [lbl_lab.id])
    add_issue!(bs; title = "Sensor calibration procedure", status = "Backlog", priority = "Low",
               story_points = 3, epic_id = e_sns.id,
               assignee_id = morgan.id, reporter_id = casey.id,
               start_date = d(70), due_date = d(88), project_id = pid,
               labels = [lbl_lab.id])

    println("  RND seeded ($(length(list_issues(bs; project_id = pid))) issues)")
end

# ═══════════════════════════════════════════════════════════════════════
# OPS — line operations
# ═══════════════════════════════════════════════════════════════════════
function seed_ops!(bs)
    pid = ops.id
    already_seeded(bs, pid) && (println("  OPS already playground-seeded — skip"); return)

    e_chg = create_epic!(bs; name = "Changeovers", color = "orange", project_id = pid)
    e_cap = create_epic!(bs; name = "Capacity", color = "teal", project_id = pid)
    e_tr  = create_epic!(bs; name = "Training", color = "violet", project_id = pid)

    lbl_a = ensure_label!(bs, pid, "shift-A", "cyan")
    lbl_b = ensure_label!(bs, pid, "shift-B", "blue")
    lbl_q = ensure_label!(bs, pid, "quality", "red")

    s1 = create_sprint!(bs; name = "Ops Sprint Now", goal = "Stabilize throughput",
                        start_date = d(-5), end_date = d(9), project_id = pid)
    start_sprint!(bs, s1.id)
    s2 = create_sprint!(bs; name = "Ops Sprint +2w", goal = "New SKU ramp",
                        start_date = d(10), end_date = d(24), project_id = pid)
    s3 = create_sprint!(bs; name = "Ops Sprint +6w", goal = "Second line dual-run",
                        start_date = d(40), end_date = d(54), project_id = pid)
    s4 = create_sprint!(bs; name = "Ops Sprint +10w", goal = "Year-end volume",
                        start_date = d(70), end_date = d(90), project_id = pid)

    add_issue!(bs; title = "SKU-12 changeover playbook", status = "In Progress", priority = "High",
               story_points = 5, epic_id = e_chg.id, sprint_id = s1.id,
               assignee_id = casey.id, reporter_id = sam.id,
               start_date = d(-3), due_date = d(4), project_id = pid,
               labels = [lbl_a.id])
    add_issue!(bs; title = "Cycle-time study cell 2", status = "To Do", priority = "Medium",
               story_points = 3, epic_id = e_cap.id, sprint_id = s1.id,
               assignee_id = jordan.id, reporter_id = casey.id,
               start_date = d(0), due_date = d(7), project_id = pid,
               labels = [lbl_b.id])
    add_issue!(bs; title = "First-article inspection checklist", status = "Review", priority = "High",
               story_points = 2, epic_id = e_chg.id, sprint_id = s1.id,
               assignee_id = morgan.id, reporter_id = sam.id,
               start_date = d(-4), due_date = d(1), project_id = pid,
               labels = [lbl_q.id])

    add_issue!(bs; title = "New SKU-18 tooling set", status = "Backlog", priority = "High",
               story_points = 8, epic_id = e_chg.id, sprint_id = s2.id,
               assignee_id = riley.id, reporter_id = alex.id,
               start_date = d(12), due_date = d(22), project_id = pid)
    add_issue!(bs; title = "Operator cross-train matrix", status = "Backlog", priority = "Medium",
               story_points = 5, epic_id = e_tr.id, sprint_id = s2.id,
               assignee_id = sam.id, reporter_id = casey.id,
               start_date = d(14), due_date = d(24), project_id = pid,
               labels = [lbl_a.id, lbl_b.id])
    add_issue!(bs; title = "Scrap Pareto for last 30 days", status = "Backlog", priority = "Low",
               story_points = 3, epic_id = e_cap.id, sprint_id = s2.id,
               assignee_id = morgan.id, reporter_id = taylor.id,
               start_date = d(11), due_date = d(18), project_id = pid,
               labels = [lbl_q.id])

    add_issue!(bs; title = "Line B dual-run staffing plan", status = "Backlog", priority = "High",
               story_points = 5, epic_id = e_cap.id, sprint_id = s3.id,
               assignee_id = casey.id, reporter_id = alex.id,
               start_date = d(42), due_date = d(52), project_id = pid)
    add_issue!(bs; title = "Night-shift onboarding week", status = "Backlog", priority = "Medium",
               story_points = 5, epic_id = e_tr.id, sprint_id = s3.id,
               assignee_id = sam.id, reporter_id = casey.id,
               start_date = d(45), due_date = d(54), project_id = pid,
               labels = [lbl_b.id])

    add_issue!(bs; title = "Peak-season overtime model", status = "Backlog", priority = "Medium",
               story_points = 3, epic_id = e_cap.id, sprint_id = s4.id,
               assignee_id = alex.id, reporter_id = alex.id,
               start_date = d(72), due_date = d(85), project_id = pid)
    add_issue!(bs; title = "Holiday shutdown / startup checklist", status = "Backlog", priority = "High",
               story_points = 5, epic_id = e_chg.id, sprint_id = s4.id,
               assignee_id = jordan.id, reporter_id = sam.id,
               start_date = d(80), due_date = d(92), project_id = pid)
    add_issue!(bs; title = "Quality hold: lot trace drill", status = "Backlog", priority = "High",
               story_points = 3, epic_id = e_cap.id,
               assignee_id = riley.id, reporter_id = casey.id,
               start_date = d(55), due_date = d(68), project_id = pid,
               labels = [lbl_q.id])

    println("  OPS seeded ($(length(list_issues(bs; project_id = pid))) issues)")
end

# ── Run all ─────────────────────────────────────────────────────────────
println("── board data ──")
seed_qci!(bs)
seed_mnt!(bs)
seed_rnd!(bs)
seed_ops!(bs)

n_users = length(list_users(us))
n_proj  = length(list_projects(bs))
n_iss   = length(list_issues(bs))
n_dated = count(i -> i.start_date !== nothing || i.due_date !== nothing, list_issues(bs))
dates = Date[]
for i in list_issues(bs)
    i.start_date !== nothing && push!(dates, i.start_date)
    i.due_date !== nothing && push!(dates, i.due_date)
end
span_days = isempty(dates) ? 0 : Dates.value(maximum(dates) - minimum(dates))

close!(us)
close!(bs)

println()
println("════════════════════════════════════════════════════════")
println("  Playground ready")
println("════════════════════════════════════════════════════════")
println("  users:     $n_users")
println("  projects:  $n_proj  (QCI, MNT, RND, OPS)")
println("  issues:    $n_iss  ($n_dated dated)")
println("  schedule:  ~$span_days days across calendar/Gantt")
println("  users db:  $users_path")
println("  board db:  $board_path")
println()
println("  Login:  alex@qci.demo  /  $DEMO_PASSWORD")
println("  Also:   sam@ jordan@ morgan@ casey@ riley@ taylor@  @qci.demo")
println()
println("  Run:  julia --project=. -e 'using QciKanban; QciKanban.kanban2()'")
println("  Tips:  P project switch · s swimlane by assignee · C calendar · G gantt")
println("════════════════════════════════════════════════════════")
