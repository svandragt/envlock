#!/usr/bin/env bash
# Tests for envpool_suspend and the suspend pass.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

susp() { [ -e "$ED/$1.suspended" ]; }
nosusp() { ! susp "$1"; }
markers() { find "$ED" -name '*.suspended' -printf '%f\n' | sort | tr '\n' ' '; }
before() { awk -v a="^$1\$" -v b="^$2\$" '$0 ~ a && !x {x=NR} $0 ~ b && !y {y=NR} END {exit !(x && y && x < y)}' "$TEST_LOG"; }

echo "U1 acquire's detached job suspends the spares and not the env it leased"
fresh u1; export TEST_ENVS="a b c" TEST_SUSPEND=1
acq "$T/repo"; settle
say "OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")] markers: $(markers)"
check "acquire took a" [ "$OUT" = a ]
check "envpool_suspend ran for b and c" bash -c 'grep -qx "suspend b" "$0" && grep -qx "suspend c" "$0"' "$TEST_LOG"
check "b and c have markers" bash -c '[ -e "$0/b.suspended" ] && [ -e "$0/c.suspended" ]' "$ED"
check "a has no marker and was not suspended" bash -c '[ ! -e "$0/a.suspended" ] && ! grep -q "suspend a" "$1"' "$ED" "$TEST_LOG"
st=$(cd "$T/repo" && "$EL" status)
say "status: $(echo "$st" | tr '\n' ';')"
check "status shows a suspended free env" grep -qx 'b  free, suspended' <<<"$st"
check "status shows the leased env as before" grep -q '^a  held by ' <<<"$st"

echo "U2 an env that a live worktree last leased is not a spare, even when free"
fresh u2; export TEST_ENVS="a b" TEST_SUSPEND=1
acq "$T/repo"; idle "$PANE"; wait_free a; settle
elrun repo suspend
say "manual suspend: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "a is free but not suspended" bash -c '[ ! -e "$0/a.suspended" ] && ! grep -q "suspend a" "$1"' "$ED" "$TEST_LOG"
check "b is suspended" susp b
check "status shows a as plain free" bash -c '(cd "$0/repo" && "$1" status) | grep -qx "a  free"' "$T" "$EL"

echo "U2b a record whose worktree is gone no longer protects its env"
fresh u2b; export TEST_ENVS="a b" TEST_SUSPEND=1
wt w1
acq "$T/w1"; idle "$PANE"; wait_free a; settle
check "a is protected while w1 exists" nosusp a
rmwt w1
elrun repo suspend
say "after removing w1: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "a is suspended now" susp a
check "the dead record was deleted" bash -c '[ -z "$(ls "$0/last")" ]' "$LD"

echo "U3 a leased env is not suspended even when no live record names it"
fresh u3; export TEST_ENVS="a b" TEST_SUSPEND=1
wt w1
acq "$T/w1"; settle
rmwt w1
elrun repo suspend
say "a held, w1 gone: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "a is still held" held a
check "a was not suspended" bash -c '[ ! -e "$0/a.suspended" ] && ! grep -q "suspend a" "$1"' "$ED" "$TEST_LOG"
check "b was suspended" susp b

echo "U4 acquire clears the marker and runs attach even when the attach record matched"
fresh u4; withattrs; export TEST_ENVS="a b" TEST_SUSPEND=1 TEST_HEALTHY_RC=0
setattrs a wp=6.9; setattrs b wp=7.1
acq "$T/repo" --need wp=6.9; idle "$PANE"; wait_free a; settle
say "step 1: OUT=[$OUT] a.attached=[$(attached_of a)] markers: $(markers)"
check "step 1 leased a and wrote its attach record" bash -c '[ "$0" = a ] && [ "$1" = "$2" ]' "$OUT" "$(attached_of a)" "$T/repo"
check "b was suspended" susp b
acq "$T/repo" --need wp=7.1; idle "$PANE"; wait_free b; settle
say "step 2: OUT=[$OUT] markers: $(markers) log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "step 2 leased the suspended b" [ "$OUT" = b ]
check "b's marker is gone" nosusp b
check "attach and reset ran for b" bash -c 'grep -qx "attach b" "$0" && grep -qx "reset b" "$0"' "$TEST_LOG"
check "a is now a spare: suspended, attach record deleted" bash -c '[ -e "$0/a.suspended" ] && [ ! -e "$0/a.attached" ]' "$ED"
acq "$T/repo" --need wp=6.9
say "step 3: OUT=[$OUT] a.attached=[$(attached_of a)] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "step 3 leased a again" [ "$OUT" = a ]
check "attach a ran a second time although the record had named this worktree" [ "$(count '^attach a$')" = 2 ]
check "envpool_healthy was not asked about a" nolog 'healthy a'
check "a's marker is gone and its attach record is back" bash -c '[ ! -e "$0/a.suspended" ] && [ "$1" = "$2" ]' "$ED" "$(attached_of a)" "$T/repo"
idle "$PANE"

echo "U5 grow suspends the new env; shrink of a suspended grown env clears its marker"
fresh u5; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g TEST_DESTROY=1 TEST_SUSPEND=1
elrun repo grow
say "grow: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "grow added g2 and succeeded" bash -c '[ "$0" = 0 ] && grep -q "added g2" <<<"$1"' "$RC" "$OUT"
check "g2 was suspended after it was created" before 'create g2' 'suspend g2'
check "g2 has a marker" susp g2
elrun repo shrink
say "shrink: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "shrink destroyed the suspended g2" bash -c 'grep -q "removed g2" <<<"$0" && ! grep -qx g2 "$1/envs"' "$OUT" "$LD"
check "g2's marker is gone" nosusp g2
check "base keeps its marker" susp base

echo "U6 a held pool lock skips the pass"
fresh u6; export TEST_ENVS="a b" TEST_SUSPEND=1
(flock "$LD/grow.lock" sleep 1.5) & lk=$!
sleep 0.4
elrun repo suspend
say "pool lock held: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "the pass refused and said why" bash -c '[ "$0" = 2 ] && grep -q "a grow or shrink is running" <<<"$1"' "$RC" "$OUT"
check "no hook ran and no marker was written" bash -c '[ ! -s "$0" ] && [ -z "$(ls "$1"/*.suspended 2>/dev/null)" ]' "$TEST_LOG" "$ED"
wait "$lk"
elrun repo suspend
check "the pass works once the lock is free" bash -c '[ -e "$0/a.suspended" ] && [ -e "$0/b.suspended" ]' "$ED"

echo "U7 without envpool_suspend nothing happens"
fresh u7; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g
elrun repo grow
check "grow works and writes no marker" bash -c '[ "$0" = 0 ] && [ -z "$(ls "$1"/*.suspended 2>/dev/null)" ]' "$RC" "$ED"
acq "$T/repo"; settle
elrun repo suspend
say "manual suspend: rc=$RC out=[$OUT]"
check "no marker, no hook call" bash -c '[ -z "$(ls "$0"/*.suspended 2>/dev/null)" ] && ! grep -q suspend "$1"' "$ED" "$TEST_LOG"
check "the manual command says what is missing" bash -c '[ "$0" = 2 ] && grep -q "needs envpool_suspend" <<<"$1"' "$RC" "$OUT"
check "grow.log has no suspend output" bash -c '! grep -qs suspend "$0/grow.log"' "$LD"

echo "U8 a failed suspend leaves no marker; the pass skips marked envs and retries the rest"
fresh u8; export TEST_ENVS="a b c" TEST_SUSPEND=1 TEST_SUSPEND_FAIL=b
elrun repo suspend
say "rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "failure is logged and the pass continues" bash -c 'grep -q "suspending b failed" <<<"$0" && [ -e "$1/a.suspended" ] && [ -e "$1/c.suspended" ]' "$OUT" "$ED"
check "b has no marker" nosusp b
unset TEST_SUSPEND_FAIL
elrun repo suspend
check "the next pass suspends b" susp b
check "a and c were not suspended twice" bash -c '[ "$(grep -c "^suspend a$" "$0")" = 1 ] && [ "$(grep -c "^suspend c$" "$0")" = 1 ]' "$TEST_LOG"

echo "U9 the hook runs with the lock fds closed"
fresh u9; export TEST_ENVS="a b" TEST_SUSPEND=1 TEST_LEAK=$T/leak
elrun repo suspend
say "leaked pids: $(tr '\n' ' ' <"$TEST_LEAK")"
check "the hook's background children are running" leaks_alive
check "no leaked child holds a lock file" leaks_lockfree
check "pool lock and both lease locks are free after the pass" bash -c 'flock -n "$0/grow.lock" true' "$LD"
check "a and b are free" bash -c 'flock -n "$0/a.lock" true && flock -n "$0/b.lock" true' "$ED"
kill_leaks

echo "U10 the detached job shrinks first, then suspends"
fresh u10; export TEST_ENVS="a b" TEST_MAX=4 TEST_PREFIX=g TEST_DESTROY=1 TEST_SUSPEND=1
register g3
acq "$T/repo"; settle
say "OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "g3 was destroyed, then b suspended" before 'destroy g3' 'suspend b'
check "b has a marker, a does not" bash -c '[ -e "$0/b.suspended" ] && [ ! -e "$0/a.suspended" ]' "$ED"

summary
