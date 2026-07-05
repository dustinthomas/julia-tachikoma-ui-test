# ═══════════════════════════════════════════════════════════════════════
# notify/smtp.jl — SMTPNotifier with an injectable transport.
#
# Part of `module Notify`. The transport is injectable: FakeTransport records
# sends (used in every test); the real SMTPClient transport is only ever used
# when `config.smtp.enabled` — it is never exercised in tests and is marked
# `# COV_EXCL`.
# ═══════════════════════════════════════════════════════════════════════

import SMTPClient

export AbstractTransport, FakeTransport, SMTPNotifier, sent_count

abstract type AbstractTransport end

# ── FakeTransport: records every send (tests) ────────────────────────────
struct SentMail
    from::String
    to::String
    subject::String
    body::String
end
struct FakeTransport <: AbstractTransport
    sends::Vector{SentMail}
end
FakeTransport() = FakeTransport(SentMail[])
sent_count(t::FakeTransport) = length(t.sends)

function send_mail(t::FakeTransport, from, to, subject, body)::Bool
    push!(t.sends, SentMail(String(from), String(to), String(subject), String(body)))
    true
end

# ── SMTPNotifier ──────────────────────────────────────────────────────────
struct SMTPNotifier <: AbstractNotifier
    config::SmtpConfig
    transport::AbstractTransport
end

function deliver!(n::SMTPNotifier, recipient::AbstractString, subject::AbstractString, body::AbstractString)::Bool
    n.config.enabled || return false   # config-gated: never send unless enabled
    valid_email(recipient) || return false          # reject malformed/injected recipient
    send_mail(n.transport, n.config.from, sanitize_header(recipient),
              sanitize_header(subject), body)
end

notify!(n::SMTPNotifier, event::NotificationEvent) =
    deliver!(n, event.recipient_email, render_subject(event), render_body(event))

# ── Real SMTPClient transport (live SMTP only) ──────────────────────────────
# COV_EXCL_START — requires a live SMTP server; excluded from coverage.
struct SMTPTransport <: AbstractTransport
    url::String
    user::String
    password::String
end
SMTPTransport(cfg::SmtpConfig) =
    SMTPTransport("smtp://$(cfg.host):$(cfg.port)", cfg.user, cfg.password)

function send_mail(t::SMTPTransport, from, to, subject, body)::Bool
    opts = SMTPClient.SendOptions(username = t.user, passwd = t.password)
    message = SMTPClient.get_body([String(to)], String(from), String(subject), String(body))
    SMTPClient.send(t.url, [String(to)], String(from), message, opts)
    true
end
# COV_EXCL_STOP
