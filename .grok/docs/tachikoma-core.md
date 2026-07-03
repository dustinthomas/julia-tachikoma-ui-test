# Tachikoma.jl — Core Concepts for Grok Build

This document is the primary reference for how to correctly build and test Tachikoma UIs in this project. It distills the official architecture combined with this repository's conventions and hard-learned patterns.

**Before doing any Tachikoma UI work, read this file + `.grok/docs/tachikoma-ui-testing.md`.**

When working on the QCI Kanban board specifically, also read:
- `.grok/docs/kanban-beauty-plan.md` (full Jira-inspired feature roadmap and PR plan)

---

## 1. Fundamental Architecture

Tachikoma uses a strict **Elm-style architecture**:

- **Model**: A single mutable struct that holds all state.
- **update!**: Pure(ish) mutation of the model in response to events.
- **view**: Imperative rendering into a `Frame` / `Buffer`.
- **should_quit**: Simple predicate.

```julia
using Tachikoma
@tachikoma_app

@kwdef mutable struct MyModel <: Model
    quit::Bool = false
    # ... your state
end

should_quit(m::MyModel) = m.quit

function update!(m::MyModel, evt::KeyEvent)
    # handle events, mutate m
end

function view(m::MyModel, f::Frame)
    buf = f.buffer
    # render using set_string!, Block, widgets, etc.
end

app(MyModel())
```

**Key invariants**:
- The model is the single source of truth.
- Rendering is side-effecting but deterministic given the model + frame size.
- Never do heavy work inside `view`.

---

## 2. The Model Contract

```julia
@kwdef mutable struct Foo <: Model
    quit::Bool = false
    # other fields...
end
```

Required:
- Subtype `Model`
- `quit::Bool` field (or implement `should_quit`)
- Use `@kwdef` for convenient construction (strongly preferred in this codebase)

`should_quit(m)` can be defined if you need custom logic.

---

## 3. Events & Input

Most common event type:

```julia
function update!(m::MyModel, evt::KeyEvent)
    if evt.key == :char && evt.char == 'q'
        m.quit = true
    elseif evt.key == :escape
        # ...
    end

    # Text inputs handle themselves
    if handle_key!(m.some_input, evt)
        return
    end
end
```

`KeyEvent` carries `.key` (symbol) and `.char` (when applicable).

Mouse support exists but is rarely used in this project.

---

## 4. Rendering Model (view + Frame + Buffer)

```julia
function view(m::MyModel, f::Frame)
    buf = f.buffer          # Buffer you draw into
    area = f.area           # Rect for this view/widget
    # ...
end
```

Core drawing primitives:
- `set_string!(buf, x, y, text, style)`
- `set_char!(buf, x, y, char, style)`
- `Block(title=..., border_style=..., title_style=...)` + `render(block, rect, buf)`

**Always** respect the `area` you were given. Never draw outside it.

### Layout

Use `split_layout`:

```julia
rows = split_layout(Layout(Vertical, [Fixed(7), Fill(), Fixed(1)]), main_area)
logo_area   = rows[1]
content_area = rows[2]
status_area  = rows[3]
```

Common constraints: `Fixed(n)`, `Fill()`, `Percent(p)`.

This project frequently uses helper functions like `gate_frame_areas(frame)` to compute stable regions.

---

## 5. Styling

```julia
const QCI_CYAN   = ColorRGB(0, 188, 212)
const QCI_NAVY   = ColorRGB(30, 32, 75)
const QCI_SECONDARY = ColorRGB(100, 110, 165)

sty = Style(; fg = QCI_CYAN, bold = true, dim = false)
```

- `fg`, `bg`, `bold`, `dim`, `underline`
- Use project colors for consistency.
- `Block` takes `border_style` and `title_style`.

---

## 6. Common Patterns in This Project

### Raw Model + Gate Testing (Mandatory)

```julia
m = KanbanModel()
m.db_path = ":memory:"
load_users!(m)           # must result in 0 users for first-time test

tb = TestBackend(78, 20)
reset!(tb.buf)
view(m, Frame(tb.buf, Rect(1,1,tb.width,tb.height), [], []))

@test find_text(tb, "No users — press [c] to create account") !== nothing
```

After any change to gate, login, seeding, or view code → re-run this pattern.

### Drive + Re-render Cycle

```julia
update!(m, KeyEvent('c'))
# feed characters...
update!(m, KeyEvent(:enter))

reset!(tb.buf)
view(m, ...)
# assert new state
```

**Always** re-render after `update!` / `handle_key!` before inspecting.

### Modals & No-Bleed

When a modal is open, previous content must not leak through:

```julia
@test find_text(tb, "Backlog") === nothing || occursin("modal title", ...)
```

Clear the area under the modal before rendering it.

### Small Terminal Handling

```julia
if area.width < 20 || area.height < 6
    set_string!(buf, area.x, area.y, "QCI KANBAN (small)", Style(; fg=QCI_CYAN, dim=true))
    return
end
```

### Custom Logo / Header Areas

This project uses a dedicated `render_qci_logo(buf, area)` + dynamic `logo_h` calculation based on terminal height.

---

## 7. Testing (See Also tachikoma-ui-testing.md)

**Primary tool: `Tachikoma.TestBackend`**

```julia
tb = TestBackend(80, 18)
view(m, Frame(tb.buf, Rect(1,1,80,18), [], []))

find_text(tb, "something")
row_text(tb, 5)
char_at(tb, 10, 3)
visual_rows(m; w=80, h=18)
```

**Golden rules in this repo**:
- Start gate tests from a **fresh raw model**.
- Re-render after every mutation.
- Assert both presence and **absence** (especially for modals).
- Test multiple sizes, including very small ones.
- Use `record_demo` / `record_app` for human-visible verification.

---

## 8. Important Gotchas & Anti-Patterns

**Never**:
- Rely on "it looks fine when I run `kanban()` manually".
- Render without re-rendering after `update!`.
- Let board content bleed under modals.
- Hardcode positions instead of using `split_layout` + `area`.
- Assume a fixed terminal size.
- Put complex logic inside `view`.

**Always**:
- Use `TestBackend` + inspection functions for UI claims.
- Start first-time user tests with zero users.
- Run the live app + create-account flow after changes that affect startup/gate (see `always-run-the-app-after-changes.md`).
- Clear areas under overlays.
- Respect the `Rect` passed to `view` / widgets.

---

## 9. Project-Specific Helpers & Conventions

- `visual_rows(m; w, h)` — very commonly used.
- `gate_frame_areas`, `plan_gate_modal_layout`, `render_gate_modal!`
- Project colors: `QCI_CYAN`, `QCI_NAVY`, `QCI_SECONDARY`
- Login gate must always be the first thing a fresh model shows.
- After any `src/` change that affects rendering or the gate → mandatory live verification.

---

## 10. When in Doubt

1. Read `.grok/docs/tachikoma-core.md` + `.grok/docs/tachikoma-ui-testing.md`
2. Look at recent tests in `test/runtests.jl`, `test/test_users.jl`, `test/test_board_render.jl`
3. Look at how the current `KanbanModel` implements `update!` and `view`
4. Use small, isolated `TestBackend` experiments

The official docs live at https://kahliburke.github.io/Tachikoma.jl/dev/ — this file + the testing doc are the **project-specific overlay** that actually matters for working in this codebase.

---

**This file is intended to be read by Grok Build (and other agents) at the start of any Tachikoma-related task.**
