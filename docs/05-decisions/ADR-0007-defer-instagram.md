# ADR-0007: Defer Instagram integration

**Status:** Accepted
**Date:** 2026-04-29
**Deciders:** HRA Project Lead

## Context

Workflow E (social posting; `docs/02-workflows/e-social-posting.md`) was scoped in the v3.1 blueprint to fan out a single approved job post to four channels: Facebook Page, Instagram Business account, X, and Telegram — all via free native APIs (per ADR-0001, no Blotato; per ADR-0002, no LinkedIn). Phase 4 voucher work proved three of the four:

- Facebook Page post + delete via Page Access Token: green (`scripts/voucher/meta-fb.sh`, commit `d561219`).
- Telegram channel post: green (`scripts/voucher/telegram.sh`, commit `79a93d2`).
- X: deferred separately, pending developer-access approval. Out of scope for this ADR.

The fourth — **Instagram Business account linked to the same Meta Business Account that owns the Facebook Page (TechTag)** — failed structurally during Phase 4 setup. Two distinct paths were attempted:

1. **Business Settings path** (Meta Business Manager → Business Assets → connect Instagram).
2. **Page-side path** (Facebook Page → Settings → Linked Accounts → Instagram).

Both produced the same refusal:

> "Couldn't add your Page and Instagram account to a Business Account... won't have access to other features like comparing insights or posting across your profiles."

The 48-hour soft-hold theory was tested across three days and disproven — the failure does not abate with time. The refusal is structural to this particular Meta Business / Page / IG account combination, not time-based.

What we have confirmed works:
- The Page Access Token has the IG scopes (`instagram_basic`, `instagram_content_publish`) — verified at System User token regeneration.
- The Page itself is healthy and posting via Graph API v25.0.
- The wire-level voucher script `scripts/voucher/meta-ig.sh` is committed (`d561219`) and skip-gates cleanly when `META_IG_USER_ID` is empty (the current state). It logs the skip to `event_log` so the operator sees an explicit "blocked external" signal rather than a missed-config one.

What is missing: a `META_IG_USER_ID` value, which can only come from a successfully linked IG Business account. Meta's UI refuses the link.

## Decision

**Do not integrate Instagram in v1.** Workflow E ships v1 with Facebook Page + Telegram + (X if developer access lands), without Instagram.

The voucher script `scripts/voucher/meta-ig.sh` stays in the repo as committed-but-unrunnable. It serves two purposes: (a) documents the exact two-step IG publish + delete wire shape so the next attempt isn't a re-research exercise, and (b) is runnable the moment `META_IG_USER_ID` is populated — no code change needed.

## Consequences

**Positive:**

- Unblocks Workflow E's v1 build. Three-channel fan-out (FB + Telegram + X-when-approved) is enough for the firm's launch reach; Instagram-specific reach was always a stretch goal.
- Removes a dependency on Meta's account-link approval surface, which we have no leverage to escalate.
- Pattern matches ADR-0002 (LinkedIn): same class of "free-tier channel where the platform's onboarding wall is the blocker, not the firm's intent."

**Negative / trade-offs accepted:**

- Instagram is a meaningful channel for blue-collar candidate reach in Ghana — younger candidates, especially in hospitality and retail roles, often find roles via IG before Facebook.
- Mitigation: the firm's IG strategy (if any) becomes manual. Operator copies the FB post text from Twenty's `SocialPost` draft and posts via the IG mobile app, ~2-3 minutes per post. Workflow E's draft is platform-aware (per its spec), but the IG draft simply goes unused for now.
- We lose engagement-sampling on IG. FB engagement data via Graph Insights still works.

**Neutral / follow-up:**

- Revisit triggers — either is sufficient to reopen this ADR:
  1. **Different IG Business account in a different Meta Business Manager.** If the firm acquires (or uses an existing) IG Business account that's NOT entangled with the current Meta Business Manager's structural refusal, the voucher runs as-is (env var fill + activate).
  2. **Workflow E v2 prioritization** where IG becomes load-bearing for the firm's reach goals. At that point, the cost of fighting Meta's link maze (or pursuing a paid alternative) becomes justifiable; today it isn't.
- During the 2-week post-launch calibration window, monitor `SocialPost` engagement metrics from FB + Telegram. If reach is meaningfully short of forecast and the firm's CEO judges IG would close the gap, escalate to a Phase 2 ADR superseding this one.
- The `meta-ig.sh` voucher is part of the supersession test: the moment a fix lands, the script runs and writes the `event_log.publish_and_delete_succeeded` row that closes this ADR.

## Alternatives considered

- **Spend further hours on Meta's account-linking maze.** Rejected: three-day exploration produced no progress; Meta's error message is intentionally non-diagnostic and there's no support path. Time-boxed sunk-cost.
- **Acquire a throwaway IG account specifically for this project.** Rejected: ToS-risky (Meta's automated systems flag throwaway accounts), creates ongoing maintenance burden (account hygiene, password rotation, separate 2FA), and doesn't actually solve the structural Business-Account linkage problem if the throwaway can't be linked either.
- **Use a third-party IG poster service** (e.g. Buffer, Later, Zapier-with-IG-integration). Rejected: adds vendor dependency, monthly cost ($15-50 typical), and a security surface (third party with content + posting authority on the firm's IG account, IF an IG account ever exists). Same architectural objection as ADR-0001 raised against Blotato. If we ever go this route, it deserves its own ADR.
- **Drop Instagram from the firm's social mix entirely.** Not our call — that's a business decision for the firm's CEO. Until they say otherwise, the channel stays in the firm's strategy and we leave the manual posting path open via the unused `SocialPost` draft.

## References

- ADR-0001 — drop Blotato (the original "no paid social aggregator" decision)
- ADR-0002 — defer LinkedIn (precedent pattern: same class of platform-onboarding blocker)
- `scripts/voucher/meta-ig.sh` — the skip-gated voucher that becomes runnable when this ADR is superseded
- `docs/02-workflows/e-social-posting.md` — Workflow E spec (will need a small update to acknowledge IG-deferred when the Phase 4 status rollup lands)
- Meta Graph API IG publishing reference: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login (kept for whenever the link unblocks)
