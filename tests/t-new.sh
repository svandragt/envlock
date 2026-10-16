#!/usr/bin/env bash
# Tests for the lease lifecycle, attach records, the queue, and --need and --want.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

echo "N1 name=\$(envlock acquire) returns promptly with the name, and the lease outlives the command"
fresh n1
s=$(date +%s%N); acq "$T/repo"; ms=$((($(date +%s%N) - s) / 1000000))
say "OUT=[$OUT] rc=$RC after ${ms}ms; stderr=[$(echo "$ERR" | tr '\n' ';')]; holder file: $(cat "$ED/base.holder")"
check "stdout is exactly the env name" [ "$OUT" = base ]
check "returned in under 3s" [ "$ms" -lt 3000 ]
check "lock still held after acquire exited" held base
hp=$(holder_pid base)
check "holder pid alive, detached, with fd 9 on base.lock" fd9_is "$hp" base
check "holder is in its own session" bash -c '[ "$(ps -o sid= -p "$0" | tr -d " ")" = "$0" ]' "$hp"
# The holder runs the wait as a child, so the holder pid is not the herdr process.
wp=$(wait_pid "$PANE")
check "the herdr wait is a separate process in the holder's session" bash -c '[ -n "$0" ] && [ "$0" != "$1" ] && [ "$(ps -o sid= -p "$0" | tr -d " ")" = "$1" ]' "$wp" "$hp"
check "the wait child does not hold the lease (fd 9 closed)" bash -c '! ls -l /proc/$0/fd 2>/dev/null | grep -q "\.lock"' "$wp"
check "holder ran herdr agent wait for the pane with both --until" grep -qx "agent wait $PANE --until idle --until done" "$STUB_DIR/calls"
check "holder stdin/stdout/stderr are not the caller's pipe" bash -c '! ls -l /proc/$0/fd/0 /proc/$0/fd/1 /proc/$0/fd/2 | grep -q pipe' "$hp"
check "reset and attach ran once" bash -c '[ "$(grep -c "^reset base" "$0")" = 1 ] && [ "$(grep -c "^attach base" "$0")" = 1 ]' "$TEST_LOG"

echo "N2 the agent going idle frees the lease; killing the holder frees it too"
idle "$PANE"
check "lock freed after the stub wait returns" wait_free base
say "holder pid $hp alive after idle: $(kill -0 "$hp" 2>/dev/null && echo yes || echo no)"
acq "$T/repo"
check "re-acquire after idle gives base again" [ "$OUT" = base ]
check "base held while the new holder lives" held base
hp=$(holder_pid base); kill "$hp"
check "lock freed after the holder was killed" wait_free base
# a missing pane or server: a herdr that fails at once ends the lease
mkdir -p "$T/failbin"; printf '#!/bin/sh\nexit 1\n' >"$T/failbin/herdr"; chmod +x "$T/failbin/herdr"
OUT=$(cd "$T/repo" && PATH=$T/failbin:$PATH HERDR_PANE_ID=gone "$EL" acquire 2>/dev/null); RC=$?
say "failing herdr: OUT=[$OUT] rc=$RC"
check "acquire still prints the env" [ "$OUT" = base ]
check "lease gone once herdr failed" wait_free base

echo "N3 second acquire from the same worktree reuses the lease; env and release work"
fresh n3
acq "$T/repo"; first=$OUT; hp=$(holder_pid base)
: >"$TEST_LOG"
acq "$T/repo"
say "second acquire: OUT=[$OUT] rc=$RC; log after it: [$(tr '\n' ';' <"$TEST_LOG")]; holder pid before=$hp after=$(holder_pid base)"
check "second acquire prints the same env, rc 0" bash -c '[ "$0" = "$1" ] && [ "$2" = 0 ]' "$OUT" "$first" "$RC"
check "no reset, attach or healthy ran" bash -c '[ ! -s "$0" ]' "$TEST_LOG"
check "same holder pid kept" [ "$(holder_pid base)" = "$hp" ]
out=$(cd "$T/repo" && "$EL" env); rc=$?
check "env prints the env, rc 0" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$out" "$rc"
wt a
out=$(cd "$T/a" && "$EL" env); rc=$?
say "env from a worktree with no lease: [$out] rc=$rc"
check "env exits 1 with no output when this worktree has no lease" bash -c '[ -z "$0" ] && [ "$1" = 1 ]' "$out" "$rc"
out=$(cd "$T/a" && "$EL" release); say "release from other worktree: $out"
check "release from another worktree touches nothing" held base
out=$(cd "$T/repo" && "$EL" release); say "release: $out"
check "release reports the env" grep -q "released base" <<<"$out"
check "release freed the lock" wait_free base
out=$(cd "$T/repo" && "$EL" env); rc=$?
check "env exits 1 after release" [ "$rc" = 1 ]
out=$(cd "$T/repo" && "$EL" release); say "release again: $out"
check "release with no lease says so, rc 0" grep -q "no lease held" <<<"$out"
check "a stale holder file does not make env succeed" bash -c '[ -s "$0" ]' "$ED/base.holder"
acq "$T/repo"
check "acquire after release takes a new lease (reset ran)" bash -c 'grep -q "^reset base" "$0"' "$TEST_LOG"

echo "N4 no HERDR_PANE_ID"
fresh n4
out=$(cd "$T/repo" && env -u HERDR_PANE_ID "$EL" acquire 2>&1); rc=$?
say "rc=$rc out=[$out]"
check "non-zero with a clear message" bash -c '[ "$0" != 0 ] && grep -q "HERDR_PANE_ID is not set" <<<"$1"' "$rc" "$out"
check "nothing leased, no hooks ran" bash -c '[ ! -s "$0" ]' "$TEST_LOG"
check "base free" free base

echo "N5 two repos that list the same env cannot both hold it"
fresh n5
new_repo repo2
export TEST_ENVS=shared
acq "$T/repo"; PA=$PANE; say "repo: OUT=[$OUT]"
check "repo got shared" [ "$OUT" = shared ]
acq "$T/repo2"; say "repo2: OUT=[$OUT] rc=$RC err=[$ERR]"
check "repo2 is refused (busy, exit 75)" [ "$RC" = 75 ]
check "the lock file is machine-wide, not in a per-repo dir" bash -c '[ -e "$0/shared.lock" ] && [ -z "$(find "$1"/envlock -name shared.lock -not -path "$0/*")" ]' "$ED" "$XDG_STATE_HOME"
st=$(cd "$T/repo2" && "$EL" status); say "repo2 status: $(echo "$st" | tr '\n' ';')"
check "repo2 status shows the holder and its pane" grep -qF "shared  held by $T/repo (main) pane $PA pid" <<<"$st"
idle "$PA"; wait_free shared
acq "$T/repo2"; say "after idle: repo2 OUT=[$OUT]"
check "repo2 gets it once the first agent is idle" [ "$OUT" = shared ]
unset TEST_ENVS

echo "N6 attach record"
fresh n6
acq "$T/repo"; idle "$PANE"; wait_free base
say "after lease 1: attach count $(count '^attach base'); .attached = [$(cat "$ED/base.attached")]"
check "attach ran, record names the worktree" bash -c '[ "$(grep -c "^attach base" "$0")" = 1 ] && [ "$(cat "$1")" = "$2" ]' "$TEST_LOG" "$ED/base.attached" "$T/repo"
acq "$T/repo"; idle "$PANE"; wait_free base
say "after lease 2: attach count $(count '^attach base'), reset count $(count '^reset base'); stderr=[$ERR]"
check "second lease skipped attach (no healthy hook defined)" [ "$(count '^attach base')" = 1 ]
check "second lease still reset" [ "$(count '^reset base')" = 2 ]
echo "  -- another worktree switches the env, then this one returns"
wt b
acq "$T/b"; idle "$PANE"; wait_free base
check "worktree b attached (record names b)" bash -c '[ "$(cat "$0")" = "$1" ]' "$ED/base.attached" "$T/b"
acq "$T/repo"; idle "$PANE"; wait_free base
check "returning worktree re-attached" [ "$(count '^attach base')" = 3 ]
echo "  -- attach that fails"
fresh n6b
export TEST_ATTACH_FAIL=1
acq "$T/repo"
say "failing attach: rc=$RC OUT=[$OUT]; .attached exists: $([ -e "$ED/base.attached" ] && echo yes || echo no); base free: $(free base && echo yes || echo no)"
check "acquire fails" [ "$RC" != 0 ]
check "no record left" [ ! -e "$ED/base.attached" ]
check "lock released with the failed foreground" wait_free base
unset TEST_ATTACH_FAIL
acq "$T/repo"; idle "$PANE"; wait_free base
check "next lease re-attached" [ "$(count '^attach base')" = 2 ]
check "record now names the worktree" [ "$(cat "$ED/base.attached")" = "$T/repo" ]
echo "  -- a failing attach deletes an existing record first"
export TEST_HEALTHY_RC=1 TEST_ATTACH_FAIL=1
acq "$T/repo"
say "healthy=1 and attach fails: rc=$RC; record exists: $([ -e "$ED/base.attached" ] && echo yes || echo no)"
check "old record removed before the failing attach" [ ! -e "$ED/base.attached" ]
unset TEST_HEALTHY_RC TEST_ATTACH_FAIL
wait_free base
echo "  -- envpool_healthy"
fresh n6c
export TEST_HEALTHY_RC=0
acq "$T/repo"; idle "$PANE"; wait_free base
check "first lease: attach ran, healthy not asked (no record yet)" bash -c '[ "$(grep -c "^attach base" "$0")" = 1 ] && ! grep -q "^healthy" "$0"' "$TEST_LOG"
acq "$T/repo"; idle "$PANE"; wait_free base
say "healthy returns 0: attach count $(count '^attach base'), healthy count $(count '^healthy base')"
check "healthy 0: attach skipped, healthy asked once" bash -c '[ "$(grep -c "^attach base" "$0")" = 1 ] && [ "$(grep -c "^healthy base" "$0")" = 1 ]' "$TEST_LOG"
export TEST_HEALTHY_RC=1
acq "$T/repo"; idle "$PANE"; wait_free base
say "healthy returns 1: attach count $(count '^attach base'), healthy count $(count '^healthy base')"
check "healthy 1: attach ran again" [ "$(count '^attach base')" = 2 ]
check "record rewritten after the successful re-attach" [ "$(cat "$ED/base.attached")" = "$T/repo" ]
unset TEST_HEALTHY_RC

echo "N7 membership recheck: an env that left the pool but whose lock is free is skipped"
fresh n7
wt a; acq "$T/a"; PA=$PANE
register g2
export TEST_DROP=$LD/envs
: >"$TEST_LOG"
acq "$T/repo"
say "rc=$RC OUT=[$OUT] err=[$ERR] envs=[$(envs_now)] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "acquire exits 75 instead of leasing g2" [ "$RC" = 75 ]
check "g2's lock was dropped" free g2
check "no hook ran for g2" nolog g2
unset TEST_DROP
register g2
acq "$T/repo"
say "control without the drop: rc=$RC OUT=[$OUT]"
check "control: g2 is leased when it is still a member" [ "$OUT" = g2 ]

echo "W1 status shows the attributes; a failing or missing describe does not break it"
fresh w1; withattrs; export TEST_ENVS="e1 e2 e3"
setattrs e1 wp=7.1 php=8.4; setattrs e2 wp=6.9 php=8.3; setattrs e3 wp=7.1 php=8.4
acq "$T/repo" --need wp=6.9; PA=$PANE
st=$(cd "$T/repo" && "$EL" status); rc=$?
say "rc=$rc status: $(echo "$st" | tr '\n' '|')"
check "free env line ends with its attributes" grep -qx 'e1  free  wp=7.1 php=8.4' <<<"$st"
check "held env line ends with its attributes after the holder" grep -Eq "^e2  held by $T/repo \(main\) pane $PA pid [0-9]+  wp=6.9 php=8.3\$" <<<"$st"
export TEST_DESC_FAIL=e1
st=$(cd "$T/repo" && "$EL" status); rc=$?
say "describe fails for e1: rc=$rc status: $(echo "$st" | tr '\n' '|')"
check "status still exits 0" [ "$rc" = 0 ]
check "e1 line has no attributes, not even partial output" grep -qx 'e1  free' <<<"$st"
check "other lines keep their attributes" grep -qx 'e3  free  wp=7.1 php=8.4' <<<"$st"
unset TEST_ATTRS
st=$(cd "$T/repo" && "$EL" status); rc=$?
say "no describe hook: rc=$rc status: $(echo "$st" | tr '\n' '|')"
check "no hook: lines print as before" bash -c '[ "$1" = 0 ] && grep -qx "e1  free" <<<"$0" && grep -qx "e3  free" <<<"$0"' "$st" "$rc"

echo "W2 --need picks a free matching env over a non-matching one that is earlier in the pool"
fresh w2; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1 php=8.4; setattrs e2 wp=6.9 php=8.4; setattrs e3 wp=7.1 php=8.3
acq "$T/repo" --need wp=6.9
say "want wp=6.9: OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "leased e2, the only match" [ "$OUT" = e2 ]
check "configure did not run" nolog configure
check "reset and attach ran on e2" bash -c '[ "$(tr "\n" , <"$0")" = "reset e2,attach e2," ]' "$TEST_LOG"
fresh w2b; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1 php=8.4; setattrs e2 wp=6.9 php=8.4; setattrs e3 wp=6.9 php=8.3
acq "$T/repo" --need wp=6.9 --need php=8.3
say "want wp=6.9 and php=8.3: OUT=[$OUT] rc=$RC"
check "repeated --need needs every pair: e3" [ "$OUT" = e3 ]
check "configure did not run" nolog configure

echo "W3 no env matches: configure runs on the chosen env before reset and attach, with every pair"
fresh w3; withattrs; export TEST_ENVS="e1 e2" TEST_CONF=1
setattrs e1 wp=7.1 php=8.4; setattrs e2 wp=7.1 php=8.4
acq "$T/repo" --need wp=6.9 --need php=8.3
say "OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "e1 chosen (pool order, no affinity), name printed on stdout only" [ "$OUT" = e1 ]
check "hook log order is configure, reset, attach, with both pairs" bash -c '[ "$(tr "\n" , <"$0")" = "configure e1 wp=6.9 php=8.3,reset e1,attach e1," ]' "$TEST_LOG"
check "e1 holds wp=6.9 and php=8.3 and no stale values" bash -c 'grep -qx wp=6.9 "$0" && grep -qx php=8.3 "$0" && ! grep -qx wp=7.1 "$0" && ! grep -qx php=8.4 "$0"' "$TEST_ATTRS/e1"
check "e2 untouched" [ "$(attrs_of e2)" = "wp=7.1 php=8.4" ]
echo "  -- growth when nothing matches and configure exists: the grown env is configured"
fresh w3b; withattrs; export TEST_ENVS="e1" TEST_MAX=2 TEST_PREFIX=g TEST_CONF=1
setattrs e1 wp=7.1
acq "$T/repo"; PA=$PANE
wt b
acq "$T/b" --wait 20 --need wp=6.9
say "from worktree b with e1 held: OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "pool grew g2, which clones wp=7.1, then g2 was configured to wp=6.9; e1 was not touched" bash -c 'grep -qx "create g2" "$0" && grep -qx "configure g2 wp=6.9" "$0" && ! grep -q "configure e1" "$0"' "$TEST_LOG"
check "b leased g2 and the order was create, configure, reset, attach" bash -c '[ "$1" = g2 ] && [ "$(grep -n "g2" "$0" | cut -d: -f2- | tr "\n" ,)" = "create g2,configure g2 wp=6.9,reset g2,attach g2," ]' "$TEST_LOG" "$OUT"

echo "W4 a failing configure: acquire exits non-zero and the lease is free afterwards"
fresh w4; withattrs; export TEST_ENVS="e1" TEST_CONF=1
setattrs e1 wp=7.1
acq "$T/repo"; idle "$PANE"; wait_free e1
check "setup: a normal lease left an attach record" [ -e "$ED/e1.attached" ]
: >"$TEST_LOG"
export TEST_CONF_FAIL=1
acq "$T/repo" --need wp=6.9
say "OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "acquire exits non-zero with nothing on stdout" bash -c '[ "$0" != 0 ] && [ -z "$1" ]' "$RC" "$OUT"
check "stderr logs the failure" grep -q "configuring e1 failed" <<<"$ERR"
check "no reset or attach ran" bash -c '[ "$(tr "\n" , <"$0")" = "configure e1 wp=6.9," ]' "$TEST_LOG"
check "the lock is free" wait_free e1
check "this worktree holds no lease" bash -c '! (cd "$0" && "$1" env >/dev/null)' "$T/repo" "$EL"
check "the attach record is gone, so the next lease re-attaches" [ ! -e "$ED/e1.attached" ]
unset TEST_CONF_FAIL
acq "$T/repo" --need wp=6.9
say "retry without the failure: OUT=[$OUT] rc=$RC"
check "the retry works and re-attaches (the log was cleared after setup, so one attach)" bash -c '[ "$0" = e1 ] && [ "$(grep -c "^attach e1" "$1")" = 1 ]' "$OUT" "$TEST_LOG"

echo "W5 without configure only a matching env is eligible: waiters keep their place, --wait 0 exits 75"
fresh w5; withattrs; export TEST_ENVS="e1 e2"
setattrs e1 wp=7.1; setattrs e2 wp=6.9
wt a
acq "$T/a" --need wp=6.9; PA=$PANE
check "setup: a holds the only matching env e2" [ "$OUT" = e2 ]
acq "$T/repo" --need wp=6.9 --wait 0
say "e1 is free but does not match: OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')]"
check "--wait 0 exits 75" [ "$RC" = 75 ]
check "the message names what is missing" grep -q "all environments busy or lacking wp=6.9" <<<"$ERR"
check "e1 stayed free and no hook ran for it" bash -c '[ ! -s "$0" ] || ! grep -q e1 "$0"' "$TEST_LOG"
free e1 && echo "  observed: e1 free" || echo "  observed: e1 HELD"
check "e1 is still free" free e1
(cd "$T/repo" && HERDR_PANE_ID=pw "$EL" acquire --need wp=6.9 --wait 30 >"$T/w.out" 2>"$T/w.err"; echo $? >"$T/w.rc") &
sleep 1.5
st=$(cd "$T/repo" && "$EL" status)
say "waiter started; status: $(echo "$st" | tr '\n' '|')"
check "the waiter is queued" grep -q '^queued 1' <<<"$st"
check "the waiter has not taken e1" bash -c '[ ! -e "$0" ]' "$T/w.rc"
idle "$PA"
for _ in $(seq 40); do [ -e "$T/w.rc" ] && break; sleep 0.5; done
say "after e2 freed: waiter rc=$(cat "$T/w.rc" 2>/dev/null) out=[$(cat "$T/w.out")]"
check "the waiter got e2 once it freed" bash -c '[ "$(cat "$0")" = 0 ] && [ "$(cat "$1")" = e2 ]' "$T/w.rc" "$T/w.out"
touch "$STUB_DIR/pw"
echo "  -- growth still happens when allowed, but a grown env that does not match is not eligible without configure"
fresh w5b; withattrs; export TEST_ENVS="e1" TEST_MAX=2 TEST_PREFIX=g
setattrs e1 wp=7.1
wt a
acq "$T/a"; PA=$PANE
acq "$T/repo" --need wp=6.9 --wait 1
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "pool grew g2 (it clones wp=7.1)" logged "create g2"
check "waiter still exits 75: g2 does not match and cannot be configured" [ "$RC" = 75 ]
check "g2 was not leased" free g2

echo "W6 --need without envpool_describe exits non-zero with a clear message; --want is ignored with a note"
fresh w6
acq "$T/repo" --need wp=6.9
say "OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "non-zero, names the missing hook" bash -c '[ "$0" != 0 ] && grep -q "envpool_describe" <<<"$1"' "$RC" "$ERR"
check "nothing leased, no hook ran" bash -c '[ -z "$0" ] && [ ! -s "$1" ]' "$OUT" "$TEST_LOG"
check "base is free" free base
acq "$T/repo" --need wp
say "malformed --need: rc=$RC stderr=[$ERR]"
check "a --need without key=value is refused" bash -c '[ "$0" = 2 ] && grep -q "key=value" <<<"$1"' "$RC" "$ERR"
acq "$T/repo" --want wp=6.9
say "--want, no describe hook: OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "leased as usual, rc 0" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "one stderr note says --want is ignored" bash -c '[ "$(grep -c "ignoring --want" <<<"$0")" = 1 ]' "$ERR"

echo "W7 reuse: a lease that does not match --need is configured in place, or refused without configure"
fresh w7; withattrs; export TEST_ENVS="e1 e2" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=7.1
acq "$T/repo"; hp=$(holder_pid e1)
: >"$TEST_LOG"
acq "$T/repo" --need wp=6.9
say "reuse with a mismatch: OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')] log=[$(tr '\n' ';' <"$TEST_LOG")]; holder pid before=$hp after=$(holder_pid e1)"
check "prints e1, rc 0" bash -c '[ "$0" = e1 ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "configure ran on e1 in place, with no reset or attach" bash -c '[ "$(tr "\n" , <"$0")" = "configure e1 wp=6.9," ]' "$TEST_LOG"
check "same lease kept" [ "$(holder_pid e1)" = "$hp" ]
check "e1 now describes wp=6.9" grep -qx wp=6.9 "$TEST_ATTRS/e1"
: >"$TEST_LOG"
acq "$T/repo" --need wp=6.9
check "a second call finds a match and does not configure again" bash -c '[ "$0" = e1 ] && [ ! -s "$1" ]' "$OUT" "$TEST_LOG"
fresh w7b; withattrs; export TEST_ENVS="e1 e2"
setattrs e1 wp=7.1; setattrs e2 wp=7.1
acq "$T/repo"; hp=$(holder_pid e1)
acq "$T/repo" --need wp=6.9
say "reuse, no configure hook: OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "exits non-zero, nothing on stdout" bash -c '[ "$0" != 0 ] && [ -z "$1" ]' "$RC" "$OUT"
check "tells the caller to release first" grep -q "envlock release first" <<<"$ERR"
check "the lease is untouched" bash -c 'fd9=$(readlink /proc/$0/fd/9) && [ "$fd9" = "$1/e1.lock" ]' "$hp" "$ED"

echo "W8 candidate order: match+affinity, match, affinity, the rest"
fresh w8a; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=6.9; setattrs e2 wp=6.9; setattrs e3 wp=6.9
echo "$T/repo (main) pane old pid 1" >"$ED/e3.holder"
acq "$T/repo" --need wp=6.9
say "e1,e2,e3 all match, holder names e3: OUT=[$OUT]"
check "match + affinity ranks first (e3, not the earlier e1)" [ "$OUT" = e3 ]
fresh w8b; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=6.9; setattrs e3 wp=7.1
echo "$T/repo (main) pane old pid 1" >"$ED/e1.holder"
acq "$T/repo" --need wp=6.9
say "only e2 matches, holder names e1: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "a match beats affinity without a match (e2)" [ "$OUT" = e2 ]
check "no configure needed" nolog configure
fresh w8c; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=7.1; setattrs e3 wp=7.1
echo "$T/repo (main) pane old pid 1" >"$ED/e2.holder"
acq "$T/repo" --need wp=6.9
say "nothing matches, holder names e2: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "affinity beats pool order when nothing matches (e2, configured)" bash -c '[ "$0" = e2 ] && head -1 "$1" | grep -qx "configure e2 wp=6.9"' "$OUT" "$TEST_LOG"
echo "W9 soft --want: only ranks; picks a matching env when one is free"
fresh w9; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=6.9; setattrs e3 wp=7.1
acq "$T/repo" --want wp=6.9
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "leased e2, the matching env, over the earlier e1" [ "$OUT" = e2 ]
check "configure did not run" nolog configure
fresh w9b; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=6.9; setattrs e2 wp=6.9; setattrs e3 wp=6.9
echo "$T/repo (main) pane old pid 1" >"$ED/e3.holder"
acq "$T/repo" --want wp=6.9
check "want + affinity ranks first (e3)" [ "$OUT" = e3 ]
fresh w9c; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=6.9; setattrs e3 wp=7.1
echo "$T/repo (main) pane old pid 1" >"$ED/e1.holder"
acq "$T/repo" --want wp=6.9
say "holder names the non-matching e1: OUT=[$OUT]"
check "a wanted match beats affinity (e2)" [ "$OUT" = e2 ]

echo "W10 soft --want takes a non-matching env, without configure, when none match"
fresh w10; withattrs; export TEST_ENVS="e1 e2" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=7.1
acq "$T/repo" --want wp=6.9
say "OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "leased e1 (pool order), rc 0" bash -c '[ "$0" = e1 ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "configure did not run; reset and attach did" bash -c '[ "$(tr "\n" , <"$0")" = "reset e1,attach e1," ]' "$TEST_LOG"
check "e1 attributes unchanged" [ "$(attrs_of e1)" = wp=7.1 ]
fresh w10b; withattrs; export TEST_ENVS="e1 e2"
setattrs e1 wp=7.1; setattrs e2 wp=7.1
acq "$T/repo" --want wp=6.9 --wait 0
check "same without an envpool_configure hook" [ "$OUT" = e1 ]
echo "  -- a reused lease that does not match --want is left alone"
fresh w10c; withattrs; export TEST_ENVS="e1 e2" TEST_CONF=1
setattrs e1 wp=7.1; setattrs e2 wp=7.1
acq "$T/repo"; : >"$TEST_LOG"
acq "$T/repo" --want wp=6.9
check "reuse prints e1 and never configures" bash -c '[ "$0" = e1 ] && [ ! -s "$1" ]' "$OUT" "$TEST_LOG"
echo "  -- when every env is busy a soft want does not wait for a match"
fresh w10d; withattrs; export TEST_ENVS="e1 e2"
setattrs e1 wp=7.1; setattrs e2 wp=6.9
wt a; wt b
acq "$T/a" --need wp=6.9; check "setup: a holds the only matching env e2" [ "$OUT" = e2 ]
acq "$T/b" --want wp=6.9 --wait 0
check "b takes the free non-matching e1 at once" [ "$OUT" = e1 ]

echo "W11 --need and --want together: needs decide eligibility, wants break ties"
fresh w11; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=6.9 php=8.4; setattrs e2 wp=6.9 php=8.3; setattrs e3 wp=7.1 php=8.3
acq "$T/repo" --need wp=6.9 --want php=8.3
say "OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "e2 meets the need and the want" [ "$OUT" = e2 ]
check "configure did not run" nolog configure
fresh w11b; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1 php=8.3; setattrs e2 wp=6.9 php=8.4; setattrs e3 wp=7.1 php=8.3
acq "$T/repo" --need wp=6.9 --want php=8.3
say "OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "a needed match beats a wanted match (e2)" [ "$OUT" = e2 ]
check "configure did not run" nolog configure
fresh w11c; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=7.1 php=8.4; setattrs e2 wp=7.1 php=8.3; setattrs e3 wp=7.1 php=8.4
acq "$T/repo" --need wp=6.9 --want php=8.3
say "no env has the need: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "configure runs on e2 (the wanted one) with the needed pair only" bash -c '[ "$0" = e2 ] && head -1 "$1" | grep -qx "configure e2 wp=6.9"' "$OUT" "$TEST_LOG"
fresh w11d; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=6.9 php=8.4; setattrs e2 wp=6.9 php=8.3; setattrs e3 wp=6.9 php=8.3
echo "$T/repo (main) pane old pid 1" >"$ED/e1.holder"
acq "$T/repo" --need wp=6.9 --want php=8.3
check "a wanted match beats affinity among needed matches (e2)" [ "$OUT" = e2 ]
fresh w11e; withattrs; export TEST_ENVS="e1 e2 e3" TEST_CONF=1
setattrs e1 wp=6.9 php=8.3; setattrs e2 wp=6.9 php=8.3; setattrs e3 wp=6.9 php=8.3
echo "$T/repo (main) pane old pid 1" >"$ED/e3.holder"
acq "$T/repo" --need wp=6.9 --want php=8.3
check "need + want + affinity ranks first (e3)" [ "$OUT" = e3 ]
fresh w11f; withattrs; export TEST_ENVS="e1 e2"
setattrs e1 wp=7.1 php=8.3; setattrs e2 wp=6.9 php=8.4
acq "$T/repo" --need wp=6.9 --want php=8.3 --wait 0
check "without configure only needed matches are eligible, even if another env has the want (e2)" [ "$OUT" = e2 ]

summary
