# ADR-0002: Defer LinkedIn integration

**Status:** Accepted
**Date:** 2026-04-24
**Deciders:** Operations Lead, CEO

## Context

The v3 blueprint included LinkedIn as a social-posting target. Getting programmatic posting access to LinkedIn requires Marketing Developer Platform (MDP) approval, which:
- Requires a business justification review by LinkedIn.
- Has historically been slow (weeks-to-months) for small firms without pre-existing high-volume usage.
- Is not available through simple API keys.

The fallback is manual posting through the LinkedIn web UI, or paying an aggregator.

## Decision

**Do not integrate LinkedIn in v1.** Defer until after the system is live and the firm has time/justification to pursue MDP approval or a compatible vendor.

## Consequences

**Positive:**
- Removes a dependency on an external approval timeline that we do not control.
- Simplifies Workflow E.
- Removes the main rationale for using a paid aggregator (see ADR-0001).

**Negative / trade-offs accepted:**
- LinkedIn is a meaningful channel for the firm's white-collar placements. Not posting there means lost reach for those roles.
- Mitigation: until integrated, the Operations Lead manually posts to LinkedIn using Twenty's `SocialPost` draft as the source text. It adds ~3 minutes per post but costs nothing.

**Neutral / follow-up:**
- Revisit in Phase 2 (post go-live + 3 months). Two paths:
  1. Apply for LinkedIn MDP directly. Document the process; worst case we pay an aggregator.
  2. Keep manual LinkedIn posting and focus automation on Meta / X / Telegram where free access exists.

## Alternatives considered

- **Apply for LinkedIn MDP now:** slows project by unknown weeks. Not acceptable given the firm's timeline.
- **Use Blotato for LinkedIn specifically:** $29/mo is high for one channel; ADR-0001 already supersedes this.
- **Drop LinkedIn from the firm's channel mix:** not our call — that is a business decision for the CEO. Until then, manual.

## References

- LinkedIn MDP: https://learn.microsoft.com/linkedin/marketing/
- ADR-0001 (drop Blotato)
