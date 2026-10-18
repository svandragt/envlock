#!/usr/bin/env bash
# Tests for acquire --fresh and envpool_fresh.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

ev() { cat "$LD/events.log" 2>/dev/null; }
evhas() { ev | grep -qE -- "$1"; }
steps() { cut -d' ' -f1 "$TEST_LOG" | tr '\n' ' '; }
queue_empty() { [ -z "$(ls "$LD/queue")" ]; }
holder_kept() { [ "$(holder_pid base)" = "$1" ] && fd9_is "$1" base; }
not_released() { ! ev | grep -q " released "; }

echo "R1 --fresh without envpool_fresh exits 1 before queueing"
fresh r1
acq "$T/repo" --fresh
say "OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "exits 1 and names the missing hook" bash -c '[ "$0" = 1 ] && grep -q "envpool_fresh" <<<"$1"' "$RC" "$ERR"
check "no queued line" bash -c '! grep -q queued "$0/events.log" 2>/dev/null' "$LD"
check "no queue file" queue_empty
check "no hook ran" [ ! -s "$TEST_LOG" ]

echo "R2 a new lease runs reset, attach and fresh in that order, and stdout stays the env name"
fresh r2; export TEST_FRESH=1
acq "$T/repo" --urgent --fresh
say "OUT=[$OUT] rc=$RC log=[$(steps)] stderr=[$(echo "$ERR" | tr '\n' ';')]"
check "stdout is exactly the env name" [ "$OUT" = base ]
check "reset, attach, fresh" [ "$(steps)" = "reset attach fresh " ]
check "the hook saw ENVLOCK_ENV and ENVLOCK_WORKTREE" logged "fresh base $T/repo"
check "the hook's stdout went to stderr" grep -qx 'seed copied to base' <<<"$ERR"
check "queued line carries urgent and fresh" evhas ' queued main pane '"$PANE"' urgent fresh$'
check "fresh line, then leased line" bash -c 'f=$(grep -n " fresh base main pane " "$0" | cut -d: -f1); l=$(grep -n " leased " "$0" | cut -d: -f1); [ -n "$f" ] && [ "$f" -lt "$l" ]' "$LD/events.log"
check "base is held" held base

echo "R3 fresh still runs when attach is skipped"
fresh r3; export TEST_FRESH=1 TEST_HEALTHY_RC=0
acq "$T/repo" --fresh; idle "$PANE"; wait_free base; : >"$TEST_LOG"
acq "$T/repo" --fresh
say "second lease: OUT=[$OUT] rc=$RC log=[$(steps)]"
check "healthy ran and attach did not, then fresh ran" [ "$(steps)" = "reset healthy fresh " ]

echo "R4 reuse with --fresh runs fresh in place and keeps the holder"
fresh r4; export TEST_FRESH=1
acq "$T/repo"; hp=$(holder_pid base); p=$PANE
acq "$T/repo" --fresh
say "reuse: OUT=[$OUT] rc=$RC log=[$(steps)] holder before=$hp after=$(holder_pid base)"
check "stdout is exactly the env name, exit 0" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "reuse ran fresh and no second reset or attach" [ "$(steps)" = "reset attach fresh " ]
check "the holder pid is unchanged and still holds the lock" holder_kept "$hp"
check "the hook's stdout went to stderr" grep -qx 'seed copied to base' <<<"$ERR"
check "fresh is logged before reused" bash -c 'f=$(grep -n " fresh base " "$0" | cut -d: -f1); r=$(grep -n " reused base " "$0" | cut -d: -f1); [ -n "$f" ] && [ "$f" -lt "$r" ]' "$LD/events.log"
idle "$p"

echo "R5 a failing fresh on a new lease logs fresh-failed, starts no holder and frees the lock"
fresh r5; export TEST_FRESH=1 TEST_FRESH_FAIL=1
acq "$T/repo" --fresh
say "OUT=[$OUT] rc=$RC log=[$(steps)]"
check "exits non-zero with nothing on stdout" bash -c '[ "$0" != 0 ] && [ -z "$1" ]' "$RC" "$OUT"
check "fresh-failed carries the env and the exit status" evhas ' fresh-failed base main pane '"$PANE"' exit=1$'
check "no fresh line, no leased line, no holder wait" bash -c '! grep -qE " (fresh|leased) " "$0/events.log"' "$LD"
check "no stub holder is waiting" nowait "$PANE"
check "the attach record is kept" [ "$(attached_of base)" = "$T/repo" ]
check "the lock is free" free base
check "the queue is empty" queue_empty
unset TEST_FRESH_FAIL
acq "$T/repo" --wait 0
say "next acquire: OUT=[$OUT] rc=$RC"
check "a following acquire gets the env" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"

echo "R6 a failing fresh on reuse keeps the lease alive"
fresh r6; export TEST_FRESH=1
acq "$T/repo"; hp=$(holder_pid base); p=$PANE
export TEST_FRESH_FAIL=1
acq "$T/repo" --fresh
say "OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')]"
check "exits non-zero with nothing on stdout" bash -c '[ "$0" != 0 ] && [ -z "$1" ]' "$RC" "$OUT"
check "fresh-failed is logged" evhas ' fresh-failed base main pane .* exit=1$'
check "the holder is the same process and still holds the lock" holder_kept "$hp"
check "base is still held" held base
check "no released line was logged" not_released
unset TEST_FRESH_FAIL
acq "$T/repo" --fresh
check "a later --fresh on the same lease works" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
idle "$p"

echo "R7 --fresh combines with --need: configure, reset, attach, fresh"
fresh r7; withattrs; export TEST_FRESH=1 TEST_CONF=1
setattrs base wp=6.9
acq "$T/repo" --wait 0 --urgent --need wp=7.1 --fresh
say "OUT=[$OUT] rc=$RC log=[$(steps)]"
check "configure ran first and fresh last" [ "$(steps)" = "configure reset attach fresh " ]
check "queued line carries need, urgent and fresh" evhas ' queued main pane '"$PANE"' need=wp=7.1 urgent fresh$'

summary
