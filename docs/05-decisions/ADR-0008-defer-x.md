# ADR-0008: Defer X integration

**Status:** Accepted
**Date:** 2026-04-29
**Deciders:** HRA Project Lead

## Context

Workflow E (social posting; `docs/02-workflows/e-social-posting.md`) was scoped to fan out a single approved job post to Facebook Page, Instagram, X, and Telegram via free native APIs (per ADR-0001 — no Blotato; per ADR-0002 — no LinkedIn). Phase 4 voucher work resolved three of the four:

- Facebook Page: green (`scripts/voucher/meta-fb.sh`, commit `d561219`).
- Telegram: green (`scripts/voucher/telegram.sh`, commit `79a93d2`).
- Instagram: deferred per ADR-0007 (Meta structurally refused the Page↔IG account link).

The fourth — X — has been blocked on developer-access approval since the start of Phase 4. The application was submitted 2026-04-27 ("fire-and-forget today" per the Phase 4 brief). As of 2026-04-29 (two days later), approval is still pending.

X's free-tier developer-access timeline has been wildly inconsistent across 2024-2026: some applications resolve in hours, others take weeks, others are rejected outright with no useful feedback. We have no leverage to escalate and no way to estimate "weeks vs. months" for our specific application.

Unlike Instagram (where ADR-0007 captures a structural refusal we've actively reproduced), the X situation is open-ended waiting. No voucher script has been authored yet — there's nothing to script against until access lands.

## Decision

**Do not integrate X in v1.** Workflow E ships v1 with Facebook Page + Telegram only.

X voucher work and any integration spec (`docs/03-integrations/x-api.md` already exists from the v3.1 blueprint round; it stays as future-reference but is not exercised) are deferred until either developer access is granted or the alternative-vendor decision below is taken.

## Consequences

**Positive:**

- Closes Phase 4 cleanly. The remaining "unstarted" entry on the voucher list is removed; nothing in the plan now waits indefinitely on an external approval timeline we don't control.
- Workflow E becomes a 2-channel fan-out for v1 (FB + Telegram), simpler than the 4-channel original. Less code, less per-platform error handling, less monitoring surface.
- Pattern-matches ADR-0002 (LinkedIn) and ADR-0007 (Instagram): same class of "free-tier channel where the platform's onboarding wall is the blocker, not the firm's intent." This makes three. The cumulative deferral suggests a structural bias in our approach — relying on free-tier APIs from incumbent platforms — that's worth a deliberate look in Phase 5+ if the channel-mix gap becomes a business problem.

**Negative / trade-offs accepted:**

- One fewer fan-out channel for v1. Modest reach loss for white-collar candidate sourcing — X carries some weight there for tech / professional roles, less so for blue-collar where Telegram + WhatsApp dominate the firm's expected audience based on Ghana market patterns.
- If/when X access lands later, building the voucher + integration is a half-day of work plus the X voucher's own potential surprises. Not free, but bounded.

**Neutral / follow-up:**

- **30-day re-trigger.** If X developer access is still pending on or after **2026-05-27** (30 days post-application), revisit. At that point the question becomes: is the channel valuable enough to pay for it? Options at that decision point:
  1. Pay for X API access via X's own paid tiers ($100/mo Basic, etc.).
  2. Use a third-party X-posting wrapper (similar architectural objection as ADR-0001 raised against Blotato; revisit on its own merits).
  3. Continue waiting and accept the 2-channel v1 indefinitely.
  Each of these warrants its own ADR if pursued. Not pre-deciding here.
- **Approval-lands trigger.** If X developer access is granted before the 30-day mark, build the voucher in the next free Phase-4-style window. Estimated 2-4 hours: voucher script + integration doc update + workflow-builder dispatch for the X-specific path inside Workflow E (when E is built).
- The integration spec at `docs/03-integrations/x-api.md` (authored during the v3.1 blueprint round) stays in place as a reference for the eventual build — same status as the Instagram voucher script under ADR-0007.

## Alternatives considered

- **Wait for X approval before closing Phase 4.** Rejected: open-ended timeline with no leverage. Phase 4's purpose is to validate that vendor APIs work in our environment, not to validate that we can convince vendors to grant us access. Three vouchers (Telegram, FB, plus the integrated WhatsApp webhook) already proved the social-fan-out architecture works end-to-end; X is incremental, not foundational.
- **Pay for X API access today.** Rejected: $100/mo for one channel that isn't load-bearing for the firm's expected v1 audience is poor value at this stage. Re-evaluate at the 30-day mark with real launch data.
- **Use a third-party X poster** (e.g. RapidAPI's offerings, Buffer-style aggregators with X integration). Rejected for now on the same architectural grounds as ADR-0001 — vendor dependency + cost + security surface. If we ever go this route, it deserves a fresh ADR with current vendor research.
- **Drop X from the firm's social mix entirely.** Not our call — that's a business decision for the firm's CEO. The channel stays in the firm's strategy on paper; the firm can post manually via the X mobile app using the `SocialPost` draft until automation is unblocked.

## References

- ADR-0001 — drop Blotato (no paid social aggregator)
- ADR-0002 — defer LinkedIn (precedent: free-tier API access denied for our setup)
- ADR-0007 — defer Instagram (precedent: structural Meta refusal)
- `docs/03-integrations/x-api.md` — integration spec, kept as future reference
- `docs/02-workflows/e-social-posting.md` — Workflow E spec; will need a small update to acknowledge X-deferred when the Phase 4 status rollup lands
- X developer portal: https://developer.x.com (where approval status is visible)
