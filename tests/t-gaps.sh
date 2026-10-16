#!/usr/bin/env bash
# Tests for creating missing ENVS names, an empty ENVS, one lease per pane, events log trimming and urgent acquires.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

# The queue polls every 5 seconds; this sleep shortens only that one, so the waiters below take turns quickly.
real_sleep=$(command -v sleep)
cat >"$SCR/bin/sleep" <<EOF
#!/bin/sh
[ "\$1" = 5 ] && set -- 0.3
exec $real_sleep "\$@"
EOF
chmod +x "$SCR/bin/sleep"

ev() { cat "$LD/events.log" 2>/dev/null; }
evhas() { ev | grep -qE -- "$1"; }
evn() { ev | grep -cE -- "$1" || true; }
# bg NAME DIR PANE [args]: acquire in the background; the result lands in $T/NAME.out, .err and .rc.
bg() { local n=$1 d=$2 p=$3; shift 3; (cd "$d" && HERDR_PANE_ID=$p "$EL" acquire "$@" >"$T/$n.out" 2>"$T/$n.err"; echo $? >"$T/$n.rc") & }
# acq_as PANE DIR [args]: acquire from a pane that already exists. Sets OUT, ERR and RC.
acq_as() { local p=$1 d=$2; shift 2; OUT=$(cd "$d" && HERDR_PANE_ID=$p "$EL" acquire "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
waited() { for _ in $(seq 100); do [ -e "$T/$1.rc" ] && return 0; sleep 0.1; done; return 1; }
leased_n() { for _ in $(seq 100); do [ "$(evn ' leased ')" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }

echo "G1 a name in ENVS that does not exist is created on the first acquire"
fresh g1; export TEST_ENVS=e1 TEST_DISK=$T/disk
acq "$T/repo" --wait 30
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")]; events: $(ev | grep -c ' created ') created"
check "acquire leased e1" [ "$OUT" = e1 ]
check "envpool_create ran once, before reset and attach" bash -c '[ "$(cat "$0")" = "$(printf "create e1\nreset e1\nattach e1")" ]' "$TEST_LOG"
check "the creation is logged" evhas ' created e1$'
check "the env exists now" [ -e "$T/disk/e1" ]
idle "$PANE"; wait_free e1
: >"$TEST_LOG"
acq "$T/repo" --wait 30
check "the next acquire does not create it again" nolog '^create'
idle "$PANE"
echo "  -- without --wait nothing is created"
fresh g1b; export TEST_ENVS=e1 TEST_DISK=$T/disk
acq "$T/repo"
check "acquire gives up with 75 and creates nothing" bash -c '[ "$0" = 75 ] && [ ! -s "$1" ] && [ ! -e "$2/e1" ]' "$RC" "$TEST_LOG" "$T/disk"
echo "  -- an env that already exists is not created"
fresh g1c; export TEST_ENVS=e1 TEST_DISK=$T/disk; touch "$T/disk/e1"
acq "$T/repo"
check "e1 is leased and envpool_create did not run" bash -c '[ "$0" = e1 ] && ! grep -q "^create" "$1"' "$OUT" "$TEST_LOG"
idle "$PANE"
echo "  -- a free existing env wins over creating a missing one"
fresh g1e; export TEST_ENVS="e1 e2" TEST_DISK=$T/disk; touch "$T/disk/e2"
wt a
acq "$T/repo" --wait 30
check "e2 is leased and nothing was created, although e1 comes first in ENVS" bash -c '[ "$0" = e2 ] && ! grep -q "^create" "$1"' "$OUT" "$TEST_LOG"
acq "$T/a" --wait 30
say "e2 busy: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "with e2 busy the missing e1 is created and leased" bash -c '[ "$0" = e1 ] && [ "$(grep -c "^create e1" "$1")" = 1 ]' "$OUT" "$TEST_LOG"
idle_all
echo "  -- a failing create leaves the env unusable and runs once per acquire"
fresh g1d; export TEST_ENVS=e1 TEST_DISK=$T/disk TEST_CFAIL=1
acq "$T/repo" --wait 2
say "rc=$RC err=[$(echo "$ERR" | tr '\n' ';')] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "acquire exits 75" [ "$RC" = 75 ]
check "create ran once and failed" bash -c '[ "$(grep -c "^create e1" "$0")" = 1 ] && grep -qE " create-failed e1 exit=1$" "$1/events.log"' "$TEST_LOG" "$LD"
check "no created line, no reset or attach, e1 free" bash -c '! grep -q " created " "$0/events.log" && ! grep -qE "^(reset|attach)" "$1"' "$LD" "$TEST_LOG"
check "e1 free" free e1
unset TEST_CFAIL
acq "$T/repo" --wait 30
check "the next acquire creates it" [ "$OUT" = e1 ]
idle "$PANE"

echo "G1f status shows a name that does not exist yet as not created"
fresh g1f; export TEST_ENVS="e1 e2" TEST_DISK=$T/disk; touch "$T/disk/e2"
elrun repo status
say "status: $(echo "$OUT" | tr '\n' ';')"
check "e1 is not created, e2 is free, and only e2 counts as free" bash -c 'grep -qx "e1  not created" <<<"$0" && grep -qx "e2  free" <<<"$0" && grep -q "^0/2 in use, 1 free" <<<"$0"' "$OUT"
acq "$T/repo" --wait 30
elrun repo status
check "e2 held, e1 still not created, no free env" bash -c 'grep -qx "e1  not created" <<<"$0" && grep -q "^e2  held by " <<<"$0" && grep -q "^1/2 in use, 0 free" <<<"$0"' "$OUT"
wt a
acq "$T/a" --wait 30
elrun repo status
check "once created, e1 is a normal env again" bash -c 'grep -q "^e1  held by " <<<"$0" && ! grep -q "not created" <<<"$0"' "$OUT"
idle_all

echo "G2 acquires that race for missing envs create each env once"
fresh g2; export TEST_ENVS="e1 e2" TEST_DISK=$T/disk TEST_CSLEEP=2
wt u
bg w "$T/repo" pw --wait 30
sleep 0.7
bg u "$T/u" pu --urgent --wait 30
sleep 1
say "mid-creation: queue=[$(cd "$T/repo" && "$EL" status | grep -c '^queued')] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "while e1 is created the urgent head does not create e2 (the pool lock is held)" bash -c '[ "$(cat "$0")" = "create e1" ]' "$TEST_LOG"
waited w; waited u
say "w: rc=$(cat "$T/w.rc") out=$(cat "$T/w.out"); u: rc=$(cat "$T/u.rc") out=$(cat "$T/u.out"); log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "both leased, the first waiter e1 and the other e2" bash -c '[ "$(cat "$0")" = e1 ] && [ "$(cat "$1")" = e2 ] && [ "$(cat "$2")$(cat "$3")" = 00 ]' "$T/w.out" "$T/u.out" "$T/w.rc" "$T/u.rc"
check "each env was created once" bash -c '[ "$(grep -c "^create e1" "$0")" = 1 ] && [ "$(grep -c "^create e2" "$0")" = 1 ]' "$TEST_LOG"
check "one created line each" bash -c '[ "$(grep -c " created e1$" "$0/events.log")" = 1 ] && [ "$(grep -c " created e2$" "$0/events.log")" = 1 ]' "$LD"
idle pw; idle pu

echo "G3 an empty ENVS grows the pool from zero"
fresh g3; export TEST_ENVS='' TEST_MAX=3 TEST_PREFIX=g
elrun repo status
say "status: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "an empty pool that can grow is accepted" bash -c '[ "$0" = 0 ] && grep -q "^0/0 in use, 0 free" <<<"$1"' "$RC" "$OUT"
check "status prints no blank line for an empty pool" bash -c '! grep -q "^$" <<<"$0"' "$OUT"
acq "$T/repo"
check "without --wait acquire does not grow and exits 75" [ "$RC" = 75 ]
acq "$T/repo" --wait 30
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")] envs=[$(envs_now)]"
check "acquire waited for g2 and leased it" [ "$OUT" = g2 ]
check "g2 was created once and registered" bash -c '[ "$(grep -c "^create" "$0")" = 1 ]' "$TEST_LOG"
check "grown line and envs file" bash -c 'grep -qE " grown g2$" "$0/events.log" && grep -qx g2 "$0/envs"' "$LD"
check "reset and attach ran for g2" bash -c 'grep -qx "reset g2" "$0" && grep -qx "attach g2" "$0"' "$TEST_LOG"
idle "$PANE"
echo "  -- an empty ENVS that cannot grow is still an error"
fresh g3b; export TEST_ENVS='' TEST_MAX=0
elrun repo status
check "ENVPOOL_MAX=0 exits 1 with the old message" bash -c '[ "$0" = 1 ] && grep -q "sets no ENVS" <<<"$1"' "$RC" "$OUT"
fresh g3c; export TEST_ENVS=''
elrun repo status
check "no ENVPOOL_MAX exits 1 with the old message" bash -c '[ "$0" = 1 ] && grep -q "sets no ENVS" <<<"$1"' "$RC" "$OUT"

echo "G4 a pane holds one lease: acquire from another worktree releases the old one"
fresh g4; export TEST_ENVS="e1 e2"
wt a; wt b; wt c
acq "$T/a"; P=$PANE; ha=$(holder_pid e1)
check "setup: a holds e1" bash -c '[ "$0" = e1 ]' "$OUT"
acq "$T/c"; hc=$(holder_pid e2)
check "setup: c holds e2 from another pane" [ "$OUT" = e2 ]
acq_as "$P" "$T/b" --wait 0
say "b: OUT=[$OUT] rc=$RC; log:"; ev | sed 's/^/    /'
check "b leased e1 with --wait 0, so the lock was already free" bash -c '[ "$0" = e1 ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "exactly one released line, for a, naming the move to b" bash -c '[ "$(grep -c " released " "$0/events.log")" = 1 ] && grep -qE " released e1 a pane $1 \(moved to b\)$" "$0/events.log"' "$LD" "$P"
check "a's holder is gone" bash -c '! kill -0 "$0" 2>/dev/null' "$ha"
check "e1 is held by b's new holder" fd9_is "$(holder_pid e1)" e1
check "a no longer has a lease, b does" bash -c '! (cd "$0/a" && "$1" env >/dev/null) && [ "$(cd "$0/b" && "$1" env)" = e1 ]' "$T" "$EL"
check "c's lease on e2 is untouched" bash -c 'kill -0 "$0" && [ "$(readlink /proc/$0/fd/9)" = "$1/e2.lock" ]' "$hc" "$ED"
: >"$LD/events.log"
acq_as "$P" "$T/b"
check "acquire from b again reuses its lease and releases nothing" bash -c '[ "$0" = e1 ] && ! grep -q " released " "$1/events.log" && grep -qE " reused e1 b " "$1/events.log"' "$OUT" "$LD"
echo "  -- the same holds when the pool has one env"
fresh g4b
wt a; wt b
acq "$T/a"; P=$PANE
acq_as "$P" "$T/b" --wait 0
check "b takes the only env at once" [ "$OUT" = base ]
check "one released line" [ "$(evn ' released ')" = 1 ]
idle "$P"

echo "G5 the events log keeps its last 5000 lines once it passes 1 MiB"
fresh g5
awk 'BEGIN { for (i = 1; i <= 20000; i++) printf "2026-01-01T00:00:00 filler %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }' >"$LD/events.log"
say "size before: $(stat -c %s "$LD/events.log")"
acq "$T/repo"
say "size after: $(stat -c %s "$LD/events.log") lines: $(wc -l <"$LD/events.log"); first: $(head -n1 "$LD/events.log"); last: $(tail -n1 "$LD/events.log")"
check "5000 lines are left" [ "$(wc -l <"$LD/events.log")" = 5000 ]
check "they are the newest ones: the last filler lines, then this acquire's queued and leased" bash -c 'head -n1 "$0/events.log" | grep -q "filler 15003 " && tail -n2 "$0/events.log" | head -n1 | grep -q " queued " && tail -n1 "$0/events.log" | grep -q " leased base "' "$LD"
check "no temp file is left" bash -c '[ -z "$(find "$0" -name "events.log.*")" ]' "$LD"
idle "$PANE"
echo "  -- a log under the limit is left whole"
fresh g5b
awk 'BEGIN { for (i = 1; i <= 7000; i++) printf "2026-01-01T00:00:00 filler %d\n", i }' >"$LD/events.log"
acq "$T/repo"
check "all 7000 old lines and the two new ones are there" [ "$(wc -l <"$LD/events.log")" = 7002 ]
idle "$PANE"

echo "G6 urgent waiters go ahead of normal ones and keep their order among themselves"
fresh g6; export TEST_ENVS=a
wt n1; wt n2; wt u1; wt u2
acq "$T/repo"; PH=$PANE
bg n1 "$T/n1" pn1 --wait 60; sleep 0.4
bg n2 "$T/n2" pn2 --wait 60; sleep 0.4
bg u1 "$T/u1" pu1 --wait 60 --urgent; sleep 0.4
bg u2 "$T/u2" pu2 --urgent --wait 60; sleep 0.4
st=$(cd "$T/repo" && "$EL" status)
say "status: $(echo "$st" | tr '\n' '|')"
check "the queue lists u1, u2, n1, n2" bash -c 'grep "^queued" <<<"$0" | sed -E "s/.*\/([a-z0-9]+) \(.*/\1/" | tr "\n" " " | grep -qx "u1 u2 n1 n2 "' "$st"
check "queued lines say urgent for the urgent waiters only" bash -c '[ "$(grep -cE " queued u[12] pane pu[12] urgent$" "$0/events.log")" = 2 ] && [ "$(grep -cE " queued n[12] pane pn[12]$" "$0/events.log")" = 2 ]' "$LD"
idle "$PH"
for k in 2 3 4 5; do
	leased_n "$k" || break
	case $k in 2) idle pu1 ;; 3) idle pu2 ;; 4) idle pn1 ;; esac
done
for n in n1 n2 u1 u2; do waited $n; done
order=$(ev | awk '$2 == "leased" {print $4}' | tr '\n' ' ')
say "lease order: $order"
check "leases went to the holder, u1, u2, n1, n2 in that order" [ "$order" = "main u1 u2 n1 n2 " ]
idle pn2

echo "G7 a missing .envpool points the agent at the README"
fresh g7; rm "$T/repo/.envpool"
elrun repo status
say "rc=$RC out=[$OUT]"
check "exit 1 with the worktree named and the hint" bash -c '[ "$0" = 1 ] && grep -q "no .envpool in $1/repo or the main checkout; ask your agent to set up a pool (see README)" <<<"$2"' "$RC" "$T" "$OUT"

summary
