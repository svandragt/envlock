#!/usr/bin/env bash
# Tests for ENVPOOL_MIN: the pool's minimum versions for acquire, --need and --want, and status.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

export ENVLOCK_POLL=0.3

# The dummy pool inherits ENVPOOL_MIN from the environment. mfresh clears it first, because fresh runs status.
mfresh() { unset ENVPOOL_MIN; fresh "$@"; }
logged_all() { [ "$(tr '\n' , <"$TEST_LOG")" = "$1," ]; }
# min_case NAME ATTR MINIMUM EXPECTED: one env on ATTR under ENVPOOL_MIN=MINIMUM. EXPECTED is the configure line, or none.
min_case() {
	mfresh "$1"; withattrs; export TEST_ENVS=e1 TEST_CONF=1 ENVPOOL_MIN=$3
	setattrs e1 "$2"
	acq "$T/repo"; idle "$PANE"
	say "$2 under minimum $3: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
	if [ "$4" = none ]; then
		check "$2 meets $3: leased without configure" bash -c '[ "$0" = e1 ] && ! grep -q "^configure" "$1"' "$OUT" "$TEST_LOG"
	else
		check "$2 is below $3: configure ran as '$4'" bash -c '[ "$0" = e1 ] && head -1 "$1" | grep -qx "$2"' "$OUT" "$TEST_LOG" "$4"
	fi
}

echo "M1 an env below the minimum is configured to it before reset and attach"
mfresh m1; withattrs; export TEST_ENVS=e1 TEST_CONF=1 ENVPOOL_MIN="wp=7.1"
setattrs e1 wp=6.9
acq "$T/repo"
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")] attrs=[$(attrs_of e1)]"
check "e1 is leased" [ "$OUT" = e1 ]
check "configure wp=7.1 ran first, then reset and attach" logged_all "configure e1 wp=7.1,reset e1,attach e1"
check "e1 describes wp=7.1 now" grep -qx wp=7.1 "$TEST_ATTRS/e1"
idle "$PANE"

echo "M2 an env above the minimum is leased without configure"
min_case m2 wp=7.2 "wp=7.1" none

echo "M3 versions compare numerically, field by field"
min_case m3a wp=7.10 "wp=7.9" none
min_case m3b wp=7.1.4 "wp=7.1" none
min_case m3c wp=7.9 "wp=7.10" "configure e1 wp=7.10"
min_case m3d wp=7.1 "wp=7.1.4" "configure e1 wp=7.1.4"
min_case m3e wp=beta "wp=7.1" "configure e1 wp=7.1"
min_case m3f php=8.4 "wp=7.1" "configure e1 wp=7.1"
min_case m3g wp=7.1 "wp=7.1.0" none
min_case m3h wp=7.1.0 "wp=7.1" none

echo "M4 an env that meets the minimum wins over one that needs configuring"
mfresh m4; withattrs; export TEST_ENVS="e1 e2" TEST_CONF=1 ENVPOOL_MIN="wp=7.1"
setattrs e1 wp=6.9; setattrs e2 wp=7.1
acq "$T/repo"
say "e1 below, e2 at the minimum: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "e2 is leased, although e1 comes first in ENVS" [ "$OUT" = e2 ]
check "nothing was configured" nolog '^configure'
idle "$PANE"

echo "M5 --need and --want below the minimum fail before queuing"
mfresh m5; withattrs; export TEST_ENVS=e1 TEST_CONF=1 ENVPOOL_MIN="wp=7.1"
setattrs e1 wp=7.1
for opt in --need --want; do
	acq "$T/repo" "$opt" wp=6.9
	say "$opt wp=6.9: OUT=[$OUT] rc=$RC stderr=[$ERR]"
	check "$opt: exits non-zero and names the minimum" bash -c '[ "$0" != 0 ] && [ "$1" = "envlock: $2 wp=6.9 is older than ENVPOOL_MIN wp=7.1" ]' "$RC" "$ERR" "$opt"
	check "$opt: nothing leased, no hook ran, nothing queued" bash -c '[ -z "$0" ] && [ ! -s "$1" ] && ! grep -q queued "$2/events.log" 2>/dev/null' "$OUT" "$TEST_LOG" "$LD"
done
check "e1 is free" free e1
acq "$T/repo" --need wp=7.1
check "--need at the minimum is accepted" [ "$OUT" = e1 ]
idle "$PANE"; wait_free e1

echo "M6 --need above the minimum configures to the need; other keys are left alone"
mfresh m6a; withattrs; export TEST_ENVS=e1 TEST_CONF=1 ENVPOOL_MIN="wp=7.1"
setattrs e1 wp=6.9
acq "$T/repo" --need wp=7.2
say "OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "configure got wp=7.2, not the minimum" bash -c '[ "$0" = e1 ] && head -1 "$1" | grep -qx "configure e1 wp=7.2"' "$OUT" "$TEST_LOG"
idle "$PANE"
mfresh m6b; withattrs; export TEST_ENVS=e1 TEST_CONF=1 ENVPOOL_MIN="wp=7.1 php=8.2"
setattrs e1 wp=6.9 php=8.4
acq "$T/repo"
say "wp below, php above: log=[$(tr '\n' ';' <"$TEST_LOG")] attrs=[$(attrs_of e1)]"
check "configure got wp only, so php is not lowered to its minimum" bash -c 'head -1 "$0" | grep -qx "configure e1 wp=7.1"' "$TEST_LOG"
idle "$PANE"
mfresh m6c; withattrs; export TEST_ENVS=e1 TEST_CONF=1 ENVPOOL_MIN="wp=7.1 php=8.2"
setattrs e1 wp=6.9 php=8.0
acq "$T/repo" --need wp=7.2
say "wp need, php below: log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "configure got the need and the minimum of the key it does not name" bash -c 'head -1 "$0" | grep -qx "configure e1 wp=7.2 php=8.2"' "$TEST_LOG"
idle "$PANE"

echo "M7 without envpool_configure an env below the minimum is not leased"
mfresh m7a; withattrs; export TEST_ENVS=e1 ENVPOOL_MIN="wp=7.1"
setattrs e1 wp=6.9
acq "$T/repo" --wait 1
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")] stderr=[$ERR]"
check "acquire gives up with 75 and leases nothing" bash -c '[ "$0" = 75 ] && [ -z "$1" ] && [ ! -s "$2" ]' "$RC" "$OUT" "$TEST_LOG"
check "the timeout names the minimum" grep -q "below ENVPOOL_MIN wp=7.1" <<<"$ERR"
check "e1 is free" free e1
mfresh m7b; withattrs; export TEST_ENVS="e1 e2" ENVPOOL_MIN="wp=7.1"
setattrs e1 wp=6.9; setattrs e2 wp=7.2
acq "$T/repo"
check "an env at the minimum is leased instead (e2)" [ "$OUT" = e2 ]
idle "$PANE"

echo "M7c reuse without envpool_configure names only what the env misses"
mfresh m7c; withattrs; export TEST_ENVS=e1
setattrs e1 wp=7.2 php=8.0
acq "$T/repo"; idle "$PANE"
export ENVPOOL_MIN="wp=7.1 php=8.2"
acq "$T/repo"
say "OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "the error names php=8.2" grep -q "php=8.2" <<<"$ERR"
check "the error does not name wp=7.1" bash -c '! grep -q "wp=7.1" <<<"$0"' "$ERR"

echo "M8 ENVPOOL_MIN needs envpool_describe and version pairs"
mfresh m8; export ENVPOOL_MIN="wp=7.1"
elrun repo status
say "no describe hook: rc=$RC out=[$OUT]"
check "status fails and names envpool_describe" bash -c '[ "$0" != 0 ] && grep -q "ENVPOOL_MIN requires envpool_describe" <<<"$1"' "$RC" "$OUT"
mfresh m8b; withattrs; export TEST_ENVS=e1; export ENVPOOL_MIN="wp=latest"
setattrs e1 wp=7.1
elrun repo status
say "non-version minimum: rc=$RC out=[$OUT]"
check "status fails and names the setting" bash -c '[ "$0" != 0 ] && grep -q "ENVPOOL_MIN" <<<"$1"' "$RC" "$OUT"

echo "M9 status marks the env that is below the minimum"
mfresh m9; withattrs; export TEST_ENVS="e1 e2" ENVPOOL_MIN="wp=7.1 php=8.2"
setattrs e1 wp=6.9 php=8.0; setattrs e2 wp=7.2 php=8.4
elrun repo status
say "$OUT"
check "e1 shows each key it is below" grep -qx "e1  free  wp=6.9 php=8.0 (wp below 7.1) (php below 8.2)" <<<"$OUT"
check "e2 shows nothing" grep -qx "e2  free  wp=7.2 php=8.4" <<<"$OUT"

summary
