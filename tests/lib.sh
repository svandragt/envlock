# shellcheck shell=bash
# shellcheck disable=SC2034  # OUT, ERR and RC are read by the suites that source this file.
# Shared helpers for the envlock tests. Source it; it does not run anything.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# All scratch state lives in SCR. The herdr stub and envlock are reached through symlinks in it, so
# the pgrep patterns below, which match command lines, only ever match processes of this run.
SCR=$(mktemp -d)
mkdir "$SCR/bin"
ln -s "$here/bin/herdr" "$SCR/bin/herdr"
ln -s "$here/../bin/envlock" "$SCR/bin/envlock"
EL=$SCR/bin/envlock
export PATH=$SCR/bin:$PATH XDG_STATE_HOME=$SCR/state
pass=0 fail=0 PN=0 PANE='' OUT='' ERR='' RC=0 T='' LD='' ED=''

check() { # description, then a command that succeeds when the observation is right
	local d=$1; shift
	if "$@"; then echo "  PASS $d"; pass=$((pass + 1)); else echo "  FAIL $d"; fail=$((fail + 1)); fi
}
say() { echo "  observed: $*"; }

idle_all() { local n; [ -z "${STUB_DIR:-}" ] || for n in $(seq "$PN"); do touch "$STUB_DIR/p$n"; done; }

write_pool() { # dir: writes the dummy .envpool; hooks only log to $TEST_LOG
	cat >"$1/.envpool" <<'EOP'
ENVS=(${TEST_ENVS:-base})
# With TEST_LEAK=file every hook starts a background sleep and appends its pid to the file, like a hook that starts a daemon.
leak() { [ -z "${TEST_LEAK:-}" ] || { sleep 7771 >/dev/null 2>&1 </dev/null & echo $! >>"$TEST_LEAK"; }; }
[ -z "${TEST_MAX:-}" ] || { ENVPOOL_PREFIX=${TEST_PREFIX:-g}; ENVPOOL_MAX=$TEST_MAX; }
envpool_exists() { leak; [ -e "${TEST_DISK:-/nonexistent}/$1" ]; }
envpool_create() { leak; echo "create $ENVLOCK_ENV" >>"$TEST_LOG"; sleep "${TEST_CSLEEP:-0}"; [ -z "${TEST_CFAIL:-}" ] && { [ -z "${TEST_ATTRS:-}" ] || echo wp=7.1 >"$TEST_ATTRS/$ENVLOCK_ENV"; }; }
envpool_reset() { leak; echo "reset $ENVLOCK_ENV" >>"$TEST_LOG"; }
envpool_attach() { leak; echo "attach $ENVLOCK_ENV" >>"$TEST_LOG"; [ -z "${TEST_ATTACH_FAIL:-}" ]; }
if [ -n "${TEST_HEALTHY_RC:-}" ]; then envpool_healthy() { leak; echo "healthy $ENVLOCK_ENV" >>"$TEST_LOG"; return "$TEST_HEALTHY_RC"; }; fi
# Attributes live in one file per env, one key=value per line.
if [ -n "${TEST_ATTRS:-}" ]; then
	envpool_describe() { leak; if [ "${TEST_DESC_FAIL:-}" = "$ENVLOCK_ENV" ]; then echo partial=1; return 1; fi; paste -sd' ' "$TEST_ATTRS/$ENVLOCK_ENV"; }
fi
if [ -n "${TEST_CONF:-}" ]; then
	envpool_configure() {
		leak; echo "configure $ENVLOCK_ENV $*" >>"$TEST_LOG"
		[ -z "${TEST_CONF_FAIL:-}" ] || return 1
		local p
		for p in "$@"; do sed -i "/^${p%%=*}=/d" "$TEST_ATTRS/$ENVLOCK_ENV"; echo "$p" >>"$TEST_ATTRS/$ENVLOCK_ENV"; done
	}
fi
if [ -n "${TEST_DESTROY:-}" ]; then
	envpool_destroy() { leak; echo "destroy $ENVLOCK_ENV" >>"$TEST_LOG"; sleep "${TEST_DSLEEP:-0}"; [ -z "${TEST_FAIL:-}" ]; }
fi
if [ -n "${TEST_SUSPEND:-}" ]; then
	envpool_suspend() { leak; echo "suspend $ENVLOCK_ENV" >>"$TEST_LOG"; [ "${TEST_SUSPEND_FAIL:-}" != "$ENVLOCK_ENV" ]; }
fi
if [ -n "${TEST_INFO:-}" ]; then
	envpool_info() { leak; echo "info $ENVLOCK_ENV $ENVLOCK_WORKTREE" >>"$TEST_LOG"; echo "https://$ENVLOCK_ENV.example/?key=1"; [ -z "${TEST_INFO_FAIL:-}" ]; }
fi
if [ -n "${TEST_DROP:-}" ]; then
	# Stands in for a shrink that removes g2 from the pool right after acquire locked it.
	flock() {
		command flock "$@" || return
		if [ "$*" = "-n 9" ] && [[ $(readlink "/proc/$$/fd/9") == */g2.lock ]]; then sed -i '/^g2$/d' "$TEST_DROP"; fi
	}
fi
EOP
}

ld_of() { printf '%s/envlock/%s' "$XDG_STATE_HOME" "$(printf '%s' "$(realpath "$1/.git")" | sha1sum | cut -c1-12)"; }

new_repo() { # name: a git repo with the dummy pool under $T
	git init -q -b main "$T/$1"
	git -C "$T/$1" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
	write_pool "$T/$1"
}

fresh() {
	idle_all
	T=$SCR/$1; rm -rf "$T"; mkdir -p "$T/disk" "$T/stub"
	export XDG_STATE_HOME=$T/state STUB_DIR=$T/stub TEST_LOG=$T/log
	unset TEST_ENVS TEST_MAX TEST_PREFIX TEST_DISK TEST_CSLEEP TEST_CFAIL TEST_DSLEEP TEST_DESTROY TEST_FAIL TEST_ATTACH_FAIL TEST_HEALTHY_RC TEST_DROP TEST_ATTRS TEST_CONF TEST_CONF_FAIL TEST_DESC_FAIL TEST_LEAK TEST_INFO TEST_INFO_FAIL TEST_SUSPEND TEST_SUSPEND_FAIL
	: >"$TEST_LOG"
	new_repo repo
	(cd "$T/repo" && "$EL" status >/dev/null)
	LD=$(ld_of "$T/repo"); ED=$XDG_STATE_HOME/envlock/envs
}
wt() { git -C "$T/repo" worktree add -q -b "$1" "$T/${2:-$1}"; }
rmwt() { git -C "$T/repo" worktree remove --force "$T/$1"; }

# acq DIR [args]: acquire as a new agent pane. Sets PANE, OUT (stdout), ERR (stderr), RC.
acq() {
	local d=$1; shift
	PN=$((PN + 1)); PANE=p$PN
	OUT=$(cd "$d" && HERDR_PANE_ID=$PANE "$EL" acquire "$@" 2>"$T/err"); RC=$?
	ERR=$(cat "$T/err")
}
idle() { touch "$STUB_DIR/$1"; }
free() { flock -n "$ED/$1.lock" true 2>/dev/null; }
held() { ! free "$1"; }
wait_free() { local i; for i in $(seq 40); do free "$1" && return 0; sleep 0.1; done; return 1; }
wait_held() { local i; for i in $(seq 40); do free "$1" || return 0; sleep 0.1; done; return 1; }
holder_pid() { sed 's/.* pid //' "$ED/$1.holder"; }
fd9_is() { [ "$(readlink "/proc/$1/fd/9" 2>/dev/null)" = "$ED/$2.lock" ]; }
logged() { grep -qx "$1" "$TEST_LOG"; }
nolog() { ! grep -q "$1" "$TEST_LOG"; }
count() { grep -c "$1" "$TEST_LOG" || true; }
envs_has() { grep -qx "$1" "$LD/envs" 2>/dev/null; }
envs_now() { tr '\n' ' ' <"$LD/envs" 2>/dev/null; }
register() { printf '%s\n' "$@" >>"$LD/envs"; }
rec() { sed -n "${2:-2}p" "$LD/last/$(printf '%s' "$1" | sha1sum | cut -c1-40)" 2>/dev/null; }
setattrs() { printf '%s\n' "${@:2}" >"$TEST_ATTRS/$1"; } # env key=value...: sets that env's attributes
attrs_of() { paste -sd' ' "$TEST_ATTRS/$1"; }
withattrs() { export TEST_ATTRS=$T/attrs; mkdir -p "$TEST_ATTRS"; }

elrun() { local d=$1; shift; OUT=$(cd "$T/$d" && "$EL" "$@" 2>&1); RC=$?; }
attached_of() { cat "$ED/$1.attached" 2>/dev/null; }

# The stub herdr processes this run started, for one pane or (without an argument) for all of them.
wait_pid() { pgrep -f "^bash $SCR/bin/herdr agent wait ${1:+$1 }" | head -1; }
waits_for() { [ -n "$(wait_pid "$1")" ]; }
nowait() { ! waits_for "$1"; }

# Waits for the detached shrink/suspend job that acquire starts.
settle() { sleep 0.3; while pgrep -f "^bash -c for s; do .* $SCR/bin/envlock " >/dev/null; do sleep 0.1; done; }

# Hooks started with TEST_LEAK=file record the pid of each background sleep in that file.
leaks_alive() { local p; [ -s "$TEST_LEAK" ] || return 1; while read -r p; do kill -0 "$p" 2>/dev/null || return 1; done <"$TEST_LEAK"; }
leaks_lockfree() { local p; while read -r p; do readlink "/proc/$p/fd/"* 2>/dev/null | grep -q '\.lock' && return 1; done <"$TEST_LEAK"; return 0; }
kill_leaks() { local f; for f in "$SCR"/*/leak; do [ -s "$f" ] || continue; xargs -r kill <"$f" 2>/dev/null; : >"$f"; done; }

summary() { echo; echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]; }

# Lets the holders end before the scratch dir goes, so none of them writes a log into a half-removed tree.
finish() {
	kill_leaks; idle_all
	for _ in $(seq 50); do [ -z "$(wait_pid)" ] && break; sleep 0.1; done
	rm -rf "$SCR"
}
trap finish EXIT
trap 'exit 1' INT TERM
