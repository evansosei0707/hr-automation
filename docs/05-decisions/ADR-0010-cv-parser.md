# ADR-0010: CV parser for Workflow B — n8n "Extract from File" + Claude Sonnet for facts

**Status:** Accepted
**Date:** 2026-05-01
**Deciders:** HRA Project Lead

## Context

Workflow B (white-collar candidate screening, `docs/02-workflows/b-white-collar.md`) needs to turn a candidate's submitted CV into structured facts (years of experience, current role, key skills, education) and score it against a job-specific rubric. The spec separates two concerns:

- **Step 1 — parser skill:** PDF/DOCX → plain text + basic structure (sections, bullets). The spec explicitly says "via a dedicated parser skill."
- **Steps 2 + 4 — Claude Sonnet:** semantic fact extraction (step 2) and scoring against rubric (step 4). These are language-model concerns, not document-parsing concerns.

The spec is also explicit that **scanned-image CVs without OCR produce a `ReviewTask` with `kind=parse_failure`, NOT a zero-score**. This means the parser does NOT need to ship OCR for v1 — image-only CVs follow the existing failure path.

This ADR resolves OQ-6 from `docs/02-workflows/b-white-collar-design-v1.md` by choosing the parser implementation for v1.

## Decision

For step 1 (PDF/DOCX → text), use **n8n's built-in "Extract from File" node** in-process. No new infrastructure, no external dependency, no candidate data leaves Ghana.

For steps 2 + 4 (fact extraction + scoring), use **Claude Sonnet** via the existing `Subflow — Claude Call` (already live in production from Workflow A).

Image-only CVs and parse failures route to a `ReviewTask` with `kind=parse_failure` per the spec — the existing Workflow A calibration-gate ReviewTask pattern applies.

## Options considered

### Option A — n8n "Extract from File" + Claude Sonnet (chosen)

n8n has a built-in node that reads PDF, DOCX, XLSX, and CSV from a binary input and emits text. It runs in-process inside the n8n container, no extra service. After extraction, the existing `Subflow — Claude Call` does fact extraction (one Sonnet call) and scoring (a second Sonnet call), as the design note specifies.

- **Cost:** ~$0.003–$0.015 per CV (Claude Sonnet on extracted text; parser itself is free)
- **Latency:** 3–8s per CV (Claude calls dominate)
- **DPA stance:** clean — all data stays inside the VPS in Ghana
- **Failure mode:** images / corrupted files / unsupported formats → `parse_failure` ReviewTask (matches spec)

### Option B — Python microservice with pdfplumber / python-docx / pytesseract

A separate FastAPI/Flask container with `pdfplumber`, `python-docx`, optional `pytesseract` for OCR. More robust extraction (e.g. tables, columns) and adds OCR for image CVs.

- **Cost:** roughly the same per-CV cost (parser is local; Claude still does extraction)
- **Latency:** 5–10s per CV (OCR adds 2–5s when invoked)
- **DPA stance:** clean — local
- **Adds:** one Docker service, a new health check, more lines in `docker-compose.yml`, build pipeline complexity (Python image with `tesseract-ocr` system dependency is large)
- **Why not v1:** YAGNI. The spec routes image CVs to ReviewTask anyway. Until we have evidence that the n8n Extract from File node fails on a meaningful share of real submissions, the extra service is unjustified.

### Option C — SaaS CV-parsing API (Affinda / Sovren / HireAbility / RChilli)

Purpose-built parsers that return structured JSON directly (skills, employers, dates).

- **Cost:** $0.10–$0.50 per parse — 10–50× more expensive than Option A's Claude tail
- **Latency:** 1–3s
- **DPA stance:** **blocker.** Candidate CV data leaves Ghana to a foreign vendor. CLAUDE.md establishes Ghana DPA as a project invariant; this option violates it without explicit per-candidate consent, and even with consent the friction is unacceptable for v1.
- **Why not:** rejected on DPA grounds. Re-evaluation would require an explicit consent flow + a vendor that contractually keeps data within ECOWAS or has a Ghana DPA-compliant DPA. Not on the v1 roadmap.

## Consequences

**Positive:**

- No new container, no new env vars, no new credentials. Ships with the existing Workflow A footprint.
- All candidate CV bytes stay on the firm's VPS in Ghana — DPA-clean.
- Reuses `Subflow — Claude Call` (live, AI-budget-gated, cost-logged via `ai_call_log`). Step 2 + Step 4 inherit budget gating, retry config, and cost telemetry without new code.
- The `parse_failure` ReviewTask path is already in spec — no new failure handling to design.

**Negative / trade-offs accepted:**

- **No OCR in v1.** Scanned-image CVs → `parse_failure` ReviewTask → human review. Acceptable per the spec ("scanned image without OCR produces a `ReviewTask`, not a 0 score"). If real candidate traffic shows >20% image-only CVs, this becomes a Tier 2 trigger to revisit Option B.
- **Table-heavy / multi-column CVs may extract poorly.** n8n's Extract from File node uses generic PDF text extraction, not layout-aware parsing. Most professional Ghanaian CVs are linear (single-column, header → experience → education → skills); this is an acceptable risk for v1 and a known calibration-window watch item.
- **No structured-output guarantees from the parser.** We get plain text and rely on Claude Sonnet to find the structure. The spec already calls for this in step 2; this is not a new burden.

**Follow-up work (Tier 2):**

- Track parse-failure rate during the 2-week calibration window. If >20% of real CVs hit `parse_failure`, open a Tier 2 item to evaluate Option B (Python microservice with `pdfplumber` + `pytesseract`).
- Track Claude Sonnet extraction cost per CV. If real-world cost per CV exceeds $0.02 routinely, evaluate switching the extraction step to Haiku (and keeping Sonnet only for scoring).
- During the calibration window, sample 10–20 real CVs and human-rate the extraction quality. Use as the v1 baseline before any future-step decision.

## Triggers that would force a re-decision

- **Image-only CV rate > 20%** of real submissions — would justify the Python + OCR microservice (Option B).
- **Per-CV Claude cost > $0.02 average** — would justify a Haiku migration for the extraction step or a non-AI structured parser.
- **Spec change requiring layout-aware parsing** (e.g. table-of-skills extraction, multi-column resumes from international applicants) — would justify Option B's `pdfplumber` for layout-preserving extraction.
- **Operator request for SaaS-grade structured fields** (e.g. normalized employer names linked to a company database) — would re-open the DPA conversation around Option C, not change the decision unilaterally.

## References

- `docs/02-workflows/b-white-collar.md` — Workflow B spec; lines 34, 50, 56 establish the parser scope and the `parse_failure` ReviewTask path
- `docs/02-workflows/b-white-collar-design-v1.md` — design note that this ADR resolves (OQ-6)
- `docs/03-integrations/twenty-application-schema.md` — Application field shape used by step 5 (status update after scoring)
- ADR-0006 — Groq Whisper pivot (closest format/tone template for this ADR; same Ghana-context build/buy decision shape)
- `CLAUDE.md` — Ghana-DPA invariant; cost-sensitivity context
- n8n "Extract from File" node documentation — built-in, version-pinned with the n8n container; no separate version policy needed
