# ADR-0003: Google Calendar as the Ghanaian public holidays source

**Status:** Accepted
**Date:** 2026-04-24
**Deciders:** Operations Lead

## Context

The v3 blueprint hardcoded Ghanaian public holidays inline. This approach has known failure modes:

- Lunar Islamic holiday dates change annually (Eid al-Fitr, Eid al-Adha) and are only confirmed a few weeks in advance by official proclamation.
- Holidays move for observance rules (a holiday falling on a Sunday often observed the following Monday).
- The government occasionally adds or changes holidays mid-year (e.g. special commemorations).
- v2 had multiple factual errors in its holiday list (notably Founder's Day dated to August instead of September 21).

A hand-maintained list is a known source of drift.

## Decision

Pull Ghanaian holidays from Google's public holiday calendar (`en.gh#holiday@group.v.calendar.google.com`) daily and mirror into Twenty as a `Holiday` object. Allow the Operations Lead to manually override entries in Twenty when needed (e.g. firm-specific closures, corrections).

## Consequences

**Positive:**
- Automatic updates when Google updates the calendar, including lunar adjustments.
- Free, no auth required for a public calendar (API key only).
- Manual override keeps us sovereign — we are not 100% at Google's mercy.
- Removes a class of date bugs.

**Trade-offs accepted:**
- Google occasionally lags official proclamations by a day or two; the Operations Lead verifies in January each year.
- One more integration to maintain. Minimal; the sync is ~30 lines of code.

**Neutral / follow-up:**
- Verify the calendar's reliability for lunar dates in the first year; if we lose trust, we can switch to a canonical Ghana government source if one becomes available programmatically.

## Alternatives considered

- **Hardcode and maintain in code:** rejected. v2 had errors; human-maintained lists drift.
- **A Ghana government API:** none exists in machine-readable form at time of decision.
- **A third-party holidays API service:** adds cost and dependency for no added accuracy over Google.

## References

- https://calendar.google.com → Ghana Holidays public calendar
- `docs/03-integrations/google-calendar.md`
