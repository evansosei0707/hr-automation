# Rule — when touching WhatsApp templates

Load this rule when drafting or modifying message templates that go through Meta Business Manager for approval.

## Principles

1. **Utility, not marketing.** Our templates reference specific prior interactions, confirmations, reminders, service events. They are NOT promotional. A template classified as Marketing costs 3–4× more and erodes the candidate relationship.

2. **Plain Ghanaian English** (with Pidgin phrasing where natural). Not corporate HR-speak. Not US-style casual.

3. **Variables are strictly typed.**
   - `{{1}}` — candidate first name (always).
   - `{{2}}`, `{{3}}` — role-specific, documented per template.
   - Never more than 4 variables. Meta scrutinises high-variable templates more heavily.

4. **No links to web forms.** WhatsApp is the product. If the template needs a "reply YES" call to action, state it plainly.

5. **No emojis in body.** Safe in header or footer if needed. Meta rejects emoji-heavy templates sometimes.

6. **No asking for sensitive data in a template.** No "please send your ID number", no "confirm your bank account." Those go in in-session free-form messages where consent and context exist.

7. **Every template has a purpose comment** in `reference/whatsapp-templates/<name>.md` describing when it fires, who triggers it, what the variables mean, and the exact Meta approval state.

## The approval process

1. Draft the template in `reference/whatsapp-templates/<name>.md` with purpose, category, body, variables.
2. Submit via Meta Business Manager (manual step — no API automation for this in v1).
3. Wait for approval (typically under 1 hour; up to 48h).
4. On APPROVED: update the doc status; the template is now usable.
5. On REJECTED: revise. Meta's rejection reason often points to specific language to change.

## Template categories we use

- `consent_request` — first-touch consent ask. Utility.
- `interview_reminder_24h` / `interview_reminder_2h` — scheduled reminders. Utility.
- `re_engagement_v1` — Workflow H re-engagement. Utility (references the candidate's prior application).
- `still_interested_10d` — 10-day check-in for shortlisted inactive candidates. Utility.
- `data_access_delivery` — response to `DATA` request. Utility.

## What we never template

- Announcements of new jobs in general. Those go on social media, not in unsolicited WhatsApp.
- Marketing "hey we are hiring!" blasts. Violates candidate trust and Meta policy.

## Cost sanity check

At ~$0.014 per utility message in Ghana:
- 500 templates/month → ~$7/month
- 2000 templates/month → ~$28/month

Workflow G tracks template send volume and alerts if monthly pace projects above $30.
