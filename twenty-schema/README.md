# Twenty Schema — as code

Custom objects and field definitions for Twenty CRM, expressed as TypeScript.

## Why this exists

Twenty supports custom objects and fields via its UI. But UI-only changes are:

- Not reviewable in code review.
- Not idempotent across environments (local, staging, production).
- Not version-controlled.

By defining the schema as code here, we get diff-able history, can replay the schema in a fresh environment, and can review changes like any other change.

## Layout

```
twenty-schema/
└── objects/
    ├── candidate.ts
    ├── job.ts
    ├── application.ts
    ├── interview.ts
    ├── skill-tag.ts
    ├── candidate-skill-tag.ts
    ├── holiday.ts
    ├── review-task.ts
    ├── social-post.ts
    └── workflow-error.ts
```

Each file exports a definition compatible with Twenty's customisation API. Exact form depends on the Twenty version we pin; see `docs/00-foundations/infrastructure.md` for the pin.

## Applying

```
./scripts/apply-twenty-schema.sh
```

Reads each object definition, uses the Twenty GraphQL/admin API to ensure the object and its fields exist, creating or updating as needed. The script is idempotent — run it as often as you like.

## Rules

See `.claude/rules/database-migrations.md` for the general principles — they apply here too, just with the Twenty API as the apply mechanism instead of psql.

Additionally:

- Never delete a custom field via script. Archive it (`isActive=false`) instead. Deletions go through a review + manual step.
- Never rename a field via script — it's equivalent to delete + create. Same rule.
- Field name additions must be reflected in `docs/01-data-model/twenty-crm-schema.md` in the same commit.
