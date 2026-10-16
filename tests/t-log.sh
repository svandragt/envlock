#!/usr/bin/env bash
# Tests for the events log, the holder that runs the wait as a child, and the SIGPIPE guard in acquire.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

ev() { cat "$LD/events.log" 2>/dev/null; }
evn() { ev | grep -c -- "$1" || true; }
evhas() { ev | grep -qE -- "$1"; }
TS='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} '
lock_on_holder_only() { local wp; wp=$(wait_pid "$2"); [ -n "$wp" ] && fd9_is "$1" base && ! fd9_is "$wp" base; }

echo "L1 queued and leased lines carry timestamp, branch, pane, need/want pairs and the holder pid"
fresh l1; withattrs; export TEST_ENVS="a b"
setattrs a wp=6.9; setattrs b wp=7.1
wt 1295-app-store-redirect
acq "$T/1295-app-store-redirect" --need wp=7.1 --want php=8.4
say "OUT=[$OUT] log:"; ev | sed 's/^/    /'
hp=$(holder_pid b)
check "acquire leased b" [ "$OUT" = b ]
check "queued line: timestamp, event, branch, pane, need and want" evhas "$TS"'queued 1295-app-store-redirect pane '"$PANE"' need=wp=7.1 want=php=8.4$'
check "leased line has env, branch, pane and the holder pid" evhas "$TS"'leased b 1295-app-store-redirect pane '"$PANE"' pid '"$hp"'$'
check "queued comes before leased" bash -c 'q=$(grep -n " queued " "$0" | cut -d: -f1); l=$(grep -n " leased " "$0" | cut -d: -f1); [ "$q" -lt "$l" ]' "$LD/events.log"
check "stderr says preparing, then using" bash -c 'grep -qx "envlock: preparing b" <<<"$0" && grep -qx "envlock: using b" <<<"$0"' "$ERR"
check "preparing comes before using" bash -c 'p=$(grep -n preparing <<<"$0" | cut -d: -f1); u=$(grep -n using <<<"$0" | cut -d: -f1); [ "$p" -lt "$u" ]' "$ERR"
check "no env or hook output moved: stdout is the env name only" [ "$OUT" = b ]

echo "L1b a detached HEAD logs the worktree basename; a unwritable log never fails envlock"
fresh l1b
git -C "$T/repo" worktree add -q --detach "$T/det"
mkdir "$LD/events.log"
acq "$T/det"
check "acquire succeeded although the log cannot be written" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
rmdir "$LD/events.log"
idle "$PANE"; wait_free base
acq "$T/det"
say "log:"; ev | sed 's/^/    /'
check "queued line names the worktree directory" evhas ' queued det pane '
check "leased line names the worktree directory" evhas ' leased base det pane '

echo "L2 reuse logs reused and nothing else"
fresh l2
acq "$T/repo"; P1=$PANE
acq "$T/repo"
say "second acquire OUT=[$OUT] log:"; ev | sed 's/^/    /'
check "reused line has env, branch and pane" evhas "$TS"'reused base main pane '"$PANE"'$'
check "one queued and one leased line, no second" bash -c '[ "$(grep -c " queued " "$0")" = 1 ] && [ "$(grep -c " leased " "$0")" = 1 ]' "$LD/events.log"

echo "L3 attach failure: attach-failed with the hook status, no attach record, non-zero exit, lock released"
fresh l3; export TEST_ENVS=base
cat >>"$T/repo/.envpool" <<'EOP'
envpool_attach() { echo "attach $ENVLOCK_ENV" >>"$TEST_LOG"; return 7; }
EOP
acq "$T/repo"
say "OUT=[$OUT] rc=$RC log:"; ev | sed 's/^/    /'
check "exit status is the hook's" [ "$RC" = 7 ]
check "attach-failed line with exit=7" evhas "$TS"'attach-failed base main pane '"$PANE"' exit=7$'
check "no leased line, no released line" bash -c '! grep -qE " (leased|released) " "$0"' "$LD/events.log"
check "no attach record" [ ! -e "$ED/base.attached" ]
check "lock released" free base
check "holder file has no pid" bash -c '! grep -q " pid " "$0"' "$ED/base.holder"
check "no stdout" [ -z "$OUT" ]
check "queue entry removed" bash -c '[ -z "$(ls "$0/queue")" ]' "$LD"
echo "L3b a failing step inside the hook still aborts the hook (set -e applies inside it)"
fresh l3b; export TEST_ENVS=base
cat >>"$T/repo/.envpool" <<'EOP'
envpool_attach() { false; echo "attach reached the end" >>"$TEST_LOG"; }
EOP
acq "$T/repo"
say "rc=$RC log: $(tr '\n' ';' <"$TEST_LOG")"
check "the step after the failing one did not run" nolog 'reached the end'
check "attach-failed logged with exit=1, rc 1" bash -c '[ "$0" = 1 ] && grep -q " attach-failed base main pane .* exit=1$" "$1"' "$RC" "$LD/events.log"

echo "L4 reset failure: reset-failed with the hook status, attach never ran"
fresh l4; export TEST_ENVS=base
cat >>"$T/repo/.envpool" <<'EOP'
envpool_reset() { return 5; }
EOP
acq "$T/repo"
say "rc=$RC log:"; ev | sed 's/^/    /'
check "exit status 5" [ "$RC" = 5 ]
check "reset-failed line with exit=5" evhas "$TS"'reset-failed base main pane '"$PANE"' exit=5$'
check "attach did not run, lock released" bash -c '! grep -q "^attach" "$0"' "$TEST_LOG"
check "lock released" free base

echo "L5 configure failure: configure-failed with the hook status, exit 1, lock released"
fresh l5; withattrs; export TEST_ENVS=a TEST_CONF=1 TEST_CONF_FAIL=1
setattrs a wp=6.9
acq "$T/repo" --need wp=7.1
say "rc=$RC log:"; ev | sed 's/^/    /'
check "exit 1" [ "$RC" = 1 ]
check "configure-failed line with env, branch, pane, exit=1" evhas "$TS"'configure-failed a main pane '"$PANE"' exit=1$'
check "no leased line" bash -c '! grep -q " leased " "$0"' "$LD/events.log"
check "lock released, no attach record" bash -c 'flock -n "$0/a.lock" true && [ ! -e "$0/a.attached" ]' "$ED"

echo "L6 timeout logs exit 75 with the asked-for pairs"
fresh l6; withattrs; export TEST_ENVS=a
setattrs a wp=6.9
acq "$T/repo"; P1=$PANE
wt w2
acq "$T/w2" --wait 1 --want wp=6.9
say "rc=$RC err=[$ERR] log:"; ev | sed 's/^/    /'
check "exit 75" [ "$RC" = 75 ]
check "timeout line has branch, pane and the want pair" evhas "$TS"'timeout w2 pane '"$PANE"' want=wp=6.9$'
idle "$P1"

echo "L7 the agent going idle logs exactly one released line; the lock is free afterwards"
fresh l7
acq "$T/repo"; P1=$PANE; hp=$(holder_pid base)
check "holder alive with fd 9, and the wait is running" bash -c 'kill -0 "$0"' "$hp"
check "the wait is running" waits_for "$P1"
check "no released line yet" bash -c '! grep -q " released " "$0"' "$LD/events.log"
idle "$P1"
check "lock freed" wait_free base
sleep 0.3
say "log:"; ev | sed 's/^/    /'
check "exactly one released line" [ "$(evn ' released ')" = 1 ]
check "released line: env, branch, pane, reason" evhas "$TS"'released base main pane '"$P1"' \(idle or done\)$'
check "the holder is gone" bash -c '! kill -0 "$0" 2>/dev/null' "$hp"
check "no wait process left" nowait "$P1"
echo "L7b the lock is held while the wait runs, even though only the holder has fd 9"
acq "$T/repo"; P2=$PANE; hp=$(holder_pid base)
check "base held" held base
check "fd 9 is on the holder, not the wait" lock_on_holder_only "$hp" "$P2"
idle "$P2"; wait_free base
echo "L7c a failing wait logs the failure status as the reason"
mkdir -p "$T/failbin"; printf '#!/bin/sh\nexit 3\n' >"$T/failbin/herdr"; chmod +x "$T/failbin/herdr"
OUT=$(cd "$T/repo" && PATH=$T/failbin:$PATH HERDR_PANE_ID=gone "$EL" acquire 2>/dev/null); RC=$?
wait_free base; sleep 0.3
check "released line says the wait failed with exit 3" evhas ' released base main pane gone \(wait failed, exit=3\)$'

echo "L8 envlock release logs exactly one released line, frees the lock and leaves no wait process"
fresh l8
wt 1216-video-block-validation
acq "$T/1216-video-block-validation"; P1=$PANE; hp=$(holder_pid base)
check "wait running" waits_for "$P1"
elrun 1216-video-block-validation release
say "release: rc=$RC out=[$OUT]"
check "release succeeded and said so" bash -c '[ "$0" = 0 ] && grep -q "released base" <<<"$1"' "$RC" "$OUT"
check "lock freed" wait_free base
sleep 0.5
say "log:"; ev | sed 's/^/    /'
check "exactly one released line" [ "$(evn ' released ')" = 1 ]
check "it names env, branch, pane and the release reason" evhas "$TS"'released base 1216-video-block-validation pane '"$P1"' \(release\)$'
check "the holder is gone" bash -c '! kill -0 "$0" 2>/dev/null' "$hp"
check "no orphaned herdr wait process" nowait "$P1"
elrun 1216-video-block-validation release
check "a second release has no lease to end and logs nothing more" bash -c '[ "$0" = 0 ] && [ "$(grep -c " released " "$1")" = 1 ]' "$RC" "$LD/events.log"

echo "L9 grow, shrink and suspend lines"
fresh l9; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g TEST_DESTROY=1 TEST_SUSPEND=1
elrun repo grow
say "grow rc=$RC; log:"; ev | sed 's/^/    /'
check "grown g2" evhas "$TS"'grown g2$'
check "suspended g2 and base" bash -c 'grep -q " suspended g2$" "$0" && grep -q " suspended base$" "$0"' "$LD/events.log"
elrun repo shrink
check "shrunk g2" evhas "$TS"'shrunk g2$'
fresh l9b; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g TEST_DESTROY=1 TEST_SUSPEND=1 TEST_CFAIL=1
elrun repo grow
check "grow-failed with the hook status" evhas "$TS"'grow-failed g2 exit=1$'
check "no grown line" bash -c '! grep -q " grown " "$0"' "$LD/events.log"
fresh l9c; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g TEST_DESTROY=1 TEST_SUSPEND=1 TEST_FAIL=1 TEST_SUSPEND_FAIL=g2
register g2
elrun repo suspend
check "suspend-failed g2 with exit status" evhas "$TS"'suspend-failed g2 exit=1$'
elrun repo shrink
check "destroy-failed g2 with exit status" evhas "$TS"'destroy-failed g2 exit=1$'
check "no shrunk line" bash -c '! grep -q " shrunk " "$0"' "$LD/events.log"

echo "L10 status ends with the events log path"
fresh l10
elrun repo status
check "last line of status is the path" bash -c '[ "$(tail -n1 <<<"$0")" = "events log: $1/events.log" ]' "$OUT" "$LD"

echo "L11 acquire piped through head -1 never prints using without a live lease, and leaves a consistent state"
fresh l11
cat >>"$T/repo/.envpool" <<'EOP'
# Writes to stderr after the reader has gone.
envpool_attach() { sleep 0.8; echo "attaching $ENVLOCK_ENV" >&2; echo "attach $ENVLOCK_ENV" >>"$TEST_LOG"; }
EOP
PN=$((PN + 1)); PANE=p$PN
set -o pipefail
out=$(cd "$T/repo" && HERDR_PANE_ID=$PANE "$EL" acquire 2>&1 | head -1); rc=$?
set +o pipefail
sleep 1.2
say "head -1 saw [$out] pipeline rc=$rc; log:"; ev | sed 's/^/    /'
check "the one line is preparing, not using" bash -c 'grep -q "preparing" <<<"$0" && ! grep -q "using" <<<"$0"' "$out"
check "the failed write went through the hook-failure path: attach-failed logged" evhas "$TS"'attach-failed base main pane '"$PANE"' exit=1$'
check "no attach record, no leased line, lock free" bash -c '[ ! -e "$0/base.attached" ] && ! grep -q " leased " "$1" && flock -n "$0/base.lock" true' "$ED" "$LD/events.log"
check "the pipeline reported failure (envlock exited non-zero)" [ "$rc" != 0 ]
echo "L11b with a quiet hook the same pipe ends in a live lease, and using only follows a live holder"
fresh l11b
PN=$((PN + 1)); PANE=p$PN
out=$(cd "$T/repo" && HERDR_PANE_ID=$PANE "$EL" acquire 2>&1 | head -3)
say "head -3 saw [$(echo "$out" | tr '\n' ';')]"
check "using is printed and the lease is live" bash -c 'grep -q "using base" <<<"$0"' "$out"
check "lease is live: held, holder pid has fd 9, leased logged" bash -c '[ -n "$1" ]' x "$(holder_pid base)"
check "base is held and found by envlock env" bash -c '! flock -n "$0/base.lock" true && cd "$1/repo" && [ "$("$2" env)" = base ]' "$ED" "$T" "$EL"
check "a leased line exists" evhas ' leased base main pane '
idle "$PANE"

summary
