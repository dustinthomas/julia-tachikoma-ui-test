# ═══════════════════════════════════════════════════════════════════════
# notify/outbox.jl — durable OutboxNotifier + flush_outbox!.
#
# Part of `module Notify`. `notify!` renders the event and writes a durable
# row into the board store's outbox table. `flush_outbox!` drains pending
# rows through a sender notifier (SMTP in prod, Fake/Null in tests) and marks
# each row sent.
# ═══════════════════════════════════════════════════════════════════════

export OutboxNotifier, flush_outbox!

struct OutboxNotifier <: AbstractNotifier
    store::AbstractBoardStore
end

function notify!(n::OutboxNotifier, event::NotificationEvent)
    enqueue_outbox!(n.store; event_kind = event.kind, recipient_email = event.recipient_email,
                    subject = render_subject(event), body = render_body(event))
end

"""
    flush_outbox!(store, sender) -> Int

Drain all pending outbox rows through `sender` (via `deliver!`), marking each
row sent. Returns the number of rows successfully delivered.
"""
function flush_outbox!(store::AbstractBoardStore, sender::AbstractNotifier)::Int
    sent = 0
    for row in pending_outbox(store)
        if deliver!(sender, row["recipient_email"], row["subject"], row["body"])
            mark_sent!(store, row["id"])
            sent += 1
        end
    end
    sent
end
