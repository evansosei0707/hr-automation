# n8n Workflows — as code

This directory holds version-controlled n8n workflow JSONs. Workflows live here, not in the n8n database, as the source of truth.

## Directory layout

```
n8n-workflows/
├── communications/      Workflow A
├── candidates/          Workflows B + C
├── scheduling/          Workflow D
├── social/              Workflow E (FB, IG, X, Telegram — one file each)
├── reporting/           Workflow F
├── orchestration/       Workflow G
└── job-alerts/          Workflow H
```

Each file is named `<letter><number>-<slug>.json`, e.g. `a1-whatsapp-inbound.json`.

## Export from n8n → here

1. In the n8n UI, open the workflow.
2. `Menu → Download` — this exports without credentials if done via the standard export.
3. Save the file to the appropriate subfolder here.
4. Run the validator:
   ```
   ./scripts/validate-n8n-workflow.sh n8n-workflows/path/to/file.json
   ```
5. If valid, commit.

## Import from here → n8n

1. In the n8n UI, `Menu → Import from File`.
2. Select the JSON.
3. **Re-link credentials.** Credentials are NOT in the JSON (see `.claude/rules/n8n-workflows.md`). Every credential-using node will need to be pointed at the right credential in n8n's credential store after import.
4. Activate the workflow.

## Credentials — never committed

- API keys, OAuth tokens, webhook secrets → stored in n8n's credential store, encrypted at rest with `N8N_ENCRYPTION_KEY`.
- Credentials are backed up separately (not here) — typically exported by an admin periodically and stored in the password manager.
- The validator rejects any JSON that contains a non-empty credential value.

## Testing a workflow locally

1. Import as above into your local n8n (http://localhost:5678).
2. Re-link credentials (local/test ones, not production).
3. Use the workflow's webhook URL or Manual Trigger to exercise it.
4. Check `bookings-db.workflow_errors` for any errors.
