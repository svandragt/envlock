# AGENTS.md

Guidance for coding agents working in this repository. `README.md` covers what envlock is for and how to use it.

## Layout

- `bin/envlock`: the whole tool, one bash script. `~/.local/bin/envlock` is a symlink to it.
- `skills/ticket-fleet/SKILL.md`: a Claude Code skill that starts a herdr worktree and session per ticket. `~/.claude/skills/ticket-fleet` is a symlink to it.
- `examples/vip.envpool`: a copy of a real pool config for VIP dev-env sites. The real file lives untracked in that project's main checkout.

## How a lease works

- The lease is a `flock` on fd 9 of `$lockdir/<env>.lock`. `run` and `hold` `exec` into the command, so the lock lasts exactly as long as that process, and a crash releases it. Nothing runs after the command ends, so there is no check-in step: `envpool_attach` corrects the environment at the next acquire.
- `$lockdir` is `~/.local/state/envlock/<hash of the git common dir>`, so all worktrees of one repository share a pool.
- `.envpool` is sourced from the worktree root, or else from the main checkout.
- Waiters queue as files in `$lockdir/queue/`, named by nanosecond timestamp and pid. Only the oldest live entry may take an environment.
- Environments whose holder file names the current worktree are tried first, so a ticket gets back the environment that already has its code.
- After an acquire leaves no environment free, a detached `envlock grow --capped` builds one in the background (`$lockdir/grow.log`). It closes fd 9 so it never holds the lease. `grow.lock` is the pool lock: it stops two grows, or a grow and a shrink, running at once.
- Environments added by growth are listed in `$lockdir/envs`, not in `.envpool`.
- Every acquire writes `$lockdir/last/<sha1 of the worktree path>`: the worktree path on line 1, the env name on line 2. A worktree uses the env it leased most recently, so an env can have several users. An env is in use while any record whose worktree directory still exists names it. The holder file only serves `status`, `release` and affinity.
- After an acquire, `headroom` either starts a grow (it returns 0) or does not. When it does not, and `envpool_destroy` is defined and `$lockdir/envs` is not empty, a detached `envlock shrink` starts in the same way, logging to `grow.log`.
- `envlock shrink` takes the pool lock with `flock -n` and exits if it is held. The candidates are the names in `$lockdir/envs` that are not in `ENVS`. For each one it takes the env's lease lock on fd 7 with `flock -n` and keeps it through `envpool_destroy`, so nobody can lease the env while it is removed. With that lock held it checks the rule again: no live record names the env, and another env, from `ENVS` or grown, has a lock that `flock -n` can take. It reloads the pool before each candidate, so the free count is taken again after every removal. It deletes the records of worktrees that no longer exist.
- A successful destroy removes the name from `$lockdir/envs` and deletes the env's `.lock` and `.holder` files. A failed destroy keeps the env registered and logs it.
- Shrink always leaves another env free at the moment of each removal, so it does not fight `headroom`, which only grows at 0 free. A lease can still take that env during a slow destroy. When it does, the lease's own grow finds the pool lock held, so `shrink` calls `headroom` again after a removal.

## Writing .envpool hooks

- `envpool_create` runs inside an `if`, where `set -e` is off. Chain its steps with `&&` and return non-zero on failure, or envlock registers an environment that does not work.
- `envpool_destroy` runs inside an `if` as well. Chain its steps with `&&` and return non-zero on failure, or envlock forgets an env that still exists.
- `envpool_create` must leave a working database. The VIP example clones the seed environment's database, compares table counts, and destroys the new environment on any mismatch.

## Testing

There is no test suite. Test changes in a scratch git repo with a dummy `.envpool` whose hooks only echo, and run several `envlock run --wait N -- sleep 3` calls in the background to exercise the queue. Never test grow, create, shrink or destroy against real environments. Check the script with `bash -n bin/envlock` and `shellcheck bin/envlock`; if shellcheck is missing, run it through devbox.
