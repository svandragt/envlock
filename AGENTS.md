# AGENTS.md

Guidance for coding agents working in this repository. `README.md` covers what envlock is for and how to use it.

## Layout

- `bin/envlock`: the whole tool, one bash script. `~/.local/bin/envlock` is a symlink to it.
- `skills/ticket-fleet/SKILL.md`: a Claude Code skill that starts a herdr worktree and session per ticket. `~/.claude/skills/ticket-fleet` is a symlink to it.
- `examples/vip.envpool`: a copy of a real pool config for VIP dev-env sites. The real file lives untracked in that project's main checkout.

## How a lease works

- A lease belongs to a herdr agent, not to a command. The agent runs `envlock acquire [--wait SECONDS]` from its worktree when it is about to use an environment. `session_id` reads the caller's pane from `$HERDR_PANE_ID` and makes `acquire` exit 1 with a message when it is unset or `herdr` is not on `PATH`.
- `acquire` works in the foreground: it joins the queue, takes the lock, runs `envpool_reset`, switches the environment (see the attach record below), and then starts the holder. The agent's command blocks until all of that is done.
- The lease is a `flock` on fd 9 of `$envdir/<env>.lock`. The holder is a process started with `setsid` that inherits fd 9. It runs `session_wait_idle`, which `exec`s `herdr agent wait <pane> --until idle --until done`, so the holder process is the wait itself. When the wait returns or fails, for any reason including a missing pane or server, the holder exits and the kernel releases the lock. A `blocked` agent (a permission prompt) is neither idle nor done, so it keeps its lease.
- The holder's stdin is `/dev/null`, and its stdout and stderr go to `$lockdir/holder.log`. If it kept the caller's pipes, `name=$(envlock acquire)` would wait for it. Hook output goes to stderr for the same reason, so stdout carries only the environment name.
- After starting the holder, `acquire` closes its own fd 9, prints the environment name on stdout, and runs `headroom`. The lock now lives only in the holder, which is why `headroom`, `grow` and `shrink` all start with fd 9 closed.
- `$envdir/<env>.holder` reads `<worktree> (<branch>) pane <pane> pid <holder pid>`. `acquire` writes it without the pid first, so `find_lease` ignores a lease that is still being set up. `status` prints it as the holder, and affinity and `find_lease` match on the worktree prefix.
- `find_lease` finds this worktree's live lease: a holder file that names the worktree, whose pid has `/proc/<pid>/fd/9` pointing at that env's lock file. Holder files outlive their lease, so the `/proc` check is what makes a lease live. `acquire` (reuse), `env` and `release` all use it. On reuse, `acquire` prints the environment and exits 0 without queueing, resetting or attaching. `release` kills the holder pid.
- `$envdir` is `${XDG_STATE_HOME:-$HOME/.local/state}/envlock/envs`. It holds each env's `.lock`, `.holder` and `.attached` files, so two repositories that list the same environment share one lock. `$lockdir` is `.../envlock/<hash of the git common dir>` and holds the rest: the queue, the grown-envs list, `last/`, `grow.lock` and the logs. All worktrees of one repository share a pool.
- `.envpool` is sourced from the worktree root, or else from the main checkout.
- Waiters queue as files in `$lockdir/queue/`, named by nanosecond timestamp and pid. Only the oldest live entry may take an environment.
- Environments whose holder file names the current worktree are tried first, so a ticket gets back the environment that already has its code.
- After taking an env's lock, `acquire` reloads the pool and checks that the env is still a member. If it is not, it closes the lock and tries the next env. This covers an env that a shrink removed after `acquire` listed the pool.
- The attach record is `$envdir/<env>.attached`, which holds the worktree path of the last successful switch. Before `envpool_attach` runs, `acquire` deletes the record. It writes the record only after `envpool_attach` returns 0, and a failing hook exits under `set -e` before that. `acquire` skips `envpool_attach` when the record names this worktree and either `envpool_healthy` is undefined or returns 0. `envpool_reset` still runs on every new lease, and not on reuse.
- After an acquire leaves no environment free, a detached `envlock grow --capped` builds one in the background (`$lockdir/grow.log`). `grow.lock` is the pool lock: it stops two grows, or a grow and a shrink, running at once.
- Environments added by growth are listed in `$lockdir/envs`, not in `.envpool`.
- Every acquire writes `$lockdir/last/<sha1 of the worktree path>`: the worktree path on line 1, the env name on line 2. A worktree uses the env it leased most recently, so an env can have several users. An env is in use while any record whose worktree directory still exists names it.
- After an acquire, `headroom` either starts a grow (it returns 0) or does not. When it does not, and `envpool_destroy` is defined and `$lockdir/envs` is not empty, a detached `envlock shrink` starts in the same way, logging to `grow.log`.
- `envlock shrink` takes the pool lock with `flock -n` and exits if it is held. The candidates are the names in `$lockdir/envs` that are not in `ENVS`. For each one it takes the env's lease lock on fd 7 with `flock -n` and keeps it through `envpool_destroy`, so nobody can lease the env while it is removed. With that lock held it checks the rule again: no live record names the env, and another env, from `ENVS` or grown, has a lock that `flock -n` can take. It reloads the pool before each candidate, so the free count is taken again after every removal. It deletes the records of worktrees that no longer exist.
- A successful destroy removes the name from `$lockdir/envs`, still holding the env's lock, and deletes the env's `.holder` and `.attached` files. It never deletes the `.lock` file: a lease that opened the file before the removal then locks the same inode, finds the name gone, and drops the lock. A failed destroy keeps the env registered and logs it.
- Shrink always leaves another env free at the moment of each removal, so it does not fight `headroom`, which only grows at 0 free. A lease can still take that env during a slow destroy. When it does, the lease's own grow finds the pool lock held, so `shrink` calls `headroom` again after a removal.

## Other agent hosts

- envlock depends on herdr only through `session_id` and `session_wait_idle`. To support another host, such as Orca, rewrite those two functions.
- A host needs two things: a way to identify the calling session, such as an environment variable set in its terminals, and a way to block until that session finishes its turn or exits.
- A host-free option for Claude Code is a `Stop` hook that runs `envlock release` at the end of each turn, with a holder that waits for the agent's process to exit instead of a herdr state. It works in any terminal, but only for Claude Code sessions.
- `skills/ticket-fleet` uses herdr to create worktrees and start sessions, so another host needs its own version of that skill.

## Writing .envpool hooks

- `envpool_create` runs inside an `if`, where `set -e` is off. Chain its steps with `&&` and return non-zero on failure, or envlock registers an environment that does not work.
- `envpool_destroy` runs inside an `if` as well. Chain its steps with `&&` and return non-zero on failure, or envlock forgets an env that still exists.
- `envpool_create` must leave a working database. The VIP example clones the seed environment's database, compares table counts, and destroys the new environment on any mismatch.
- `envpool_attach` runs as a plain command, so `set -e` applies inside it and a failing step aborts `acquire` with no attach record. It must always do the full switch, because envlock decides when to skip it.
- `envpool_healthy` is optional and sees `ENVLOCK_ENV`. It returns 0 when the environment is up and serves its code. envlock asks it only when the attach record already names the worktree. Without it, the record alone decides.

## Testing

There is no test suite. Test changes in a scratch git repo with a dummy `.envpool` whose hooks only echo, and point `XDG_STATE_HOME` at a scratch directory so the real state under `~/.local/state/envlock` stays untouched.

`acquire` needs a `herdr` on `PATH` and `HERDR_PANE_ID` set. Put a stub `herdr` first on `PATH` whose `agent wait <pane>` blocks until a file named after the pane appears, and create that file to simulate the agent going idle. Never call the real `herdr agent wait` or `herdr agent prompt` from a test. Run several `envlock acquire --wait N` calls in the background, each from its own worktree and pane, to exercise the queue. Never test grow, create, shrink or destroy against real environments.

Check the script with `bash -n bin/envlock` and `shellcheck bin/envlock`; if shellcheck is missing, run it through devbox or `nix shell nixpkgs#shellcheck`.
