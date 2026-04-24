# Operations — Calibration Window

The first two weeks after launch. Every AI decision is human-reviewed. This is where the system earns trust, not demands it.

## Why

An AI-assisted screening system that goes live trusting itself is a system that makes compound errors quickly. Calibration is the practice of running the system at full capacity but gating every outbound on a human review step, and using those reviews to tune the system before we release the brakes.

## Timeline

- **Week 5, Day 1 onward:** full calibration mode. Every AI score, every re-engagement draft, every scheduling message, reviewed before it reaches a candidate.
- **Week 7, Day 1 (end of 2-week window):** review mode for specific decision types can be relaxed based on measured accuracy.
- **Week 7 onward:** ongoing spot-checks. Not every decision, but sampling.

## Decision types and their review rules

### Always-reviewed during calibration

- Workflow B CV scores (all tiers, not just borderline)
- Workflow C blue-collar screening outcomes
- Workflow H re-engagement messages — reviewed before sending
- Workflow E social posts — always reviewed, calibration window or not
- Any message a candidate might interpret as rejection

### Spot-reviewed during calibration

- Workflow A reply drafts (sampled 10% of the time)
- Workflow D scheduling confirmations (errors would show themselves quickly without review)

### Never reviewed by default

- Structured screening question interpretation (regex-based, not LLM judgement)
- Atomic slot claims (deterministic by construction)

## How the review queue works

1. During calibration, workflows that would normally auto-send instead write the outbound + a rationale + the input context to a `ReviewTask` with `kind=pre_send_review`.
2. The Operations Lead opens Twenty's Review Queue view, reviews, and clicks APPROVE, EDIT-AND-APPROVE, or REJECT.
3. APPROVE → the workflow releases the outbound. EDIT-AND-APPROVE → the edited text goes out instead, and the diff is logged for calibration analysis. REJECT → nothing goes out; the workflow logs the reject reason.
4. Every review closes in under 15 minutes during business hours, or the system pings the Operations Lead.

## What we measure during calibration

Calibration generates data. We use it to answer:

- **Agreement rate:** of the AI's decisions, what percentage did the Operations Lead approve unedited?
- **Edit distance:** when they edited, how much? Small tweaks suggest good calibration; rewrites suggest the prompt is off.
- **Systematic biases:** are there categories where the AI consistently over-scores or under-scores?
- **Failure modes:** what does the AI get wrong in ways the Operations Lead catches?

These feed into weekly calibration reports, built into Workflow F during the window.

## Graduation criteria

To graduate out of full calibration at the end of week 7:

- Agreement rate ≥ 80% across the last 7 days.
- No systematic category-level bias > 10 points.
- Zero "harmful" outputs in the last 14 days (where "harmful" = would have violated a firm rule, would have said something we'd be embarrassed by, or revealed data we should not reveal).
- Operations Lead is comfortable graduating, in their own judgement.

If any of these fails, we extend calibration by another week. There is no rush.

## After graduation

- Shift from pre-send review to post-send audit.
- Sample 10 decisions per week per workflow. Review them in a 30-minute weekly calibration session.
- Quarterly, run a "calibration drill" — take a batch of decisions, ask the AI to re-score, compare to human ground truth. If agreement drops by >5 percentage points, tighten prompts or add rules.

## Known failure modes to watch for

From the research round (and general experience with LLM-in-the-loop systems):

- **Over-politeness masking.** The AI softens bad news so aggressively that a candidate doesn't realise they were declined. Watch for it in Workflow B rejection drafts. Countermeasure: the system prompt explicitly allows polite-but-clear rejection.
- **False precision.** The AI gives confident scores for CVs it actually has weak signal on (e.g. a one-page CV for a senior role). Countermeasure: a "confidence" field in the rubric output; low-confidence scores route to human review even outside calibration.
- **Drift from the firm's voice.** Over weeks, the AI starts sounding like generic ChatGPT instead of the firm. Countermeasure: quarterly re-grounding sessions where the Operations Lead reviews 20 outbound messages and updates the system prompt with tonal corrections.
- **Prompt-injection from candidates.** Addressed in `claude-api.md`. Still watch for it in calibration.
