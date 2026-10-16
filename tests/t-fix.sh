#!/usr/bin/env bash
# Tests for hooks that start background children (they must not inherit a lock fd) and for envpool_info.
# shellcheck disable=SC2016  # check runs its command through bash -c, so $0 and $1 must stay unexpanded here.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$here/lib.sh"

pool_free() { flock -n "$LD/grow.lock" true 2>/dev/null; }

echo "F1 hooks that start background children: grow, then shrink at once"
fresh f1; export TEST_ENVS=base TEST_MAX=3 TEST_PREFIX=g TEST_DESTROY=1 TEST_LEAK=$T/leak
out=$(cd "$T/repo" && "$EL" grow 2>&1); rc=$?
say "grow rc=$rc out=[$(echo "$out" | tr '\n' ';')] leaked pids: $(tr '\n' ' ' <"$TEST_LEAK")"
check "grow succeeded and added g2" bash -c '[ "$0" = 0 ] && grep -q "added g2" <<<"$1"' "$rc" "$out"
check "the hooks' background sleeps are still running" leaks_alive
check "no leaked child holds a lock file" leaks_lockfree
check "pool lock is free right after grow returned" pool_free
out=$(cd "$T/repo" && "$EL" shrink 2>&1); rc=$?
say "shrink rc=$rc out=[$(echo "$out" | tr '\n' ';')]"
check "shrink right after grow is not refused" bash -c '[ "$0" = 0 ] && ! grep -q "grow or shrink is running" <<<"$1"' "$rc" "$out"
check "shrink removed g2" bash -c 'grep -q "removed g2" <<<"$0"' "$out"
check "destroy's leaked children hold no lock file" leaks_lockfree
check "pool lock is free right after shrink returned" pool_free
check "g2's lease lock is free right after shrink returned" free g2
check "the sleeps from destroy are still running" leaks_alive
kill_leaks

echo "F2 hooks that start background children during acquire: the lease ends with the holder"
fresh f2; withattrs; export TEST_ENVS=base TEST_CONF=1 TEST_HEALTHY_RC=0 TEST_LEAK=$T/leak
setattrs base wp=6.9
acq "$T/repo" --need wp=7.1
say "OUT=[$OUT] rc=$RC log=[$(tr '\n' ';' <"$TEST_LOG")] leaked pids: $(tr '\n' ' ' <"$TEST_LEAK")"
check "acquire ran configure, reset and attach" bash -c 'grep -q "^configure base wp=7.1" "$0" && grep -q "^reset base" "$0" && grep -q "^attach base" "$0"' "$TEST_LOG"
check "the leaked sleeps are running" leaks_alive
check "no leaked child holds a lock file" leaks_lockfree
check "base is held by the holder" held base
idle "$PANE"
check "lease is free right after the holder exits, with the sleeps still running" wait_free base
check "sleeps outlived the holder" leaks_alive
kill_leaks; : >"$TEST_LOG"
acq "$T/repo"
say "second lease from the same worktree: OUT=[$OUT] log=[$(tr '\n' ';' <"$TEST_LOG")]"
check "healthy ran this time (the attach record names the worktree)" logged "healthy base"
check "no leaked child holds a lock file" leaks_lockfree
idle "$PANE"
check "lease free again after the holder exits" wait_free base
kill_leaks

echo "F3 envpool_info"
fresh f3; export TEST_INFO=1
acq "$T/repo"
say "new lease: OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')]"
check "stdout carries only the name" [ "$OUT" = base ]
check "stderr carries the hook's output" grep -qx 'https://base.example/?key=1' <<<"$ERR"
check "the hook saw ENVLOCK_ENV and ENVLOCK_WORKTREE" logged "info base $T/repo"
acq "$T/repo"
say "reuse: OUT=[$OUT] rc=$RC stderr=[$(echo "$ERR" | tr '\n' ';')]"
check "reuse: stdout carries only the name" [ "$OUT" = base ]
check "reuse: stderr carries the hook's output" grep -qx 'https://base.example/?key=1' <<<"$ERR"
check "the hook ran on the new lease and on reuse" [ "$(count '^info base')" = 2 ]
check "reuse took no new lease (no second reset or attach)" [ "$(count '^attach base')" = 1 ]
idle_all
fresh f3b; export TEST_INFO=1 TEST_INFO_FAIL=1
acq "$T/repo"
say "failing hook: OUT=[$OUT] rc=$RC"
check "a failing envpool_info does not fail the acquire" bash -c '[ "$0" = base ] && [ "$1" = 0 ]' "$OUT" "$RC"
fresh f3c
acq "$T/repo"
check "without envpool_info nothing extra is printed" bash -c '[ "$0" = base ] && ! grep -q "https://" <<<"$1"' "$OUT" "$ERR"
fresh f3d; export TEST_ENVS="a b"; export TEST_INFO=1
acq "$T/repo" --wait 0
wt w1
acq "$T/w1" --wait 0
say "second worktree: OUT=[$OUT] stderr=[$(echo "$ERR" | tr '\n' ';')]"
check "the hook sees the other worktree's own path and env" logged "info $OUT $T/w1"

summary
