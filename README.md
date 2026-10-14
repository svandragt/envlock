# envlock

envlock cuts context switching when you juggle several tickets on one machine. Each ticket keeps its own git worktree and its own agent session, so you can leave a ticket and come back to it without re-explaining anything or stashing work. Local dev environments are shared from a small pool. A ticket leases one only when it needs to run something, waits its turn if none is free, and gets the same environment back next time if it can. Think php-fpm, but the workers are dev environments.

## Install

Link the script onto your `PATH` and the skill into Claude Code:

```bash
ln -s "$PWD/bin/envlock" ~/.local/bin/envlock
ln -s "$PWD/skills/ticket-fleet" ~/.claude/skills/ticket-fleet
```

envlock needs bash, git and `flock` (util-linux). The `ticket-fleet` skill also needs [herdr](https://herdr.dev).

## Describe your environments

Add a `.envpool` file to the root of your project's main checkout. Every worktree of the project reads it, so you can keep it out of git. It is a bash file:

```bash
ENVS=(my-env-1)              # environments in the pool
ENVPOOL_PREFIX=my-env-       # name for new environments: my-env-2, my-env-3, ...
ENVPOOL_MAX=3                # never grow the pool past this

envpool_attach() { ...; }    # point $ENVLOCK_ENV at the code in $ENVLOCK_WORKTREE
envpool_reset() { ...; }     # clean up before each lease, for example flush caches
envpool_create() { ...; }    # build $ENVLOCK_ENV, including its database; return non-zero on failure
```

Only `ENVS` is required. Leave out `ENVPOOL_MAX` and `envpool_create` to keep the pool a fixed size. [`examples/vip.envpool`](examples/vip.envpool) is a complete example for VIP dev-env sites.

## Use it

Run these from any worktree of the project:

| Command | What it does |
|---|---|
| `envlock run --wait 3600 -- <command>` | Leases an environment, runs the command, and releases the environment when the command ends. |
| `envlock hold --wait 3600` | Leases an environment and keeps it until you run `envlock release` or close the terminal. Use it for testing that spans several commands. |
| `envlock release` | Ends this worktree's `hold`. |
| `envlock status` | Shows which environments are in use and by which ticket, and who is waiting. |
| `envlock grow` | Adds an environment to the pool now. |

Without `--wait`, envlock gives up straight away when every environment is busy.

When a lease takes the last free environment, envlock builds another one in the background, up to `ENVPOOL_MAX`, so the next ticket does not wait for it.

## Start a session per ticket

In Claude Code, give the skill your project and tickets:

```text
/ticket-fleet ~/dev/my-project ABC-101 ABC-102 ABC-103
```

The skill creates a worktree and a Claude Code session per ticket, and tells each session to use envlock when it needs an environment.
