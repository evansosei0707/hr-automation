#!/usr/bin/env bash
# test-bookings-concurrency.sh
# Verifies BOTH safety legs of the bookings DB design (per
# docs/01-data-model/bookings-db.md):
#
#   Test 1 — OFFER race (the partial unique index `uq_slot_no_double_claim`)
#     Two parallel INSERTs of slot rows with the SAME (interviewer_id,
#     starts_at) and status='offered'. Expected: one INSERT succeeds,
#     one fails with SQLSTATE 23505 (unique_violation). Final state:
#     exactly one slot row exists for that (interviewer, starts_at) pair.
#
#   Test 2 — CLAIM race (the WHERE-clause guard)
#     Seed one offered slot. Two parallel UPDATEs from status='offered'
#     to status='claimed'. Expected: exactly one rowcount=1 (winner),
#     one rowcount=0 (loser) with NO error of any kind — no
#     serialization-failure, no constraint violation, no deadlock-aborted
#     txn. The whole point of the WHERE-guard is that real workflow
#     code does `if rowcount == 0: offer_next_slot()` without try/except.
#
# Each test runs 5 rounds to rule out flake. Each round uses a unique
# starts_at to avoid cross-round contamination.
#
# Cleanup runs at start AND end (via `trap '...' EXIT`), so teardown
# happens even on crash, Ctrl+C, or timeout. workflow_errors is NOT
# touched (historical evidence of any apply-script issues).
#
# Prerequisites:
#   - docker on PATH (psql via docker exec)
#   - infrastructure/.env with bookings DB vars
#   - hr-bookings-db container running and healthy
#   - V001__create_bookings_core.sql applied (slot, interviewer,
#     booking_event_log tables; uq_slot_no_double_claim index)
#
# Usage:
#   ./scripts/test-bookings-concurrency.sh           # 5 rounds each test (default)
#   ./scripts/test-bookings-concurrency.sh -n 3      # 3 rounds each test
#   ./scripts/test-bookings-concurrency.sh -v        # verbose: show SQL output per round
set -euo pipefail

# ─────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────
ROUNDS=5
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) ROUNDS="$2"; shift 2 ;;
    -v) VERBOSE=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ─────────────────────────────────────────────
# Paths + helpers
# ─────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/infrastructure/.env"

# Progress + status helpers ALL write to stderr.
# Stdout is reserved as the function-return channel — test_*_round echoes the
# winner_label ("A" or "B") on stdout so the main loop can capture it via
# command substitution. If log/pass also wrote to stdout, the capture would
# include their text and break the win counters.
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
err()  { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { err "$*"; exit 1; }
pass() { printf '[%s] [PASS] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail_msg() { printf '[%s] [FAIL] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
# shellcheck source=/dev/null
source "$ENV_FILE"

for var in BOOKINGS_DB_USER BOOKINGS_DB_PASSWORD BOOKINGS_DB_NAME; do
  [ -n "${!var:-}" ] || die "Required env var '$var' missing in .env"
done
for dep in docker; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done

BOOKINGS_DB_CONTAINER="${BOOKINGS_DB_CONTAINER:-hr-bookings-db}"

psql_exec() {
  docker exec -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A -q -c "$1"
}

psql_exec_file() {
  # -t -A : tuples-only, unaligned — output is the bare value(s), no headers, no (N rows) footer.
  # Errors (with VERBOSITY=verbose set in the SQL) still go to stderr → 2>&1 in callers.
  docker exec -i -e PGPASSWORD="$BOOKINGS_DB_PASSWORD" "$BOOKINGS_DB_CONTAINER" \
    psql -U "$BOOKINGS_DB_USER" -d "$BOOKINGS_DB_NAME" -t -A
}

# ─────────────────────────────────────────────
# Test data conventions + cleanup
# ─────────────────────────────────────────────
TEST_INTERVIEWER_TUID="test_concurrency_interviewer"
TEST_APPLICATION_ID="app_test_concurrency_1"

cleanup_test_data() {
  # Idempotent. Drops everything keyed off TEST_INTERVIEWER_TUID.
  # Cascade order: event_log → slot → interviewer.
  # workflow_errors is NEVER touched.
  psql_exec "
    DELETE FROM booking_event_log
    WHERE slot_id IN (
      SELECT s.id FROM slot s
      JOIN interviewer i ON s.interviewer_id = i.id
      WHERE i.twenty_user_id = '$TEST_INTERVIEWER_TUID'
    );
    DELETE FROM slot
    WHERE interviewer_id IN (SELECT id FROM interviewer WHERE twenty_user_id = '$TEST_INTERVIEWER_TUID');
    DELETE FROM interviewer WHERE twenty_user_id = '$TEST_INTERVIEWER_TUID';
  " >/dev/null 2>&1 || true
}

# Trap ensures cleanup on every exit path: success, failure, Ctrl+C, deadlock-timeout.
trap cleanup_test_data EXIT

# Pre-test cleanup — start clean even if a prior aborted run left data.
cleanup_test_data
log "Pre-test cleanup done."

# Seed the shared interviewer once. Both tests use the same interviewer with
# different starts_at values per round.
INTERVIEWER_ID=$(psql_exec "
  INSERT INTO interviewer (twenty_user_id, display_name)
  VALUES ('$TEST_INTERVIEWER_TUID', 'Test Concurrency Interviewer')
  RETURNING id;
")
[ -n "$INTERVIEWER_ID" ] || die "Failed to seed test interviewer"
log "Seeded interviewer: $INTERVIEWER_ID"

# ─────────────────────────────────────────────
# OFFER RACE — partial unique index test
#
# Both sessions race to INSERT a slot row with status='offered' for the same
# (interviewer_id, starts_at). Postgres's row-level lock-and-conflict handling
# during INSERT against a unique partial index ensures one wins, one fails
# with SQLSTATE 23505. The loser's psql exits non-zero (ON_ERROR_STOP=1).
# ─────────────────────────────────────────────
test_offer_race_round() {
  local round_n=$1
  local out_a="/tmp/_offer_a_${round_n}.out"
  local out_b="/tmp/_offer_b_${round_n}.out"
  rm -f "$out_a" "$out_b"

  # Each round uses a unique starts_at offset so it doesn't collide with
  # prior rounds' winning rows still in the slot table.
  local offset=$((round_n * 3600))   # +1h, +2h, +3h, ...

  # Compute the starts_at and ends_at as STABLE LITERALS outside the parallel
  # sessions. If we let each session compute NOW() inside its own transaction,
  # they each get slightly different transaction_timestamp() values, which
  # produces different (interviewer_id, starts_at) pairs — and the partial
  # unique index never fires. Stable literals make both INSERTs target the
  # exact same key.
  local starts_at_lit ends_at_lit
  starts_at_lit=$(psql_exec "SELECT (NOW() + INTERVAL '$offset seconds')::text")
  ends_at_lit=$(psql_exec "SELECT (NOW() + INTERVAL '$((offset + 3600)) seconds')::text")

  build_offer_sql() {
    cat <<SQL
\set ON_ERROR_STOP on
\set VERBOSITY verbose
BEGIN;
SELECT pg_sleep(0.4);
INSERT INTO slot (interviewer_id, starts_at, ends_at, status, offered_to_application_id, offered_at, offer_expires_at)
VALUES (
  '$INTERVIEWER_ID',
  '$starts_at_lit'::timestamptz,
  '$ends_at_lit'::timestamptz,
  'offered',
  '$TEST_APPLICATION_ID',
  NOW(),
  NOW() + INTERVAL '1 hour'
)
RETURNING id;
COMMIT;
SQL
  }

  build_offer_sql | psql_exec_file > "$out_a" 2>&1 &
  local pid_a=$!
  build_offer_sql | psql_exec_file > "$out_b" 2>&1 &
  local pid_b=$!

  wait $pid_a; local rc_a=$?
  wait $pid_b; local rc_b=$?

  if [ $VERBOSE -eq 1 ]; then
    log "  --- offer session A output (rc=$rc_a) ---"; cat "$out_a"
    log "  --- offer session B output (rc=$rc_b) ---"; cat "$out_b"
  fi

  # Exactly one rc=0 (winner), one non-zero (loser with 23505).
  local winners=0 losers=0 winner_label= loser_out=
  if [ $rc_a -eq 0 ]; then winners=$((winners+1)); winner_label="A"; else losers=$((losers+1)); loser_out="$out_a"; fi
  if [ $rc_b -eq 0 ]; then winners=$((winners+1)); winner_label="${winner_label:-}B"; else losers=$((losers+1)); loser_out="${loser_out:-$out_b}"; fi

  if [ $winners -ne 1 ] || [ $losers -ne 1 ]; then
    fail_msg "offer round $round_n: expected 1 winner + 1 loser, got winners=$winners losers=$losers (rc_a=$rc_a rc_b=$rc_b)"
    return 1
  fi

  # Loser's output must contain SQLSTATE 23505 (unique_violation), specifically
  # naming our constraint. Anything else (deadlock, generic abort, IO failure)
  # is a different failure mode and not what the test is verifying.
  if ! grep -qE '23505' "$loser_out"; then
    fail_msg "offer round $round_n: loser did not report SQLSTATE 23505"
    err "  --- loser output ---"; cat "$loser_out" >&2
    return 1
  fi
  if ! grep -qE 'uq_slot_no_double_claim' "$loser_out"; then
    fail_msg "offer round $round_n: loser's error did not name 'uq_slot_no_double_claim' constraint"
    err "  --- loser output ---"; cat "$loser_out" >&2
    return 1
  fi

  # Final state: exactly ONE slot row for this exact (interviewer_id, starts_at)
  # pair. With the literal-timestamp fix above, exact-equality is the right
  # check (no need for a window query).
  local slot_count
  slot_count=$(psql_exec "
    SELECT count(*) FROM slot
    WHERE interviewer_id = '$INTERVIEWER_ID'
      AND status = 'offered'
      AND starts_at = '$starts_at_lit'::timestamptz
  ")
  if [ "$slot_count" != "1" ]; then
    fail_msg "offer round $round_n: expected exactly 1 offered slot for (interviewer, starts_at=$starts_at_lit), got $slot_count"
    return 1
  fi

  # No event_log rows for this round (offer race doesn't write to event_log).
  local ev_count
  ev_count=$(psql_exec "
    SELECT count(*) FROM booking_event_log
    WHERE slot_id IN (
      SELECT id FROM slot WHERE interviewer_id = '$INTERVIEWER_ID'
        AND starts_at = '$starts_at_lit'::timestamptz
    )
  ")
  if [ "$ev_count" != "0" ]; then
    fail_msg "offer round $round_n: expected 0 event_log rows for this round's slot, got $ev_count"
    return 1
  fi

  pass "offer round $round_n: winner=$winner_label, loser SQLSTATE 23505 on uq_slot_no_double_claim, 1 slot row, 0 event_log rows"
  echo "$winner_label"
  return 0
}

# ─────────────────────────────────────────────
# CLAIM RACE — WHERE-clause guard test
#
# Seed one offered slot. Two sessions run the spec's UPDATE-claim. The
# winner's UPDATE matches and changes status; the loser's UPDATE WHERE
# no longer matches → rowcount=0 → no event_log INSERT (CTE-driven).
# Both sessions must exit 0 with NO error in output. Sixth assertion
# greps for ERROR / ROLLBACK / serialization / deadlock — any hit FAILS
# the round.
# ─────────────────────────────────────────────
test_claim_race_round() {
  local round_n=$1
  local out_a="/tmp/_claim_a_${round_n}.out"
  local out_b="/tmp/_claim_b_${round_n}.out"
  rm -f "$out_a" "$out_b"

  # Use a starts_at well past the offer-race rounds' window.
  local offset=$(( (100 + round_n) * 3600 ))   # round 1 = +101h, round 2 = +102h, ...

  # Seed one offered slot for this round.
  local slot_id
  slot_id=$(psql_exec "
    INSERT INTO slot (interviewer_id, starts_at, ends_at, status, offered_to_application_id, offered_at, offer_expires_at)
    VALUES (
      '$INTERVIEWER_ID',
      NOW() + INTERVAL '$offset seconds',
      NOW() + INTERVAL '$((offset + 3600)) seconds',
      'offered',
      '$TEST_APPLICATION_ID',
      NOW(),
      NOW() + INTERVAL '1 hour'
    )
    RETURNING id;
  ")
  [ -n "$slot_id" ] || { fail_msg "claim round $round_n: seed failed"; return 1; }

  build_claim_sql() {
    local sess_label=$1
    cat <<SQL
\set ON_ERROR_STOP on
BEGIN;
SELECT pg_sleep(0.4);
WITH upd AS (
  UPDATE slot SET
    status = 'claimed',
    claimed_by_application_id = '$TEST_APPLICATION_ID',
    claimed_at = NOW(),
    updated_at = NOW()
  WHERE id = '$slot_id'
    AND status = 'offered'
    AND offered_to_application_id = '$TEST_APPLICATION_ID'
    AND offer_expires_at > NOW()
  RETURNING id
)
INSERT INTO booking_event_log (slot_id, event_type, actor, payload)
SELECT id, 'slot_claimed', '$sess_label', jsonb_build_object('round', $round_n, 'session', '$sess_label')
FROM upd;
COMMIT;
SELECT CASE WHEN EXISTS (
  SELECT 1 FROM booking_event_log
  WHERE slot_id = '$slot_id' AND actor = '$sess_label'
) THEN 'WON' ELSE 'LOST' END AS outcome;
SQL
  }

  build_claim_sql "claim_a" | psql_exec_file > "$out_a" 2>&1 &
  local pid_a=$!
  build_claim_sql "claim_b" | psql_exec_file > "$out_b" 2>&1 &
  local pid_b=$!

  wait $pid_a; local rc_a=$?
  wait $pid_b; local rc_b=$?

  if [ $VERBOSE -eq 1 ]; then
    log "  --- claim session A output (rc=$rc_a) ---"; cat "$out_a"
    log "  --- claim session B output (rc=$rc_b) ---"; cat "$out_b"
  fi

  # Both sessions MUST exit 0. Any non-zero exit = a real DB error in the
  # session, which is exactly what the WHERE-clause guard is supposed to avoid.
  if [ $rc_a -ne 0 ] || [ $rc_b -ne 0 ]; then
    fail_msg "claim round $round_n: psql session(s) exited non-zero. rc_a=$rc_a rc_b=$rc_b"
    err "  --- session A ---"; cat "$out_a" >&2
    err "  --- session B ---"; cat "$out_b" >&2
    return 1
  fi

  # Sixth assertion (per user direction): grep both outputs for any error
  # indicator. Loser must come back rowcount=0 CLEANLY — not via ROLLBACK,
  # not via serialization/deadlock, not via any ERROR.
  for f in "$out_a" "$out_b"; do
    if grep -qE 'ERROR:|ROLLBACK|serialization|deadlock' "$f"; then
      fail_msg "claim round $round_n: error indicator found in session output: $f"
      err "  --- offending output ---"; cat "$f" >&2
      return 1
    fi
  done

  # Outcomes — exactly one WON, one LOST.
  local outcome_a outcome_b
  outcome_a=$(grep -E '^(WON|LOST)$' "$out_a" | tail -1 || true)
  outcome_b=$(grep -E '^(WON|LOST)$' "$out_b" | tail -1 || true)
  local wins=0 losses=0 winner_label=
  [ "$outcome_a" = "WON" ] && { wins=$((wins+1)); winner_label="A"; }
  [ "$outcome_b" = "WON" ] && { wins=$((wins+1)); winner_label="${winner_label:-}B"; }
  [ "$outcome_a" = "LOST" ] && losses=$((losses+1))
  [ "$outcome_b" = "LOST" ] && losses=$((losses+1))
  if [ "$wins" != "1" ] || [ "$losses" != "1" ]; then
    fail_msg "claim round $round_n: expected 1 WON + 1 LOST, got A=$outcome_a B=$outcome_b"
    return 1
  fi

  # Slot final state.
  local final_status final_claimer
  final_status=$(psql_exec "SELECT status FROM slot WHERE id = '$slot_id'")
  final_claimer=$(psql_exec "SELECT claimed_by_application_id FROM slot WHERE id = '$slot_id'")
  if [ "$final_status" != "claimed" ]; then
    fail_msg "claim round $round_n: slot status expected 'claimed', got '$final_status'"
    return 1
  fi
  if [ "$final_claimer" != "$TEST_APPLICATION_ID" ]; then
    fail_msg "claim round $round_n: claimed_by_application_id expected '$TEST_APPLICATION_ID', got '$final_claimer'"
    return 1
  fi

  # Event log: exactly 1 row for this slot, attributed to the winning session.
  local event_count event_actor expected_actor
  event_count=$(psql_exec "SELECT count(*) FROM booking_event_log WHERE slot_id = '$slot_id'")
  if [ "$event_count" != "1" ]; then
    fail_msg "claim round $round_n: booking_event_log row count expected 1, got $event_count"
    return 1
  fi
  event_actor=$(psql_exec "SELECT actor FROM booking_event_log WHERE slot_id = '$slot_id'")
  if [ "$outcome_a" = "WON" ]; then expected_actor="claim_a"; else expected_actor="claim_b"; fi
  if [ "$event_actor" != "$expected_actor" ]; then
    fail_msg "claim round $round_n: event_log actor expected '$expected_actor', got '$event_actor'"
    return 1
  fi

  pass "claim round $round_n: A=$outcome_a B=$outcome_b; slot.status=claimed; event_log rows=1 (actor=$event_actor); no DB errors"
  echo "$winner_label"
  return 0
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
log ""
log "════════════════════════════════════════════"
log " test-bookings-concurrency.sh"
log " Container: $BOOKINGS_DB_CONTAINER  DB: $BOOKINGS_DB_NAME  Rounds per test: $ROUNDS"
log "════════════════════════════════════════════"

offer_failures=0
offer_a_wins=0
offer_b_wins=0
log ""
log "▶ TEST 1: OFFER RACE (partial unique index uq_slot_no_double_claim)"
for r in $(seq 1 "$ROUNDS"); do
  log "─── offer round $r ───"
  if winner=$(test_offer_race_round "$r"); then
    [ "$winner" = "A" ] && offer_a_wins=$((offer_a_wins+1))
    [ "$winner" = "B" ] && offer_b_wins=$((offer_b_wins+1))
  else
    offer_failures=$((offer_failures+1))
  fi
done

claim_failures=0
claim_a_wins=0
claim_b_wins=0
log ""
log "▶ TEST 2: CLAIM RACE (WHERE-clause guard)"
for r in $(seq 1 "$ROUNDS"); do
  log "─── claim round $r ───"
  if winner=$(test_claim_race_round "$r"); then
    [ "$winner" = "A" ] && claim_a_wins=$((claim_a_wins+1))
    [ "$winner" = "B" ] && claim_b_wins=$((claim_b_wins+1))
  else
    claim_failures=$((claim_failures+1))
  fi
done

# Summary
echo
echo "════════════════════════════════════════════"
echo " Summary"
echo "════════════════════════════════════════════"
printf " Offer race: %d/%d PASS  (A wins: %d / B wins: %d)\n" \
  "$((ROUNDS - offer_failures))" "$ROUNDS" "$offer_a_wins" "$offer_b_wins"
printf " Claim race: %d/%d PASS  (A wins: %d / B wins: %d)\n" \
  "$((ROUNDS - claim_failures))" "$ROUNDS" "$claim_a_wins" "$claim_b_wins"
echo "════════════════════════════════════════════"

total_failures=$((offer_failures + claim_failures))
if [ "$total_failures" -ne 0 ]; then
  err "$total_failures round(s) FAILED. Atomic-claim invariant did not hold."
  exit 1
fi

log ""
log "All $((ROUNDS * 2)) rounds passed."
log "  - Offer path: partial unique index uq_slot_no_double_claim rejects"
log "    duplicate offered/claimed rows for (interviewer_id, starts_at) with"
log "    SQLSTATE 23505. No partial state."
log "  - Claim path: WHERE-clause guard ensures the loser sees rowcount=0"
log "    cleanly — no error, no event_log INSERT, no try/except needed in"
log "    workflow code."
