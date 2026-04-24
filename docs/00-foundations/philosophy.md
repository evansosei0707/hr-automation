# Philosophy & Core Principles

These are the principles that override everything else. When a spec contradicts a principle, the principle wins; flag the spec for review.

## 1. The system handles the typing, humans handle the thinking

Automation displaces the repetitive work of recruiting — copying WhatsApp chats into spreadsheets, sending "still interested?" messages, chasing interview confirmations, posting the same job to five platforms. It does not displace judgement. Final hiring decisions, tough conversations, client strategy, and anything that needs moral nuance stays with humans.

If a feature proposal edges toward automating judgement, push back. That is not our lane.

## 2. WhatsApp is the product for candidates

Blue-collar candidates in Ghana live on WhatsApp. Any flow that asks a candidate to install an app, create an account, log in to a portal, or open a web link to apply is a feature that kills conversion. Our bar: **everything a candidate needs to do happens in a WhatsApp thread.** Exceptions require a good reason.

## 3. Build for the firm, not for the category

We are not building a SaaS. We are automating one HR firm in Accra. Features that only make sense across many firms (generic dashboards, marketplace mechanics, white-label theming) cost time we do not have. If the firm's owner says "we do this weirdly because X" — we honour the weirdness. Ghana-specific, firm-specific, and owner-specific quirks are features, not bugs.

## 4. AI is a probabilistic assistant, not a source of truth

Every AI decision is reviewed by a human for the first two weeks. After that, the system trusts AI more on repeated, narrow tasks (phone-number extraction, structured screening questions) and less on open-ended ones (rejection phrasing, edge-case judgement calls). We never fully remove the supervisor role.

When Claude says "I am confident," that is still just a number. Design every AI touchpoint so a wrong answer is visible and reversible.

## 5. Idempotent by default

Any operation that could run twice — because n8n retried, because the user double-tapped, because the network hiccuped — must be safe to run twice. Database inserts use `ON CONFLICT DO NOTHING` or explicit upserts. WhatsApp sends are deduplicated by message ID. Redis locks prevent concurrent processing of the same conversation.

If a function cannot be made idempotent, document why, and gate it with a lock.

## 6. Bias toward boring

We prefer boring technology we can run on a $40 VPS with no drama over clever technology that needs constant attention. Postgres beats a specialised vector DB. Cron beats a workflow engine we would have to build. The less novel the tool, the more likely it will still be working in six months.

## 7. Observability is not optional

Every workflow logs its inputs, outputs, errors, and AI-cost per run. Every external API call logs its URL, status, and latency. "Something is wrong" must be answerable without spelunking through n8n execution history. The structured log is the product's nervous system.

## 8. Friction where it matters, not where it doesn't

Friction for the HR firm's staff (approval gates, review queues, double-confirmation on destructive actions) is good friction. Friction for candidates (extra questions, delays, ambiguous bot replies) is bad friction. When a trade-off comes up, push the cost onto staff, not onto candidates.

## 9. Ghanaian-default, not Ghanaian-aware

The system defaults to Accra time, GHS currency for internal accounting, Ghanaian phone formats, English and Pidgin for conversation, and Ghanaian public holidays. "International" or "global" is not the default; it is a special case we do not need yet.

## 10. Reversible > perfect

Every architectural choice should answer the question: "if we are wrong about this in three months, how hard is it to change?" Choices with a cheap escape route get approved faster than clever ones that lock us in. This is especially true for vendor choices — wherever possible, wrap a vendor behind our own interface.
