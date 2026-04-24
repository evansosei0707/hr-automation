# Workflow C — Blue-Collar Screening

Structured WhatsApp screening for high-volume roles: drivers, warehouse staff, security, cleaners, hospitality. Where 200 applicants is a normal day.

## Purpose

Blue-collar candidates rarely have CVs. Scoring by structured questions over WhatsApp is the actual signal source. This workflow asks a short, Ghana-appropriate set of questions, scores the answers, and separates candidates into tiers so the human only spends time on strong matches.

## Triggers

- New `Application` row with `Job.collarType=blue`
- A candidate reply in an in-progress screening conversation — Workflow A routes these to C's inbox table

## Inputs

- `applicationId`, `candidateId`, `jobId`
- The screening script for this job category (see below)
- The candidate's current screening state (which question are we on, previous answers)

## Outputs

- A sequence of WhatsApp prompts, one at a time, in the candidate's preferred language setting
- Structured answers stored in `candidate_facts` and on the Application
- `Application.score`, `scoreBreakdown`, `status=screened`
- `strengthTier` on the Candidate
- `CandidateSkillTag` rows (e.g. `driver-license-class-c`, `forklift-certified`)

## The screening script

Scripts are defined per job category in `twenty-schema/objects/` under `ScreeningScript`. Each script is a list of questions with type, validation, and scoring weight.

Example script for a delivery driver role:

```yaml
- id: location
  prompt: "Which city are you currently living in?"
  type: free_text
  weight: 0.05
  scoring: presence_only

- id: own_transport
  prompt: "Do you own a motorbike or can you use one reliably? (YES / NO)"
  type: yes_no
  weight: 0.30
  scoring: { yes: 30, no: 0 }

- id: driving_experience_years
  prompt: "How many years of delivery driving have you done?"
  type: number
  weight: 0.25
  scoring: tiered
  # 0-1 => 5pts, 2-3 => 15pts, 4+ => 25pts

- id: license_class
  prompt: "Which driving license do you have? (A, B, C, D, E, none)"
  type: enum
  weight: 0.20
  scoring: { A: 20, B: 20, C: 15, D: 10, E: 10, none: 0 }

- id: available_from
  prompt: "When can you start if selected? (today / this week / this month / next month)"
  type: enum
  weight: 0.10
  scoring: { today: 10, this_week: 10, this_month: 7, next_month: 4 }

- id: references
  prompt: "Can you share one reference (name and phone number) from a previous delivery job?"
  type: free_text
  weight: 0.10
  scoring: presence_only
```

The workflow walks the script one question at a time. The state machine is driven by `conversation_message` pointer and the Application's `screeningState` JSON field.

## Step sequence

1. On Application creation: initialise `screeningState` = `{questionIndex: 0, answers: {}}` and send question 0.
2. On candidate reply (routed from Workflow A): acquire conversation lock, load state, validate the answer with Claude Haiku (free-text interpretation) or a regex (structured types), store in `answers`.
3. If valid, increment index, send next question; else send a gentle clarifier and do not advance.
4. If no reply after 24h: send one reminder. After 72h: mark `status=withdrawn` and release.
5. When all questions answered: compute score, set tier, update Application + Candidate, send a closing message ("Thanks — we have your details. We will be in touch soon."), end.

## Invariants

- One question per outbound message. Never batch.
- Scoring is deterministic per answer mapping. No LLM scoring for structured questions; only for free-text normalisation.
- Never skip a question based on earlier answers without an explicit script rule.
- Candidates who score above `shortlist_threshold` on the job AND whose application is not selected for THIS job retain `reEngagementEligible=true` — see workflow H.
- The workflow holds the conversation lock only during the reply-processing step, not across the 24h wait.

## Acceptance criteria

- **Full pass:** candidate answers all 6 questions in sequence, final score matches spec calculation, tier set correctly.
- **Mid-stream disconnect:** candidate stops after Q3. The 24h reminder fires once. The 72h auto-withdraw fires once. No message spam.
- **Parallel candidates:** 50 candidates screening in parallel, no cross-talk, all scores computed.
- **Re-interpretation:** candidate replies "I drive okada every day" to own_transport — free-text normaliser resolves to YES.
- **Language:** candidate replies to an English prompt in Pidgin — workflow continues, no silent breakage.

## Monitoring

- `workflow_c_questions_sent_total`
- `workflow_c_completion_rate` — completed / started per day
- `workflow_c_auto_withdrawn_total`
- `workflow_c_interpretation_failures_total`

## Open questions

- Should the shortlist_threshold be per-job, per-category, or global? Default: per-job, with a category default.
