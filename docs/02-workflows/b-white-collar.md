# Workflow B — White-Collar Screening

AI-assisted CV review and scoring for office / professional roles. Triggered when a candidate submits a CV against a `JobPosting` with `collarType=white`.

## Purpose

For roles like accountant, frontend developer, HR assistant, finance manager — where the candidate pool is smaller and CVs carry real signal — we do an AI-assisted first pass, produce a score with rationale, and populate the Application so the human can decide who to surface to the client.

The system never contacts the client directly with a shortlist. The Operations Lead reviews and approves.

## Triggers

- New `Application` row in Twenty with `status=received` and the linked `JobPosting.collarType=white`
- Scheduled re-score when a JobPosting's requirements are materially edited (architect must approve this change path)

## Inputs

- `applicationId`
- Linked `candidateId`, `jobPostingId`
- Candidate's CV (attached to the Candidate record as a Document)
- JobPosting's requirements and description

## Outputs

- `Application.score` (0–100)
- `Application.scoreBreakdown` (JSON, per-criterion)
- `Application.status` transitions to `screened`
- `Candidate.strengthTier` updated
- `CandidateSkillTag` rows created or updated based on the CV
- WhatsApp message to candidate acknowledging receipt and next steps

## Step sequence (high level)

1. Parse CV. PDF/DOCX via a dedicated parser skill; extract plain text + basic structure (sections, bullets).
2. Ask Claude Sonnet to extract structured facts into JSON (years of experience, current role, key skills, education). Store to `candidate_facts` and mirror updates to Twenty.
3. Build a rubric from the JobPosting. Rubric items come from the JobPosting's `requirements` field, each weighted.
4. Ask Claude Sonnet to score the CV against the rubric. Strict JSON output with per-criterion score, evidence quote, and a bounded rationale.
5. Compute the weighted total.
6. Map score to `strengthTier`: >=80 → `top20`, 60–79 → `solid`, 40–59 → `developing`, <40 → `not_a_fit`.
7. Update Application + Candidate in Twenty via GraphQL.
8. Attach inferred skill tags via `CandidateSkillTag` (source = `cv_parse`).
9. Send candidate a WhatsApp acknowledgement. Text varies by tier — acknowledge receipt, not the score.
10. If `strengthTier=top20` or `solid`, create a `ReviewTask` for the Operations Lead with `kind=score_review`. During the calibration window (first 2 weeks), create the task for ALL tiers.

## Invariants

- Score rationales must cite evidence from the CV. No unsupported judgements.
- The candidate never sees the numeric score. Ever.
- During calibration window, every score is human-reviewed before the status advances past `screened`.
- CV parsing failures do not silently default to zero. They raise a `ReviewTask` with `kind=parse_failure`.
- Rubric weights must sum to exactly 1.0 or the workflow refuses to run.

## Acceptance criteria

- **Happy path:** a plain-English CV for a mid-level frontend developer yields a score within 10 points of a human-generated rubric score, with evidence citations.
- **Malformed CV:** a CV that is actually a scanned image without OCR produces a `ReviewTask`, not a 0 score.
- **Rubric with zero weights:** workflow refuses to run and logs a configuration error.
- **Calibration mode:** every completed screening produces a review task, and the status does not advance without human approval.
- **Idempotency:** re-running on the same Application produces the same score (modulo LLM nondeterminism — allow ±5 points tolerance) and does not duplicate `CandidateSkillTag` rows.

## Monitoring

- `workflow_b_screened_total` counter, labelled by `strengthTier`
- `workflow_b_claude_cost_total` gauge (per screening, aggregated weekly)
- `workflow_b_parse_failures_total` counter

## Open questions

- Do we want a second-opinion pass (same prompt, second call, compare) for edge cases around the tier boundaries? Default: no, but keep the knob.
