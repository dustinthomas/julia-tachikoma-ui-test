# ═══════════════════════════════════════════════════════════════════════
# notify/interface.jl — AbstractNotifier + NullNotifier + template renderers.
#
# Part of `module Notify`. `notify!(n, event)` handles a NotificationEvent;
# `deliver!(n, recipient, subject, body)` delivers an already-rendered message
# (used when draining the outbox). Subject/body templates are per event kind.
# ═══════════════════════════════════════════════════════════════════════

export AbstractNotifier, NullNotifier
export notify!, deliver!, render_subject, render_body, sanitize_header

abstract type AbstractNotifier end

# ── Header/body hardening (pure) ──────────────────────────────────────────
"""
    sanitize_header(s) -> String

Strip CR, LF and all other control characters from `s` so an attacker-supplied
issue key/title/name cannot inject extra SMTP headers (header-injection) or
smuggle content across the subject/body boundary. Printable text is preserved.
"""
function sanitize_header(s::AbstractString)::String
    filter(c -> !iscntrl(c), String(s))
end

# ── Templates (pure) ─────────────────────────────────────────────────────
"""
    render_subject(event) -> String

Email subject line for a NotificationEvent, keyed on `event.kind`. The issue
key/title are sanitized (no CR/LF/control chars) before interpolation.
"""
function render_subject(event::NotificationEvent)::String
    key = sanitize_header(event.issue_key)
    title = sanitize_header(event.issue_title)
    k = event.kind
    if k === :assigned
        "[$(key)] You were assigned: $(title)"
    elseif k === :status_changed
        "[$(key)] Status changed: $(title)"
    elseif k === :comment_added
        "[$(key)] New comment: $(title)"
    elseif k === :due_soon
        "[$(key)] Due soon: $(title)"
    else # :mentioned
        "[$(key)] You were mentioned: $(title)"
    end
end

"""
    render_body(event) -> String

Plain-text email body for a NotificationEvent, keyed on `event.kind`.
"""
function render_body(event::NotificationEvent)::String
    actor = sanitize_header(isempty(event.actor_name) ? "Someone" : event.actor_name)
    key = sanitize_header(event.issue_key)
    title = sanitize_header(event.issue_title)
    k = event.kind
    lead = if k === :assigned
        "$actor assigned $(key) to you."
    elseif k === :status_changed
        "$actor changed the status of $(key)."
    elseif k === :comment_added
        "$actor commented on $(key)."
    elseif k === :due_soon
        "$(key) is due soon."
    else # :mentioned
        "$actor mentioned you on $(key)."
    end
    detail = isempty(event.detail) ? "" : "\n\n$(event.detail)"
    "$lead\n\n$(key): $(title)$detail"
end

# ── NullNotifier: default no-op sink ─────────────────────────────────────
struct NullNotifier <: AbstractNotifier end

notify!(::NullNotifier, ::NotificationEvent) = nothing
deliver!(::NullNotifier, ::AbstractString, ::AbstractString, ::AbstractString) = true
