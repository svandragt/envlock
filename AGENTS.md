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
- After an acquire leaves no environment free, a detached `envlock grow --capped` builds one in the background (`$lockdir/grow.log`). It closes fd 9 so it never holds the lease. `grow.lock` stops two grows running at once.
- Environments added by growth are listed in `$lockdir/envs`, not in `.envpool`.

## Writing .envpool hooks

- `envpool_create` runs inside an `if`, where `set -e` is off. Chain its steps with `&&` and return non-zero on failure, or envlock registers an environment that does not work.
- `envpool_create` must leave a working database. The VIP example clones the seed environment's database, compares table counts, and destroys the new environment on any mismatch.

## Testing

There is no test suite. Test changes in a scratch git repo with a dummy `.envpool` whose hooks only echo, and run several `envlock run --wait N -- sleep 3` calls in the background to exercise the queue. Never test grow or create against real environments. Check the script with `bash -n bin/envlock` and `shellcheck bin/envlock`; if shellcheck is missing, run it through devbox.
