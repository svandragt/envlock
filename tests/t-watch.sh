#!/usr/bin/env bash
# Tests for acquire --watch, envpool_watch and ENVLOCK_SLOT.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

ev() { cat "$LD/events.log" 2>/dev/null; }
evhas() { ev | grep -qE -- "$1"; }
evn() { ev | grep -cE -- "$1" || true; }
queue_empty() { [ -z "$(ls "$LD/queue")" ]; }
acq_as() { local p=$1 d=$2; shift 2; OUT=$(cd "$d" && HERDR_PANE_ID=$p "$EL" acquire "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
wpid() { awk '{ print $1 }' "$LD/watch/$1.pid" 2>/dev/null; }
# The watcher that env $1's pid file records is $2 and still runs.
same_watcher() { [ "$(wpid "$1")" = "$2" ] && alive "$2"; }
pgid_of() { awk '{ sub(/.*\) /, ""); print $3 }' "/proc/$1/stat"; }
# A watcher lives while its process group has a member.
alive() { kill -0 -- "-$1" 2>/dev/null; }
gone() { ! alive "$1" && [ -z "$(pgrep -g "$1")" ]; }
wait_gone() { for _ in $(seq 50); do gone "$1" && return 0; sleep 0.1; done; return 1; }
wait_log() { for _ in $(seq 50); do logged "$1" && return 0; sleep 0.1; done; return 1; }
wait_nopidfile() { for _ in $(seq 50); do [ ! -e "$LD/watch/$1.pid" ] && return 0; sleep 0.1; done; return 1; }
no_lock_fd() { local p; for p in $(pgrep -g "$1"); do ! readlink "/proc/$p/fd/"* 2>/dev/null | grep -q '\.lock' || return 1; done; }
slot_of() { cat "$ED/$1.slot" 2>/dev/null; }
# A grow that acquire starts in the background; wait for it to add $1 and release the pool lock.
wait_grown() { for _ in $(seq 100); do envs_has "$1" && flock -n "$LD/grow.lock" true 2>/dev/null && return 0; sleep 0.1; done; return 1; }

echo "W1 --watch without envpool_watch exits 1 before queueing"
fresh w1
acq "$T/repo" --watch
say "OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "exits 1 and names the missing hook" bash -c '[ "$0" = 1 ] && grep -q "envpool_watch" <<<"$1"' "$RC" "$ERR"
check "no queued line" bash -c '! grep -q queued "$0/events.log" 2>/dev/null' "$LD"
check "no queue file" queue_empty
check "no hook ran" [ ! -s "$TEST_LOG" ]

echo "W2 a plain acquire starts no watcher, even when the hook is defined"
fresh w2; export TEST_WATCH=600
acq "$T/repo"; p=$PANE
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "stdout is exactly the env name" [ "$OUT" = base ]
check "the hook did not run" nolog '^watch'
check "no watch line in the events log" bash -c '! grep -q " watch " "$0/events.log"' "$LD"
check "no pid file" [ ! -e "$LD/watch/base.pid" ]
idle "$p"

echo "W3 --watch on a new lease starts a watcher in its own process group, with no lock fd"
fresh w3; export TEST_WATCH=600
acq "$T/repo" --watch; p=$PANE; wp=$(wpid base)
wait_log "watch base 1"
say "OUT=[$OUT] rc=$RC pid=$wp pgid=$(pgid_of "${wp:-0}" 2>/dev/null) log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "stdout is exactly the env name" [ "$OUT" = base ]
check "the queued line carries watch" evhas ' queued main pane '"$p"' watch$'
check "the hook saw the env and slot 1" logged "watch base 1"
check "the watcher is alive" alive "$wp"
check "its pgid equals its pid" [ "$(pgid_of "$wp")" = "$wp" ]
check "no process of the group holds an envlock lock file" no_lock_fd "$wp"
check "stdin is /dev/null and stdout is the env's log" bash -c '[ "$(readlink /proc/$0/fd/0)" = /dev/null ] && [ "$(readlink /proc/$0/fd/1)" = "$1/watch/base.log" ]' "$wp" "$LD"
check "the watch line names the pid and comes before leased" bash -c 'grep -qE " watch base main pane $1 pid $2\$" "$0/events.log" && [ "$(grep -n " watch base " "$0/events.log" | cut -d: -f1)" -lt "$(grep -n " leased " "$0/events.log" | cut -d: -f1)" ]' "$LD" "$p" "$wp"
check "the watcher is not in the holder's process group" [ "$(pgid_of "$wp")" != "$(pgid_of "$(holder_pid base)")" ]
echo "  -- the agent goes idle"
idle "$p"; wait_free base; wait_gone "$wp"; wait_nopidfile base
say "log: $(ev | grep -E ' (watch-stopped|released) ' | tr '\n' ';')"
check "the watcher and its sleep are gone" gone "$wp"
check "watch-stopped is logged once with the pid" bash -c '[ "$(grep -c " watch-stopped " "$0/events.log")" = 1 ] && grep -qE " watch-stopped base main pane $1 pid $2\$" "$0/events.log"' "$LD" "$p" "$wp"
check "exactly one released line" bash -c '[ "$(grep -c " released " "$0/events.log")" = 1 ]' "$LD"
check "the pid file is gone" [ ! -e "$LD/watch/base.pid" ]

echo "W4 envlock release stops the watcher"
fresh w4; export TEST_WATCH=600
acq "$T/repo" --watch; p=$PANE; wp=$(wpid base)
elrun repo release; wait_free base; wait_gone "$wp"
say "release: rc=$RC out=[$OUT] log: $(ev | grep -E ' (watch-stopped|released) ' | tr '\n' ';')"
check "the watcher is gone" gone "$wp"
check "watch-stopped is logged" evhas ' watch-stopped base main pane '"$p"' pid '"$wp"'$'
check "release logs its own released line, once" bash -c '[ "$(grep -c " released " "$0/events.log")" = 1 ] && grep -q " released base main pane $1 (release)" "$0/events.log"' "$LD" "$p"

echo "W5 a pane that moves to another worktree loses its watcher"
fresh w5; export TEST_ENVS="e1 e2" TEST_WATCH=600
wt a; wt b
acq "$T/a" --watch; p=$PANE; wp=$(wpid e1)
acq_as "$p" "$T/b" --wait 0 --watch; wp2=$(wpid e1)
say "b: OUT=[$OUT] rc=$RC old=$wp new=$wp2 log: $(ev | grep -E ' (watch|watch-stopped|released) ' | tr '\n' ';')"
check "b leased e1" bash -c '[ "$0" = e1 ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "the old watcher is gone" gone "$wp"
check "watch-stopped names a's lease" evhas ' watch-stopped e1 a pane '"$p"' pid '"$wp"'$'
check "one released line, for the move" bash -c '[ "$(grep -c " released " "$0/events.log")" = 1 ] && grep -q " released e1 a pane $1 (moved to b)" "$0/events.log"' "$LD" "$p"
check "b has a new watcher in its own group" bash -c '[ "$0" != "$1" ] && kill -0 -- "-$1"' "$wp" "$wp2"
idle "$p"; wait_gone "$wp2"

echo "W6 reuse with --watch adds a watcher to a lease that has none, and the holder stops it"
fresh w6; export TEST_WATCH=600
acq "$T/repo"; p=$PANE; hp=$(holder_pid base)
check "setup: no watcher yet" [ ! -e "$LD/watch/base.pid" ]
acq "$T/repo" --watch; wp=$(wpid base)
wait_log "watch base 1"
say "reuse: OUT=[$OUT] rc=$RC pid=$wp holder before=$hp after=$(holder_pid base)"
check "stdout is exactly the env name, exit 0" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "a watcher started" alive "$wp"
check "the holder is the same process" [ "$(holder_pid base)" = "$hp" ]
check "reused and watch are both logged" bash -c 'grep -q " reused base " "$0/events.log" && [ "$(grep -c " watch base " "$0/events.log")" = 1 ]' "$LD"
idle "$p"; wait_gone "$wp"; wait_nopidfile base
check "the holder stopped it at lease end" bash -c 'grep -qE " watch-stopped base main pane $1 pid $2\$" "$0/events.log"' "$LD" "$p" "$wp"

echo "W7 reuse with --watch while one runs starts no second watcher; a plain reuse leaves it running"
fresh w7; export TEST_WATCH=600
acq "$T/repo" --watch; p=$PANE; wp=$(wpid base); wait_log "watch base 1"
acq "$T/repo" --watch
say "second: OUT=[$OUT] rc=$RC pid file=$(wpid base) log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "stdout is the env name" [ "$OUT" = base ]
check "the same watcher is still alive" same_watcher base "$wp"
check "the hook ran once and one watch line was logged" bash -c '[ "$(grep -c "^watch" "$1")" = 1 ] && [ "$(grep -c " watch base " "$0/events.log")" = 1 ]' "$LD" "$TEST_LOG"
acq "$T/repo"
check "a plain reuse leaves the watcher running" same_watcher base "$wp"
echo "  -- a watcher that died is replaced, with the same slot"
kill -- "-$wp"; wait_gone "$wp"
acq "$T/repo" --watch; wp2=$(wpid base); wait_log "watch base 1"
check "a new watcher runs under a new pid" bash -c '[ "$0" != "$1" ] && kill -0 -- "-$1"' "$wp" "$wp2"
check "the hook saw the same slot again" bash -c '[ "$(grep -c "^watch base 1$" "$0")" = 2 ]' "$TEST_LOG"
idle "$p"; wait_gone "$wp2"

echo "W8 a watcher that exits at once does not fail the acquire"
fresh w8; export TEST_WATCH=0
acq "$T/repo" --watch; p=$PANE
say "OUT=[$OUT] rc=$RC stderr=[$ERR]"
check "exit 0 and stdout is the env name" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "the watch line is logged and the lease is held" bash -c 'grep -q " watch base " "$0/events.log"' "$LD"
check "base is held" held base
idle "$p"; wait_free base; wait_nopidfile base
check "no watch-stopped line, because nothing was left to kill" bash -c '! grep -q " watch-stopped " "$0/events.log"' "$LD"

echo "W9 slots: distinct while leased, stable across leases, freed by destroy"
fresh w9; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g TEST_DESTROY=1 TEST_WATCH=600
wt a; wt b; wt c
acq "$T/a" --watch; pa=$PANE; oa=$OUT; wait_grown g2
acq "$T/b" --watch; pb=$PANE; ob=$OUT; wait_grown g3
wait_log "watch g2 2"
say "slots: base=$(slot_of base) g2=$(slot_of g2) log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "a leased base and b leased g2" bash -c '[ "$0" = base ] && [ "$1" = g2 ]' "$oa" "$ob"
check "two envs leased at once have different slots" bash -c '[ "$0" = 1 ] && [ "$1" = 2 ]' "$(slot_of base)" "$(slot_of g2)"
check "each hook saw its env's slot" bash -c 'grep -qx "watch base 1" "$0" && grep -qx "watch g2 2" "$0"' "$TEST_LOG"
idle "$pa"; wait_free base
acq "$T/a" --watch; wait_log "watch base 1"; settle
check "a gets base back with the same slot" bash -c '[ "$0" = base ] && [ "$(cat "$1/base.slot")" = 1 ]' "$OUT" "$ED"
check "the hook saw slot 1 again" bash -c '[ "$(grep -c "^watch base 1$" "$0")" = 2 ]' "$TEST_LOG"
check "g3, which no one leased, has no slot" [ ! -e "$ED/g3.slot" ]
idle "$pb"; wait_free g2; rmwt b
elrun repo shrink
say "shrink: rc=$RC out=[$(echo "$OUT" | tr '\n' ';')]"
check "shrink destroyed g2 and deleted its slot file" bash -c 'grep -qx "destroy g2" "$0" && [ ! -e "$1/g2.slot" ]' "$TEST_LOG" "$ED"
check "base keeps its slot" [ "$(slot_of base)" = 1 ]
acq "$T/c" --watch; wait_log "watch g3 2"
check "the next new env takes the lowest free number" bash -c '[ "$0" = g3 ] && [ "$(cat "$1/g3.slot")" = 2 ]' "$OUT" "$ED"
wait_grown g4

echo "W10 a pid file that names an unrelated live process is not signalled, and the new lease proceeds"
fresh w10; export TEST_WATCH=600
mkdir -p "$LD/watch"; sleep 7773 & sp=$!
echo "$sp 1" >"$LD/watch/base.pid"
acq "$T/repo"; p=$PANE
say "OUT=[$OUT] rc=$RC unrelated pid=$sp"
check "the lease is granted" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "the unrelated process is still alive" kill -0 "$sp"
check "nothing was stopped" bash -c '! grep -q " watch-stopped " "$0/events.log"' "$LD"
check "the stale pid file is gone" [ ! -e "$LD/watch/base.pid" ]
echo "  -- an old-format file with only a pid is not trusted either"
idle "$p"; wait_free base
echo "$sp" >"$LD/watch/base.pid"
acq "$T/repo"; p=$PANE
check "the lease is granted and the process lives" bash -c '[ "$0" = base ] && kill -0 "$1"' "$OUT" "$sp"
kill "$sp"; idle "$p"

echo "W11 a watcher whose holder was killed with SIGKILL is stopped by the next new lease"
fresh w11; export TEST_WATCH=600
acq "$T/repo" --watch; p=$PANE; wp=$(wpid base); hp=$(holder_pid base)
wait_log "watch base 1"
kill -9 "$hp"; wait_free base
check "the holder is gone and the watcher outlived it" alive "$wp"
acq "$T/repo"; p2=$PANE
wait_gone "$wp"
say "OUT=[$OUT] rc=$RC log: $(ev | grep -E ' (watch|watch-stopped|leased) ' | tr '\n' ';')"
check "the new lease is granted" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
check "the old watcher is gone" gone "$wp"
check "watch-stopped is logged as stale, with the pid" evhas ' watch-stopped base main pane '"$p2"' pid '"$wp"' \(stale\)$'
check "the pid file is gone, and the plain lease started no watcher" [ ! -e "$LD/watch/base.pid" ]
idle "$p"; idle "$p2"

summary
