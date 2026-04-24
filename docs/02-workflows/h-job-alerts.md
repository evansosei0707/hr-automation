# Workflow H — Job Alerts for Re-Engaged Candidates

Turn strong-but-not-selected candidates into a warm pool we can re-activate the moment a similar role comes in.

## Purpose

A candidate applies for "Frontend Developer" at Client X. They are strong. We shortlist three stronger ones. This candidate gets a polite rejection. Four weeks later, Client Y opens a Frontend Developer role. Without this workflow, the strong candidate is a row in the CRM that nobody notices. With this workflow, they get:

> *"Hi Kwame — last month you applied for a Frontend Developer role and you were a strong candidate, but the position filled quickly. We just received a new Frontend Developer opening at a different client. Are you still open to new roles? Reply YES and we'll fast-track you."*

They reply YES, the application skips most of the intake, and they go straight to the Operations Lead's shortlist review.

This is one of the highest-leverage features in the whole system. It is cheap to build, it uses data we already collect, and it converts wasted effort into warm leads.

## Triggers

- New `Job` row in Twenty transitioning to `status=open`
- Manual "find candidates for this job" trigger in Twenty (for back-filling old jobs)

## Inputs

- `jobId`
- Linked `category`, `seniority`, `location`, `salaryMinGhs`
- Candidate pool: all Candidates with an Application where `reEngagementEligible=true AND job.category=<match>` created within the last 6 months

## Outputs

- `Application` rows (new, linking matched candidates to this new Job) with `status=re_engagement_offered`
- WhatsApp messages to matched candidates
- On YES reply: Application advances to `status=re_engagement_accepted`, `ReviewTask` created for Operations Lead, priority=high
- On NO or timeout: Application closed with `status=not_interested` or `withdrawn`

## Eligibility criteria (the match rules)

A candidate is eligible for re-engagement on a new Job when **all** of:

1. They have a previous Application with `reEngagementEligible=true`. This flag is set by Workflows B and C when `status=not_selected AND notSelectedReason=position_filled`. Candidates who were `not_a_match` do not qualify.
2. The previous Application's Job shared at least one `SkillTag` (via `CandidateSkillTag`) with the new Job's category or required skills.
3. Previous Application is less than 6 months old.
4. Candidate's `consentStatus=granted` and `dataRetentionPolicy` is not `pending_deletion`.
5. Candidate has not been re-engaged in the past 14 days (anti-spam).
6. The new Job's salary range is within ±30% of what we inferred the candidate was seeking, if we know it.
7. Candidate's `lastActivityAt` is within the last 90 days (they are still warm — not someone we have lost touch with).

## Step sequence

1. On Job open, query the candidate pool with the criteria above. Limit to top 20 matches by `strengthTier` then by recency.
2. For each match:
   - Create an `Application` row with `status=re_engagement_offered`.
   - Compose a personalised WhatsApp message using the candidate's first name, the previous role reference ("last month you applied for Frontend Developer"), and the new role. Claude Haiku drafts this; the template is strict to prevent over-promising.
   - Send the message. Set `reEngagedAt` on the Application.
3. Wait for reply with a 72h timeout.
4. On YES:
   - Advance to `status=re_engagement_accepted`.
   - Create a ReviewTask with `kind=fast_track_candidate`, linked to the new Application, priority=high.
   - Reply: *"Great — we're putting you forward. The team will review and come back to you within a few days."*
5. On NO or "not interested":
   - Advance to `status=not_interested`.
   - Reply: *"Understood. We'll keep you on file for future roles if that's okay."*
6. On 72h timeout:
   - Advance to `status=withdrawn`.
   - No outbound message (already sent the first one; don't chase).

## The message template (guidance, not verbatim)

Claude Haiku generates the final text, but it must:
- Address by first name.
- Reference the previous role type and approximate timeframe ("last month", "a few weeks ago", "in the past").
- Not name the previous client unless we can confirm consent.
- Not mention the candidate's score or tier.
- Mention the new role (title only — client name only if marked publicly disclosable).
- End with a clear YES/NO prompt.
- Be 2–4 sentences. Not a paragraph.

Example output (for reference, do not hard-code):
> "Hi Kwame — a few weeks ago you applied for a Frontend Developer role and we really liked what we saw, but that position filled fast. A new Frontend Developer opening just came in. Are you still open to new roles? Reply YES or NO."

## Invariants

- No candidate gets a re-engagement message from more than one open job on the same day. If multiple matches fire, pick the best-matching Job and queue the others for later.
- Never mention the previous client by name without confirmed disclosure consent.
- Never include salary figures in the opening message.
- If the candidate has an open Application on any other Job in `interviewing`, `offered`, or `placed` status, skip them — they are busy.
- Anti-spam: 14-day cooldown per candidate, independent of jobs. Max 4 re-engagement messages per candidate per year.

## Acceptance criteria

- **Happy path:** Job opens, 8 candidates match, 8 messages fire within 5 minutes. 3 reply YES within 24h, 2 reply NO, 3 don't reply. After 72h, states are: 3 re_engagement_accepted (ReviewTasks created), 2 not_interested, 3 withdrawn.
- **Anti-spam cooldown:** candidate was re-engaged 10 days ago. New Job opens that matches. Candidate is NOT contacted this round.
- **Busy candidate:** candidate is `interviewing` on Job X. Job Y opens that matches. Skipped.
- **Category mismatch:** Job is for a Security Guard; candidates who previously applied for Delivery Driver are NOT contacted even though both are "blue-collar." Category match is required.
- **Personalisation:** message correctly uses the candidate's first name and correctly describes the previous role type.
- **Privacy:** message does not reveal previous client name.

## Monitoring

- `workflow_h_matched_candidates_total`, labelled by `job.category`
- `workflow_h_messages_sent_total`
- `workflow_h_yes_rate` (yes / (yes+no+timeout))
- `workflow_h_cooldown_skips_total`
- Conversion downstream: of re-engagement accepted, how many advanced to interview, to placement. (Long-feedback metric — tracked in the weekly report.)

## Open questions

- Do we want candidates to opt out of re-engagement specifically, independent of full deletion? Likely yes — add a `DATA_MINIMAL` reply option that sets `reEngagementOptOut=true` on the Candidate. Adding to Phase 2 unless it comes up.
- Do we let candidates proactively say "tell me about new Frontend Dev roles"? Yes — handled by Workflow A routing intent to a simple subscription handler. Not in this workflow's scope.
