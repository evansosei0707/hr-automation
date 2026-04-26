#!/usr/bin/env python3
"""
audit-twenty-schema.py

Local validation of `twenty-schema/migrations/V*.json` files against Twenty
v2.1.0's format rules. Exists because we kept discovering Twenty's enforcement
rules through tester round-trips — each round costs ~15 minutes. This script
is the local mirror.

Rules enforced (all derived from Twenty v2.1.0 source — paths cited per rule):

1. Object/field names are NOT in Twenty's reserved-keywords list.
   Source: packages/twenty-shared/src/metadata/constants/
           reserved-metadata-name-keywords.constant.ts

2. SELECT / MULTI_SELECT option `value` strings match `^[A-Z][A-Z0-9_]*$`.
   Source: discovered via apply on 2026-04-26; Twenty error message:
           `Value must be in UPPER_CASE and follow snake_case`

3. `defaultValue` format per type:
   - TEXT, SELECT, MULTI_SELECT, RICH_TEXT  → SQL-literal single-quoted string
                                              (`"'PENDING'"`, NOT `"\\"PENDING\\""`)
   - BOOLEAN                                → bare JSON boolean
   - NUMBER, NUMERIC                        → bare JSON number
   - DATE, DATE_TIME                        → single-quoted ISO string
                                              OR function form `{type:"now"}`
   Source: packages/twenty-server/src/engine/workspace-manager/
           workspace-migration/workspace-migration-builder/utils/
           serialize-default-value.util.ts:66-70

Usage:
  ./scripts/audit-twenty-schema.py                       # audit all V*.json
  ./scripts/audit-twenty-schema.py path/to/V001.json     # audit specific file
"""

import json
import re
import sys
from pathlib import Path

# Reserved keywords — kept in sync manually from Twenty source.
# Mirror of: ~/Sandbox/twenty/packages/twenty-shared/src/metadata/
#            constants/reserved-metadata-name-keywords.constant.ts
RESERVED_NAMES = {
    "approvedAccessDomain", "approvedAccessDomains",
    "appToken", "appTokens",
    "billingCustomer", "billingCustomers",
    "billingEntitlement", "billingEntitlements",
    "billingMeter", "billingMeters",
    "billingProduct", "billingProducts",
    "billingSubscription", "billingSubscriptions",
    "billingSubscriptionItem", "billingSubscriptionItems",
    "featureFlag", "featureFlags",
    "job", "jobs",
    "keyValuePair", "keyValuePairs",
    "pageLayout", "pageLayouts",
    "pageLayoutTab", "pageLayoutTabs",
    "pageLayoutWidget", "pageLayoutWidgets",
    "postgresCredential", "postgresCredentials",
    "twoFactorMethod", "twoFactorMethods",
    "user", "users",
    "userWorkspace", "userWorkspaces",
    "workspace", "workspaces",
    "role", "roles",
    "userWorkspaceRole", "userWorkspaceRoles",
    "plan", "plans",
    "event", "events",
    "field", "fields",
    "link", "links",
    "currency", "currencies",
    "fullNames",
    "address", "addresses",
    "type", "types",
    "object", "objects",
    "index",
    "relation", "relations",
    "aggregate",
    "search", "searches",
}

OPTION_VALUE_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")

# Field types whose `defaultValue`, when set as a string, must be a SQL-literal
# single-quoted string (e.g. "'PENDING'"). Source:
#   ~/Sandbox/twenty/packages/twenty-shared/src/types/FieldMetadataDefaultValue.ts
#   FieldMetadataDefaultValueMapping members typed `string | null`:
#     [TEXT]=string|null, [SELECT]=string|null, [NUMERIC]=string|null,
#     [RATING]=string|null
#   Plus RICH_TEXT — typed as a composite object {blocknote, markdown} but
#   if a string default is ever set on it, the same single-quote rule applies
#   per serialize-default-value.util.ts:66-70 (the check is on `typeof string`,
#   not field type).
#   MULTI_SELECT is INTENTIONALLY EXCLUDED — its default is `string[] | null`
#   (an array), not a single string. Audit doesn't validate array defaults.
STRING_DEFAULT_TYPES = {"TEXT", "SELECT", "RICH_TEXT", "NUMERIC", "RATING"}

# NUMBER is `number | null` (bare numeric); NUMERIC is string-typed (above).
NUMERIC_DEFAULT_TYPES = {"NUMBER"}
DATE_DEFAULT_TYPES = {"DATE", "DATE_TIME"}


def audit_create_object(inp, op_idx):
    findings = []
    for key in ("nameSingular", "namePlural"):
        v = inp.get(key)
        if v in RESERVED_NAMES:
            findings.append(
                f"op {op_idx} createObject: {key}={v!r} is in Twenty's "
                "RESERVED_METADATA_NAME_KEYWORDS — pick a different name"
            )
    return findings


def audit_create_field(inp, op_idx):
    findings = []
    obj_name = inp.get("objectName", "?")
    field_name = inp.get("name", "?")
    ftype = inp.get("type")

    if field_name in RESERVED_NAMES:
        findings.append(
            f"op {op_idx} createField {obj_name}.{field_name}: "
            f"name {field_name!r} is in Twenty's RESERVED_METADATA_NAME_KEYWORDS"
        )

    # SELECT / MULTI_SELECT option values
    if ftype in ("SELECT", "MULTI_SELECT"):
        for opt in inp.get("options", []):
            v = opt.get("value", "")
            if not OPTION_VALUE_RE.match(v):
                findings.append(
                    f"op {op_idx} {obj_name}.{field_name}: option value "
                    f"{v!r} does not match ^[A-Z][A-Z0-9_]*$ "
                    f"(SELECT values must be UPPER_SNAKE_CASE)"
                )

    # defaultValue per-type format
    if "defaultValue" in inp:
        dv = inp["defaultValue"]
        loc = f"op {op_idx} {obj_name}.{field_name}"

        if ftype in STRING_DEFAULT_TYPES:
            if not (isinstance(dv, str) and dv.startswith("'") and dv.endswith("'")):
                findings.append(
                    f"{loc}: defaultValue {dv!r} for {ftype} must be SQL-literal "
                    "single-quoted (e.g. \"'PENDING'\"); see "
                    "serialize-default-value.util.ts:66-70"
                )
        elif ftype == "BOOLEAN":
            if not isinstance(dv, bool):
                findings.append(
                    f"{loc}: defaultValue {dv!r} for BOOLEAN must be a bare "
                    "JSON boolean (true/false), not a string"
                )
        elif ftype in NUMERIC_DEFAULT_TYPES:
            if not isinstance(dv, (int, float)) or isinstance(dv, bool):
                findings.append(
                    f"{loc}: defaultValue {dv!r} for {ftype} must be a bare "
                    "JSON number"
                )
        elif ftype in DATE_DEFAULT_TYPES:
            ok = False
            if isinstance(dv, str) and dv.startswith("'") and dv.endswith("'"):
                ok = True
            elif isinstance(dv, dict) and "type" in dv:
                ok = True
            if not ok:
                findings.append(
                    f"{loc}: defaultValue {dv!r} for {ftype} must be a "
                    "single-quoted ISO string OR a function-form dict "
                    '(e.g. {"type":"now"})'
                )
        # Other types (CURRENCY, PHONES, EMAILS, ADDRESS, LINKS, ARRAY,
        # RAW_JSON, etc.) — composite defaults are rare and not enforced here.
        # If we ever set defaults on those, add cases.

    return findings


def audit_file(fpath):
    findings = []
    try:
        data = json.loads(fpath.read_text())
    except json.JSONDecodeError as e:
        return [f"{fpath.name}: NOT VALID JSON ({e})"]
    except FileNotFoundError:
        return [f"{fpath}: file not found"]

    ops = data.get("operations", [])
    for i, op in enumerate(ops):
        kind = op.get("kind")
        inp = op.get("input", {})
        if kind == "createObject":
            for f in audit_create_object(inp, i):
                findings.append(f"{fpath.name}: {f}")
        elif kind == "createField":
            for f in audit_create_field(inp, i):
                findings.append(f"{fpath.name}: {f}")
    return findings


def main():
    args = sys.argv[1:]
    if args:
        files = [Path(a) for a in args]
    else:
        repo = Path(__file__).resolve().parent.parent
        files = sorted((repo / "twenty-schema" / "migrations").glob("V*.json"))

    if not files:
        print("audit-twenty-schema: no migration files to audit.")
        return 0

    all_findings = []
    for f in files:
        all_findings.extend(audit_file(f))

    if all_findings:
        print(f"audit-twenty-schema: {len(all_findings)} issue(s) across "
              f"{len(files)} file(s):")
        for finding in all_findings:
            print(f"  - {finding}")
        return 1

    print(f"audit-twenty-schema: clean across {len(files)} file(s) "
          f"({sum(len(json.loads(f.read_text()).get('operations', [])) for f in files)} ops total).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
