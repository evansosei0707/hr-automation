# Workflow A — Communications

The front door. Handles every inbound WhatsApp message, regardless of what the candidate is asking about.

## Purpose

When a candidate sends a WhatsApp message, this workflow decides what happens next. Often, that means Claude drafts a reply and we send it. Sometimes, it means routing the message to a specialist workflow (B, C, or D). Sometimes, it means flagging a human.

This workflow is deliberately the "router + conversational catch-all." Specialised behaviour lives in the other workflows.

## Triggers

- WhatsApp webhook from Meta (`messages` event)
- Manual re-run via n8n for replay or debugging

## Inputs

- `wa_message_id` (string) — Meta's unique ID for the message
- `from` (E.164 phone) — the candidate
- `message_type` (text, voice, image, document, …)
- `body` (text) or media reference
- `timestamp` (epoch seconds)

## Outputs

- An outbound WhatsApp message, or
- A new `ReviewTask` in Twenty, or
- A delegation signal to Workflow B/C/D (by writing to a dispatch table they poll; we do not cross-invoke workflows directly)

And always:
- A new `conversation_message` row (inbound)
- On reply: a new `conversation_message` row (outbound)
- `Candidate.lastActivityAt` updated

## Step sequence (high level)

1. **Dedupe.** Check `wa_message_id` in Redis with SETNX. If already seen, exit. If new, proceed. Redis TTL 24h.
2. **Acquire conversation lock.** Redis `SET conv:{candidateId} {executionId} NX PX 60000`. If failed, enqueue for retry with exponential backoff.
3. **Start Lua heartbeat.** Every 15 seconds, a Lua script extends the lock TTL if and only if the lock value still matches this execution. See `03-integrations/claude-api.md` for the heartbeat script.
4. **Resolve candidate.** Look up by `whatsappNumber`. If new, create a Candidate with `consentStatus=pending`.
5. **Handle consent.** If `consentStatus=pending` and this is the first message, the outbound is the consent request — not a Claude reply.
6. **Transcribe if voice note.** See `03-integrations/openai-transcribe.md` for the rules on which voice notes get transcribed.
7. **Store inbound message.** `conversation_message` row with transcript if applicable.
8. **Classify intent.** Claude Haiku on the last 5 turns answers: is this (a) a reply to an ongoing workflow (B/C/D), (b) a DATA/DELETE request, (c) an open conversation, (d) a distress signal, (e) spam?
9. **Route.**
   - `(a)` → write to the relevant workflow's inbox table; that workflow picks it up on its next poll.
   - `(b)` → invoke the DPA handler (`04-operations/ghana-dpa.md`).
   - `(c)` → draft a reply with Claude Sonnet, send it, store outbound.
   - `(d)` → create a `ReviewTask` with `kind=compliance_flag` and send a gentle, non-committal holding reply.
   - `(e)` → silently drop, rate-limit the sender, log.
10. **Lua CAS release of the conversation lock.**
11. **Error branch.** Any throw lands here, writes to `workflow_errors`, releases the lock.

## Invariants

- Never send an outbound message while the conversation lock is not held.
- Never send a Claude-generated reply without storing it as a `conversation_message` outbound row first.
- Dedupe key TTL 24h, lock TTL 60s with heartbeat.
- The lock value is the n8n execution ID (or a UUID generated at lock acquisition). Release only if the value still matches (Lua CAS).
- Never transcribe a voice note that is not detected as English or Pidgin; route to manual review instead.

## Acceptance criteria

- **Duplicate webhook:** sending the same `wa_message_id` twice produces exactly one outbound reply and one `conversation_message` row.
- **Concurrent messages:** if a candidate sends three messages in 5 seconds, all three are processed sequentially, replies are in order, no lost messages.
- **Lock contention under load:** 50 concurrent candidates, 3 messages each — zero lost messages, zero interleaved replies.
- **Consent flow:** a new candidate who replies NO to consent receives an acknowledgement and has their Candidate record auto-purged after 48 hours.
- **Voice note in Twi:** routed to manual review queue, not transcribed.
- **Voice note in Pidgin:** transcribed, processed as a normal text message.
- **Claude failure:** if the Claude call throws, the workflow catches it, writes `workflow_errors`, releases the lock, and the orchestration workflow surfaces it on the next sweep.

## Monitoring

- `workflow_a_invocations_total` counter
- `workflow_a_duration_seconds` histogram
- `workflow_a_lock_wait_seconds` histogram (should rarely exceed 2s)
- `workflow_a_errors_total` counter

## Open questions

None at spec time. Add here if any surface during implementation, and resolve via the architect subagent.
