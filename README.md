<table><tr>
<td width="192" valign="middle"><img src="docs/icon.svg" width="176" height="176" alt="Three books on a shelf, one lifted out with a lending tag"></td>
<td valign="top">

# envlock

**Your local environments, leased like a library book.**

envlock cuts context switching when you juggle several tickets on one machine. Each ticket keeps its own git worktree and agent session, and borrows a local environment from a shared pool only while it needs one.

</td>
</tr></table>

You can leave a ticket and come back to it without re-explaining anything or stashing work. Think php-fpm, but the workers are dev environments.

## How it works

- Each ticket has its own git worktree and its own agent session.
- When an agent is about to use a site, it runs `envlock acquire`. envlock picks a free environment, points it at the ticket's code and prints its name.
- The lease ends when the agent finishes its turn. On its next turn the agent usually gets the same environment back, without switching code again.
- When every environment is busy, the agent waits its turn. envlock builds another environment in the background, up to a limit you set, and later removes or stops the ones nobody uses.
- An environment keeps its database between leases, so a ticket finds the data it left behind.
- If the project has a build watcher such as `npm run start`, an agent can ask for it with `--watch`. It runs while the ticket holds the environment and stops when the lease ends.

## Get started

### Install

Link the script onto your `PATH` and the skill into Claude Code:

```bash
ln -s "$PWD/bin/envlock" ~/.local/bin/envlock
ln -s "$PWD/skills/ticket-fleet" ~/.claude/skills/ticket-fleet
```

envlock needs bash, git, `flock` (util-linux) and [herdr](https://herdr.dev). A lease belongs to the herdr agent that asked for it, so `envlock acquire` works only in a herdr pane.

### Set up a pool

Open your agent in the main checkout of your project and ask it:

```text
Set up an envlock pool for this repo
```

The agent writes a `.envpool` file in the main checkout and keeps it out of git. envlock creates the first environment when an agent first needs one. That takes from half a minute to a few minutes, depending on the platform.

envlock comes with ready-made pools for three local platforms:

| Platform | Example | Notes |
|---|---|---|
| VIP dev-env | [`examples/vip.envpool`](examples/vip.envpool) | Agents can ask for a WordPress or PHP version. |
| Altis local-server | [`examples/altis.envpool`](examples/altis.envpool) | Versions follow each ticket's code. |
| DDEV | [`examples/ddev.envpool`](examples/ddev.envpool) | Versions follow each ticket's code. Only worktrees can lease, not the main checkout. |

For another platform, the agent writes the pool from scratch, following the rules in [AGENTS.md](AGENTS.md).

Each platform runs its own proxy on ports 80 and 443, so you can use the pools of only one platform at a time. Stop the other platforms' environments first.

### Start a session per ticket

In Claude Code, give the skill your project and tickets:

```text
/ticket-fleet ~/dev/my-project ABC-101 ABC-102 ABC-103
```

The skill creates a worktree and a Claude Code session per ticket, and tells each session to run `envlock acquire` when it needs an environment.

### Check the pool

Run `envlock status` from any worktree of the project:

```console
$ envlock status
1/2 in use, 1 free, 0 queued, cap 3
site2  held by ~/worktrees/my-project/ABC-101 (ABC-101-fix-menu) pane w3:p1 pid 41872  wp=6.9 php=8.2
site3  free  wp=7.1 php=8.4
events log: ~/.local/state/envlock/3f9a1c07d2b4/events.log
```

It shows which environments are in use, by which ticket and herdr pane, who is waiting, and which environments are `not created` yet or `suspended`. On VIP, each line ends with the environment's versions.

## Ask for what a ticket needs

Agents run `envlock acquire` themselves. To change what a ticket gets, tell its agent to add one of these options:

| Option | What the ticket gets |
|---|---|
| `--wait 3600` | It waits up to an hour for a free environment, instead of giving up straight away. |
| `--fresh` | A clean copy of the seed's database, for a ticket that runs migrations or needs clean data. The seed is the environment that serves your main checkout. |
| `--watch` | The project's build watcher, such as `npm run start`, running while the ticket holds the environment, for hot reloading. |
| `--need wp=6.9` | An environment on WordPress 6.9. envlock changes a free one if none matches. VIP only. |
| `--want wp=6.9` | WordPress 6.9 if such an environment is free, and any free environment otherwise. VIP only. |
| `--urgent` | A place ahead of every waiting ticket that did not ask for `--urgent`. |

`--need` and `--want` take any attribute the pool reports, such as `php=8.2`, and repeat for more than one.

An agent that waits at a permission prompt keeps its lease. To free an environment early, run `envlock release` from the ticket's worktree. `envlock env` prints the environment that the worktree leases.

## Look after the pool

envlock grows, shrinks and stops the pool by itself:

- When a ticket takes the last free environment, envlock builds another one in the background, up to the pool's limit, so the next ticket does not wait.
- envlock removes an environment it built when no remaining worktree uses it and another environment is free. The environments you listed are never removed.
- envlock stops free environments that no worktree uses, to save memory, and starts them again on the next lease.

These commands do the same work now:

| Command | What it does |
|---|---|
| `envlock grow` | Adds an environment, even past the pool's limit. |
| `envlock shrink` | Removes the environments envlock built that no remaining worktree uses. One environment stays free. |
| `envlock suspend` | Stops the free environments that no remaining worktree uses. |

## Example: three tickets, two environments

The pool has `site2` and `site3`, and may grow to three. You start three sessions with `/ticket-fleet`:

1. ABC-101 needs WordPress 6.9. Its agent runs `envlock acquire --need wp=6.9` and gets `site2`.
2. ABC-102's agent runs `envlock acquire` and gets `site3`. No environment is free now, so envlock starts building `site4` in the background.
3. ABC-103's agent runs `envlock acquire --wait 3600` and waits. It gets the first environment that frees up, or `site4` when it is ready.
4. ABC-101's agent finishes its turn, and its lease ends. Its next `acquire` gets `site2` back.
5. After you delete the worktrees of the tickets that used `site4`, envlock removes `site4`, as long as another environment is free.

## Troubleshooting

- **An acquire fails, or a lease ends and you do not know why.** Read the events log, whose path is the last line of `envlock status`. It records each lease, release and failure, with the step that failed and its exit status.
- **An agent gives up with "all environments busy".** Tell it to use `--wait`, or raise the pool's limit in `.envpool`.
- **The build watcher does not run, or stops early.** Read `watch/<environment>.log` in the directory that holds the events log. The watcher's output goes there.
- **A site does not load after you switch platforms.** Another platform's proxy still holds ports 80 and 443. Stop that platform's environments.
