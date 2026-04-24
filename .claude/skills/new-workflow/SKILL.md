---
name: new-workflow
description: Kick off building a new n8n workflow from a spec. Produces a plan, dispatches architect if needed, then workflow-builder, then tester, then code-reviewer.
---

# /new-workflow

## When to use

A new spec has appeared in `docs/02-workflows/` (or an existing one has been materially revised) and we are ready to implement it.

## Steps

1. **Load context.**
   - Read the spec file the user names (or ask which one).
   - Read `CLAUDE.md` (already in context).
   - Read `docs/INDEX.md`.
   - Read linked docs: the spec's own references to `01-data-model/`, `03-integrations/`.

2. **Open a plan.**
   - Copy `plans/TEMPLATE.md` to `plans/YYYYMMDD-<workflow-letter>-<slug>.md`.
   - Fill in: spec link, acceptance criteria (copy verbatim from the spec), preconditions (templates approved? credentials set? schema in place?), the phases you'll walk through, and the DONE criteria.
   - Set this as `plans/active-plan.md` by updating its pointer.

3. **Architect review (if warranted).**
   - Dispatch the `architect` subagent IF the workflow involves a new external vendor, a new invariant, or a trade-off the spec does not settle.
   - Wait for the ADR (Proposed) before implementing.

4. **Schema changes (if any).**
   - If the workflow requires new fields in Twenty or a new column in the bookings DB, dispatch the `schema-designer` subagent first.
   - Confirm the migration applied in the local stack before proceeding.

5. **Build.**
   - Dispatch the `workflow-builder` subagent with the spec path as input.
   - Wait for it to return with a workflow JSON filename and an implementation note.

6. **Test.**
   - Dispatch the `tester` subagent.
   - If FAIL, either fix (via another workflow-builder pass) or escalate to the user.

7. **Review.**
   - Dispatch the `code-reviewer` subagent.
   - If CHANGES_REQUIRED, fix, then re-dispatch tester + reviewer.

8. **Close out.**
   - Update `.claude/memory/status.md` with what's done.
   - Archive the plan to `plans/YYYYMMDD-<slug>-DONE.md`.
   - Clear `plans/active-plan.md` (or set to the next plan).

## What NOT to do

- Do not build the workflow directly in this skill. Delegation is the point.
- Do not skip tester or reviewer "because it's a simple workflow."
- Do not commit n8n JSON with any credential values. All credentials come from env / n8n's credential store.
