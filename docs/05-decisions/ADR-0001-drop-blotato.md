# ADR-0001: Drop Blotato; use free native social APIs directly

**Status:** Accepted
**Date:** 2026-04-24
**Deciders:** Operations Lead, CEO

## Context

The v3 blueprint proposed using Blotato ($29/mo) as a social-posting aggregator, mainly because it simplifies LinkedIn posting (which does not have a free, easily-approved API for third-party apps).

On review:
- The firm chose to defer LinkedIn entirely (see ADR-0002).
- Blotato's remaining value (wrapping Facebook, Instagram, X, Telegram) is replaceable by 4 direct API integrations, all free, all well-documented, none requiring approval hurdles.
- $29/mo × 12 months = $348/year for a wrapper we do not structurally need.

## Decision

Do not use Blotato. Integrate directly with:

- Meta Graph API for Facebook + Instagram
- X API free tier (500 posts/month — ample for our volume)
- Telegram Bot API

## Consequences

**Positive:**
- $348/year saved.
- Fewer third-party dependencies. One less vendor with access to firm data.
- Direct API access means we can use platform-specific features (e.g. X reply-threading, Instagram Reels later) without an aggregator abstraction.

**Trade-offs accepted:**
- More integration work: four workflows instead of one. Mitigated by the fact that each is well-documented and n8n has built-in credential types for all of them.
- Rate-limit management is per-platform instead of abstracted. Acceptable; our volume is well under free-tier caps on all four.
- When a platform deprecates an endpoint, we handle it directly rather than the aggregator handling it for us.

**Neutral / follow-up:**
- If Phase 2 brings more platforms (Threads, TikTok, BlueSky), revisit.
- If the firm adds LinkedIn later, reopen the aggregator question at that point.

## Alternatives considered

- **Blotato:** one integration but $29/mo and an extra hop. Redundant without LinkedIn.
- **Publer / Buffer / Hootsuite / Later:** broadly the same pattern and price as Blotato. Same trade-off.
- **Zapier/Make social actions:** operational cost per post plus vendor lock-in.

## References

- v3 research round — Blotato pricing verified April 2026
- Meta Graph, X, Telegram free-tier quotas documented in `docs/03-integrations/`
