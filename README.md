# envlock

envlock cuts context switching when you juggle several tickets on one machine. Each ticket keeps its own git worktree and its own agent session, so you can leave a ticket and come back to it without re-explaining anything or stashing work. Local dev environments are shared from a small pool. An agent leases one only when it is about to use it, waits its turn if none is free, and gets the same environment back next time if it can. The lease ends when the agent finishes its turn. Think php-fpm, but the workers are dev environments.

## Install

Link the script onto your `PATH` and the skill into Claude Code:

```bash
ln -s "$PWD/bin/envlock" ~/.local/bin/envlock
ln -s "$PWD/skills/ticket-fleet" ~/.claude/skills/ticket-fleet
```

envlock needs bash, git, `flock` (util-linux) and [herdr](https://herdr.dev). A lease belongs to the herdr agent that asked for it, so `envlock acquire` works only in a herdr pane.

## Describe your environments

Add a `.envpool` file to the root of your project's main checkout. Every worktree of the project reads it, so you can keep it out of git. It is a bash file:

```bash
ENVS=(my-env-1)              # environments in the pool
ENVPOOL_PREFIX=my-env-       # name for new environments: my-env-2, my-env-3, ...
ENVPOOL_MAX=3                # never grow the pool past this

envpool_attach() { ...; }    # point $ENVLOCK_ENV at the code in $ENVLOCK_WORKTREE; always do the full switch
envpool_healthy() { ...; }   # return 0 when $ENVLOCK_ENV is up and already serves its code
envpool_reset() { ...; }     # clean up before each lease, for example flush caches
envpool_create() { ...; }    # build $ENVLOCK_ENV, including its database; return non-zero on failure
envpool_destroy() { ...; }   # remove $ENVLOCK_ENV; return non-zero on failure. Without it the pool never shrinks
envpool_describe() { ...; }  # print the attributes of $ENVLOCK_ENV as key=value pairs, for example: wp=7.1 php=8.4
envpool_configure() { ...; } # change $ENVLOCK_ENV to the key=value pairs in "$@"; return non-zero on failure
```

Only `ENVS` is required. Leave out `ENVPOOL_MAX` and `envpool_create` to keep the pool a fixed size. [`examples/vip.envpool`](examples/vip.envpool) is a complete example for VIP dev-env sites.

envlock remembers which worktree it last switched each environment to. When the same worktree comes back, envlock skips `envpool_attach`, as long as `envpool_healthy` returns 0 or does not exist. If `envpool_attach` fails, envlock forgets the switch and runs it again next time. If two projects list the same environment, they share one lock.

## Use it

Run these from any worktree of the project:

| Command | What it does |
|---|---|
| `envlock acquire --wait 3600` | Leases an environment for the calling agent and prints its name. Run it before anything that needs the environment. The lease ends when the agent finishes its turn or its pane closes, so run it again next turn. An agent that waits at a permission prompt keeps its lease. Running it again while the worktree holds a lease prints the same environment. |
| `envlock acquire --need wp=6.9` | Leases an environment whose attributes include `wp=6.9`, and changes one to match if none does. Repeat `--need` for more attributes. Needs `envpool_describe`. |
| `envlock acquire --want wp=6.9` | Prefers an environment with `wp=6.9`, but leases any free one when none matches. Repeat `--want` for more attributes. Ignored without `envpool_describe`. |
| `envlock env` | Prints the environment this worktree leases, or exits with status 1 if there is none. |
| `envlock release` | Ends this worktree's lease early. |
| `envlock status` | Shows which environments are in use, by which ticket and which herdr pane, and who is waiting. When `.envpool` has `envpool_describe`, each environment's line ends with its attributes. |
| `envlock grow` | Adds an environment to the pool now, even past `ENVPOOL_MAX`. |
| `envlock shrink` | Removes the environments envlock added that no unfinished ticket uses, now. At least one environment stays free. |

Without `--wait`, envlock gives up straight away when every environment is busy.

Use `--need` when a ticket must run on a given version. envlock leases a free environment that has the attributes, preferring one this worktree used before. If none has them, envlock changes a free environment with `envpool_configure` before it resets and attaches. If `.envpool` has no `envpool_configure`, the agent waits for a matching environment and gives up with exit status 75 when `--wait` runs out. When the worktree already holds a lease that does not match, envlock changes that environment in place. Without `envpool_configure` it asks you to run `envlock release` first.

Use `--want` when a version is preferred but any will do. It only changes which free environment envlock tries first. It never changes an environment, never waits for a match and never fails on a mismatch. You can combine the two: `--need` decides which environments qualify, and `--want` picks among them.

When a lease takes the last free environment, envlock builds another one in the background, up to `ENVPOOL_MAX`, so the next ticket does not wait for it. After each lease, envlock also removes an environment it added earlier when no existing worktree has it as its most recent lease and another environment is free. Environments in `ENVS` are never removed.

## Start a session per ticket

In Claude Code, give the skill your project and tickets:

```text
/ticket-fleet ~/dev/my-project ABC-101 ABC-102 ABC-103
```

The skill creates a worktree and a Claude Code session per ticket, and tells each session to run `envlock acquire` when it needs an environment.
