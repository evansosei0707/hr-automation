# Your Role as Orchestrator

This doc is for the human running the system day-to-day — typically the HR firm's operations lead. It defines what the human does vs. what the system does, so both Claude Code (during build) and the operator (during run) know the line.

## The three layers

```
┌───────────────────────────────────────────────────────┐
│  CEO / Hiring Manager                                 │
│  — approves job posts, owns client relationships      │
│  — reviews weekly report, sets firm-level priorities  │
└───────────────────────────────────────────────────────┘
┌───────────────────────────────────────────────────────┐
│  Operations Lead (the Orchestrator)                   │
│  — triages the AI review queue twice daily            │
│  — handles manual-review voice notes                  │
│  — approves candidate shortlists                      │
│  — publishes social posts                             │
│  — monitors the weekly calibration scorecard          │
└───────────────────────────────────────────────────────┘
┌───────────────────────────────────────────────────────┐
│  The System (Twenty + n8n + Claude)                   │
│  — all inbound/outbound WhatsApp messaging            │
│  — CV parsing and initial scoring                     │
│  — structured blue-collar screening                   │
│  — scheduling offers and booking                      │
│  — social post fan-out                                │
│  — weekly reports, alerts, re-engagement              │
└───────────────────────────────────────────────────────┘
```

## The Operations Lead's daily rhythm

**Morning (10–15 minutes):**
- Check `Review Queue` in Twenty — any candidates flagged for human judgement.
- Listen to any manual-review voice notes.
- Approve or reject shortlists pending for the client's review.

**Midday (as needed):**
- Respond in-line to any escalations the system pinged you about.

**Evening (10 minutes):**
- Clear the review queue for the day.
- Check the `System Alerts` channel for anything the orchestration workflow flagged.

**Weekly (Monday, 30 minutes):**
- Read the weekly summary report.
- During calibration window only: audit 10 random AI decisions.
- Update the active plan in `plans/active-plan.md` if priorities shifted.

## Decisions the Operations Lead owns

- Which candidates get shortlisted to the client.
- Which roles are "white-collar" vs "blue-collar" (affects which workflow processes them).
- Whether to override a system-generated rejection.
- Tone adjustments in the Claude system prompt (e.g. "be warmer in the opening").
- When to pause a workflow if something is off.

## Decisions the CEO owns

- Whether to post a new job publicly.
- Client-facing communications about a specific placement.
- Firm-level policy (e.g. "we no longer work with X category of role").
- Go/no-go on go-live and on graduating past the calibration window.

## Decisions the system is trusted with

- Which WhatsApp message to send in reply, within the bounds of its system prompt.
- Scoring a candidate against a rubric.
- Booking an interview into an available slot.
- Sending "still interested?" follow-ups to warm candidates.
- Posting pre-approved content to social media at a scheduled time.

## Decisions the system is NOT trusted with

- Making a hiring recommendation to the client without human review.
- Communicating salary figures.
- Promising a placement timeline.
- Declining a candidate on sensitive grounds (age, disability, appearance).
- Anything that would land in an email signed by the firm.

## When the system escalates to the Orchestrator

1. AI confidence below threshold on any scoring decision.
2. A voice note that could not be transcribed and the candidate declined to re-record.
3. A message that triggers the safety classifier (e.g. someone expressing distress).
4. Any error that broke a workflow mid-execution and could not self-heal.
5. Any anomaly from the weekly calibration drift detector.

The system escalates by creating a Task in Twenty, assigned to the Orchestrator, and posting a WhatsApp note to the staff channel. It does not escalate by DM to the CEO unless the Orchestrator is unreachable for longer than 4 hours.
