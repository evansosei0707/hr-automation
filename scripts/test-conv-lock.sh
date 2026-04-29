#!/usr/bin/env bash
# test-conv-lock.sh
# Verifies the conversation-lock pattern (CLAUDE.md non-negotiable invariant #3):
#
#   Acquire:    SET <key> <token> NX PX <ttl_ms>
#   Heartbeat:  Lua CAS PEXPIRE — extends TTL only if value matches
#   Release:    Lua CAS DEL     — deletes only if value matches
#
# Four scenarios × ROUNDS rounds (default 5):
#
#   S1 — Mutex.
#        Two acquirers race on the same key; exactly one wins, loser sees
#        a nil reply and exits cleanly.
#
#   S2 — Heartbeat-during-long-call.
#        Round 1 = production canary (60s TTL, 15s HB interval, 45s call,
#        PTTL floor = 25000ms). Rounds 2..N = compressed (6s / 1.5s / 4.5s,
#        floor = 2500ms). Per refinement #1: assert exactly
#        floor(call_duration / hb_interval) = 3 heartbeats fired AND each
#        returned 1 (CAS success). Catches the "TTL stayed high enough by
#        luck" bug class. Per refinement #3: PTTL floor relaxed for WSL
#        scheduler jitter (was 30000 / 3000 in design; landed 25000 / 2500).
#
#   S3 — Release-by-non-holder.
#        B's CAS DEL with the wrong token returns 0; lock unchanged; A's
#        own release returns 1 and the key is gone. Catches the
#        "release deletes any lock by key" bug.
#
#   S4 — Stale-heartbeat-after-takeover (the foundational subtle-bug check).
#        A's lock expires; B acquires; A's late heartbeat fires with stale
#        token. Heartbeat must return 0; B's PTTL must NOT be extended.
#        Per refinement #2: explicit 0.2s sleep AFTER B acquires guarantees
#        we test "heartbeat fires while another holder owns the key" and
#        not "heartbeat fires on empty key" (which is a different bug class).
#
# Cleanup runs at start AND end (trap), so teardown happens even on crash,
# Ctrl+C, or timeout. All test data uses one PID-scoped $KEY; explicit DEL
# between rounds.
#
# Prerequisites:
#   - hr-redis container running and healthy
#   - uuidgen on PATH
#
# Usage:
#   ./scripts/test-conv-lock.sh           # 5 rounds each scenario (default)
#   ./scripts/test-conv-lock.sh -n 3      # 3 rounds each scenario
#   ./scripts/test-conv-lock.sh -v        # verbose: show ack values per round

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
# Helpers (all log/status writes go to stderr; stdout is reserved for
# return values from test_*_round helpers — same convention as Phase 3).
# ─────────────────────────────────────────────
log()      { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
err()      { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()      { err "$*"; exit 1; }
pass()     { printf '[%s] [PASS] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail_msg() { printf '[%s] [FAIL] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
for dep in docker uuidgen; do
  command -v "$dep" >/dev/null 2>&1 || die "Required tool '$dep' not found"
done

REDIS_CONTAINER="${REDIS_CONTAINER:-hr-redis}"
docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER}$" \
  || die "Container '$REDIS_CONTAINER' is not running"

rcli() {
  docker exec -i "$REDIS_CONTAINER" redis-cli "$@"
}

[ "$(rcli PING 2>/dev/null)" = "PONG" ] || die "redis-cli PING failed"

# ─────────────────────────────────────────────
# Lua scripts (loaded once via SCRIPT LOAD; EVALSHA per round)
# ─────────────────────────────────────────────
HB_LUA='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("PEXPIRE", KEYS[1], ARGV[2]) else return 0 end'
REL_LUA='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end'

HB_SHA=$(rcli SCRIPT LOAD "$HB_LUA")
REL_SHA=$(rcli SCRIPT LOAD "$REL_LUA")
[ -n "$HB_SHA" ]  || die "Failed to SCRIPT LOAD heartbeat Lua"
[ -n "$REL_SHA" ] || die "Failed to SCRIPT LOAD release Lua"
log "Heartbeat Lua SHA: $HB_SHA"
log "Release Lua SHA:   $REL_SHA"

# ─────────────────────────────────────────────
# Test key + cleanup
# ─────────────────────────────────────────────
KEY="test:lock:conv-test:$$"

cleanup() {
  rcli DEL "$KEY" >/dev/null 2>&1 || true
  # Kill only this shell's backgrounded jobs (NOT `kill 0`, which would
  # SIGTERM the parent process group including the user's terminal shell).
  local jpids
  jpids=$(jobs -p 2>/dev/null || true)
  if [ -n "$jpids" ]; then
    # shellcheck disable=SC2086
    kill $jpids 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cleanup
log "Pre-test cleanup done. Test key: $KEY"

# ─────────────────────────────────────────────
# S1 — Mutex
# ─────────────────────────────────────────────
test_s1_round() {
  local r=$1
  rcli DEL "$KEY" >/dev/null
  local t_a t_b
  t_a=$(uuidgen); t_b=$(uuidgen)
  local out_a="/tmp/_lock_s1_a_$$_r$r.out"
  local out_b="/tmp/_lock_s1_b_$$_r$r.out"

  ( rcli SET "$KEY" "$t_a" NX PX 60000 > "$out_a" 2>&1 ) &
  local pid_a=$!
  ( rcli SET "$KEY" "$t_b" NX PX 60000 > "$out_b" 2>&1 ) &
  local pid_b=$!
  wait $pid_a; wait $pid_b

  local ack_a ack_b
  ack_a=$(tr -d '[:space:]' < "$out_a")
  ack_b=$(tr -d '[:space:]' < "$out_b")

  [ "$VERBOSE" -eq 1 ] && log "  s1 r$r: ack_a='$ack_a' ack_b='$ack_b'"

  local winners=0 winner_label= winner_token=
  [ "$ack_a" = "OK" ] && { winners=$((winners+1)); winner_label="A"; winner_token="$t_a"; }
  [ "$ack_b" = "OK" ] && { winners=$((winners+1)); winner_label="${winner_label:-}B"; winner_token="${winner_token:-$t_b}"; }
  if [ "$winners" -ne 1 ]; then
    fail_msg "S1 r$r: expected exactly 1 winner, got $winners (ack_a='$ack_a' ack_b='$ack_b')"
    return 1
  fi
  for f in "$out_a" "$out_b"; do
    if grep -qE 'ERR|WRONGTYPE|NOAUTH' "$f"; then
      fail_msg "S1 r$r: error reply in $f"
      cat "$f" >&2
      return 1
    fi
  done
  local stored
  stored=$(rcli GET "$KEY")
  if [ "$stored" != "$winner_token" ]; then
    fail_msg "S1 r$r: GET returned '$stored', expected winner token '$winner_token'"
    return 1
  fi

  pass "S1 r$r: winner=$winner_label, GET matches winner token, loser ack=(nil) cleanly"
  echo "$winner_label"
  rm -f "$out_a" "$out_b"
  return 0
}

# ─────────────────────────────────────────────
# S2 — Heartbeat-during-long-call
# Args: round ttl_ms hb_interval_s call_duration_s pttl_floor_ms
#       expected_hb_count pttl_poll_interval_s label
# ─────────────────────────────────────────────
test_s2_round() {
  local r=$1 ttl=$2 hb_int=$3 call=$4 floor=$5 expected_hb=$6 pi=$7 label=$8
  rcli DEL "$KEY" >/dev/null
  local tok; tok=$(uuidgen)
  local hb_out="/tmp/_lock_s2_hb_$$_r$r.out"
  local pt_out="/tmp/_lock_s2_pt_$$_r$r.out"
  : > "$hb_out"; : > "$pt_out"

  local ack
  ack=$(rcli SET "$KEY" "$tok" NX PX "$ttl")
  [ "$ack" = "OK" ] || { fail_msg "S2 r$r ($label): acquire returned '$ack', expected 'OK'"; return 1; }

  # Background heartbeat: fire $expected_hb times spaced $hb_int seconds apart.
  # Counted loop (not "until killed") so the count is deterministic.
  ( for _ in $(seq 1 "$expected_hb"); do
      sleep "$hb_int"
      rcli EVALSHA "$HB_SHA" 1 "$KEY" "$tok" "$ttl" >> "$hb_out" 2>&1
    done
  ) &
  local hb_pid=$!

  # Background PTTL poller — runs until killed after the call sleep completes.
  ( while :; do
      rcli PTTL "$KEY" >> "$pt_out" 2>&1
      sleep "$pi"
    done
  ) &
  local pt_pid=$!

  # Simulated Claude call.
  sleep "$call"

  # Wait for HB loop to complete its scheduled fires (its last fire is at
  # t = hb_int * expected_hb, which equals the call duration — there can
  # be a small race where the last fire lands just after sleep returns).
  wait $hb_pid 2>/dev/null || true
  # Stop the poller.
  kill $pt_pid 2>/dev/null || true
  wait $pt_pid 2>/dev/null || true

  # Assertion 1 — exactly $expected_hb heartbeat invocations recorded.
  local hb_count hb_ones
  hb_count=$(wc -l < "$hb_out" | tr -d ' ')
  if [ "$hb_count" != "$expected_hb" ]; then
    fail_msg "S2 r$r ($label): heartbeat invocations expected $expected_hb, got $hb_count"
    err "  --- hb output ---"; cat "$hb_out" >&2
    return 1
  fi

  # Assertion 2 — every heartbeat returned 1 (CAS success).
  hb_ones=$(grep -c '^1$' "$hb_out" || true)
  if [ "$hb_ones" != "$expected_hb" ]; then
    fail_msg "S2 r$r ($label): heartbeat CAS-success count expected $expected_hb, got $hb_ones"
    err "  --- hb output ---"; cat "$hb_out" >&2
    return 1
  fi

  # Assertion 3 — PTTL stayed above floor through the call.
  local min_pttl pttl_samples
  min_pttl=$(sort -n "$pt_out" | head -1)
  pttl_samples=$(wc -l < "$pt_out" | tr -d ' ')
  if [ -z "$min_pttl" ] || [ "$min_pttl" -lt "$floor" ]; then
    fail_msg "S2 r$r ($label): min PTTL = $min_pttl, expected >= $floor (samples=$pttl_samples)"
    err "  --- pttl samples ---"; cat "$pt_out" >&2
    return 1
  fi

  # Assertion 4 — lock still held by us at end of call.
  local stored
  stored=$(rcli GET "$KEY")
  if [ "$stored" != "$tok" ]; then
    fail_msg "S2 r$r ($label): post-call GET returned '$stored', expected '$tok'"
    return 1
  fi

  # Assertion 5 — release CAS succeeds.
  local rel
  rel=$(rcli EVALSHA "$REL_SHA" 1 "$KEY" "$tok")
  if [ "$rel" != "1" ]; then
    fail_msg "S2 r$r ($label): release CAS returned '$rel', expected 1"
    return 1
  fi

  pass "S2 r$r ($label): ${call}s call, HB fires=$hb_count (all CAS=1), PTTL samples=$pttl_samples min=${min_pttl}ms (floor=${floor}ms), release CAS=1"
  rm -f "$hb_out" "$pt_out"
  return 0
}

# ─────────────────────────────────────────────
# S3 — Release-by-non-holder
# ─────────────────────────────────────────────
test_s3_round() {
  local r=$1
  rcli DEL "$KEY" >/dev/null
  local t_a t_b; t_a=$(uuidgen); t_b=$(uuidgen)

  local ack
  ack=$(rcli SET "$KEY" "$t_a" NX PX 60000)
  [ "$ack" = "OK" ] || { fail_msg "S3 r$r: A acquire failed (ack='$ack')"; return 1; }

  # Assertion 1 — B's wrong-token release returns 0.
  local b_rel
  b_rel=$(rcli EVALSHA "$REL_SHA" 1 "$KEY" "$t_b")
  if [ "$b_rel" != "0" ]; then
    fail_msg "S3 r$r: B's wrong-token release returned '$b_rel', expected 0"
    return 1
  fi

  # Assertion 2 — lock unchanged.
  local stored pttl
  stored=$(rcli GET "$KEY")
  pttl=$(rcli PTTL "$KEY")
  if [ "$stored" != "$t_a" ]; then
    fail_msg "S3 r$r: after B's failed release, GET='$stored' expected '$t_a'"
    return 1
  fi
  if [ -z "$pttl" ] || [ "$pttl" -le 0 ]; then
    fail_msg "S3 r$r: after B's failed release, PTTL=$pttl expected > 0"
    return 1
  fi

  # Assertion 3 — A's own release returns 1.
  local a_rel
  a_rel=$(rcli EVALSHA "$REL_SHA" 1 "$KEY" "$t_a")
  if [ "$a_rel" != "1" ]; then
    fail_msg "S3 r$r: A's release returned '$a_rel', expected 1"
    return 1
  fi

  # Assertion 4 — key is gone.
  local exists
  exists=$(rcli EXISTS "$KEY")
  if [ "$exists" != "0" ]; then
    fail_msg "S3 r$r: after A release, EXISTS=$exists expected 0"
    return 1
  fi

  pass "S3 r$r: B wrong-token rel=0; lock unchanged (PTTL=${pttl}ms); A rel=1; EXISTS=0"
  return 0
}

# ─────────────────────────────────────────────
# S4 — Stale-heartbeat-after-takeover (the subtle-bug catcher)
# ─────────────────────────────────────────────
test_s4_round() {
  local r=$1
  rcli DEL "$KEY" >/dev/null
  local t_a t_b; t_a=$(uuidgen); t_b=$(uuidgen)

  # 1. A acquires with very short TTL.
  local ack_a
  ack_a=$(rcli SET "$KEY" "$t_a" NX PX 1000)
  [ "$ack_a" = "OK" ] || { fail_msg "S4 r$r: A acquire failed (ack='$ack_a')"; return 1; }

  # 2. Wait for A's lock to expire (1s TTL + 0.5s margin).
  sleep 1.5
  local existed
  existed=$(rcli EXISTS "$KEY")
  if [ "$existed" != "0" ]; then
    fail_msg "S4 r$r: A's lock should have expired by now, EXISTS=$existed"
    return 1
  fi

  # 3. B acquires.
  local ack_b
  ack_b=$(rcli SET "$KEY" "$t_b" NX PX 5000)
  [ "$ack_b" = "OK" ] || { fail_msg "S4 r$r: B acquire failed (ack='$ack_b')"; return 1; }

  # 4. Deterministic gap (refinement #2) — guarantees B's lock is the
  #    one A's stale heartbeat will hit, not an empty key.
  sleep 0.2

  local pttl_before
  pttl_before=$(rcli PTTL "$KEY")

  # 5. A's stale heartbeat fires with token t_a, requesting 60000ms TTL.
  #    A naive heartbeat (just PEXPIRE without GET-check) would extend B's
  #    lock to 60s. The CAS guard must reject it.
  local hb
  hb=$(rcli EVALSHA "$HB_SHA" 1 "$KEY" "$t_a" 60000)
  if [ "$hb" != "0" ]; then
    fail_msg "S4 r$r: stale heartbeat returned '$hb', expected 0 (CAS mismatch)"
    return 1
  fi

  # 6. B's lock unchanged: token still t_b, TTL not extended past original 5000ms.
  local stored pttl_after
  stored=$(rcli GET "$KEY")
  pttl_after=$(rcli PTTL "$KEY")
  if [ "$stored" != "$t_b" ]; then
    fail_msg "S4 r$r: GET='$stored' expected B's token '$t_b'"
    return 1
  fi
  # Ceiling = B's original 5000ms + 500ms WSL fudge. A naive heartbeat
  # would push this to ~60000.
  if [ "$pttl_after" -gt 5500 ]; then
    fail_msg "S4 r$r: PTTL after stale HB = $pttl_after, expected <= 5500 (heartbeat extended someone else's lock?)"
    return 1
  fi

  # Cleanup B's lock.
  rcli EVALSHA "$REL_SHA" 1 "$KEY" "$t_b" >/dev/null

  pass "S4 r$r: stale HB returned 0; GET still B's token; PTTL before=${pttl_before}ms after=${pttl_after}ms (ceiling=5500ms; no extension)"
  return 0
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
log ""
log "════════════════════════════════════════════"
log " test-conv-lock.sh"
log " Container: $REDIS_CONTAINER  Key: $KEY  Rounds per scenario: $ROUNDS"
log "════════════════════════════════════════════"

s1_failures=0; s1_a=0; s1_b=0
log ""
log "▶ S1: MUTEX (two acquirers race; exactly one wins)"
for r in $(seq 1 "$ROUNDS"); do
  log "─── S1 round $r ───"
  if winner=$(test_s1_round "$r"); then
    [ "$winner" = "A" ] && s1_a=$((s1_a+1))
    [ "$winner" = "B" ] && s1_b=$((s1_b+1))
  else
    s1_failures=$((s1_failures+1))
  fi
done

s2_failures=0
log ""
log "▶ S2: HEARTBEAT-DURING-LONG-CALL"
log "  round 1 = production canary (60s TTL / 15s HB / 45s call, expected_hb=3, floor=25000ms)"
log "  rounds 2-$ROUNDS = compressed (6s TTL / 1.5s HB / 4.5s call, expected_hb=3, floor=2500ms)"
log "─── S2 round 1 (production canary) ───"
if test_s2_round 1 60000 15 45 25000 3 5 "production"; then :; else s2_failures=$((s2_failures+1)); fi
for r in $(seq 2 "$ROUNDS"); do
  log "─── S2 round $r (compressed) ───"
  if test_s2_round "$r" 6000 1.5 4.5 2500 3 0.5 "compressed"; then :; else s2_failures=$((s2_failures+1)); fi
done

s3_failures=0
log ""
log "▶ S3: RELEASE-BY-NON-HOLDER (CAS DEL guard)"
for r in $(seq 1 "$ROUNDS"); do
  log "─── S3 round $r ───"
  if ! test_s3_round "$r"; then s3_failures=$((s3_failures+1)); fi
done

s4_failures=0
log ""
log "▶ S4: STALE-HEARTBEAT-AFTER-TAKEOVER (CAS PEXPIRE guard)"
for r in $(seq 1 "$ROUNDS"); do
  log "─── S4 round $r ───"
  if ! test_s4_round "$r"; then s4_failures=$((s4_failures+1)); fi
done

echo
echo "════════════════════════════════════════════"
echo " Summary"
echo "════════════════════════════════════════════"
printf " S1 mutex:                          %d/%d PASS  (A wins: %d / B wins: %d)\n" \
  "$((ROUNDS - s1_failures))" "$ROUNDS" "$s1_a" "$s1_b"
printf " S2 heartbeat-during-long-call:     %d/%d PASS  (1 production canary + %d compressed)\n" \
  "$((ROUNDS - s2_failures))" "$ROUNDS" "$((ROUNDS - 1))"
printf " S3 release-by-non-holder:          %d/%d PASS\n" \
  "$((ROUNDS - s3_failures))" "$ROUNDS"
printf " S4 stale-heartbeat-after-takeover: %d/%d PASS\n" \
  "$((ROUNDS - s4_failures))" "$ROUNDS"
echo "════════════════════════════════════════════"

total=$((s1_failures + s2_failures + s3_failures + s4_failures))
if [ "$total" -ne 0 ]; then
  err "$total round(s) FAILED. Conversation-lock invariant did not hold."
  exit 1
fi

log ""
log "All $((ROUNDS * 4)) rounds passed."
log "  - Mutex: SET NX gives exactly one acquirer per key; loser sees nil cleanly."
log "  - Heartbeat: CAS PEXPIRE extends TTL only when the holder fires;"
log "    PTTL stayed above floor through the 45s production-shape call."
log "  - Release: CAS DEL refuses non-holder; holder's release is clean."
log "  - Stale heartbeat: a heartbeat from an expired holder cannot extend"
log "    a different holder's lock — the foundational subtle-bug class."
exit 0
