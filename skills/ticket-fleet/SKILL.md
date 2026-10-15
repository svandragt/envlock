---
name: ticket-fleet
description: >-
  Start one worktree and one Claude session per ticket in herdr, each told how
  to lease a local dev environment with envlock. Use when the user gives a repo
  and several ticket IDs (ABC-740, 1234) and asks to "fan out", "start a fleet",
  or work on these tickets in parallel.
---

# Ticket fleet

Starts a herdr workspace with its own git worktree and Claude session for each
ticket. The sessions share the repo's environment pool through `envlock`
(`~/.local/bin/envlock`), so two sessions never use the same environment.

## Inputs

- A repo path (the main checkout).
- Ticket IDs, such as `ABC-740` or `1234`. Optional titles, if the user gives them.

## Prerequisite check

Run this before creating anything:

```bash
test -f <repo>/.envpool
```

If the file is missing, stop and tell the user that the repo needs an untracked
`.envpool` in the main checkout. It must define:

- `ENVS=(...)`: the environments the pool may lease. Never list the seed
  environment that serves the main checkout.
- `envpool_attach`: points `$ENVLOCK_ENV` at `$ENVLOCK_WORKTREE`.
- `envpool_reset`: clears state in `$ENVLOCK_ENV` between leases.
- Optional: `envpool_healthy`, which succeeds when `$ENVLOCK_ENV` already serves
  its code, so envlock can skip `envpool_attach`.
- Optional, to let the pool grow: `ENVPOOL_PREFIX`, `ENVPOOL_MAX`,
  `envpool_create` and `envpool_exists`.

## Steps for each ticket

1. Get the ticket title. Use the title the user gave. Otherwise look it up in the
   tracker: `gh issue view <ticket> --json title` for a GitHub issue number, the Jira
   tools for a key such as `ABC-740`. Build the slug from two to four key words of the
   title, in lowercase and joined by hyphens: "Annual report shows the wrong release"
   gives `annual-report-release`. Use `<ticket>` alone only when no title can be found.
   The branch is `<ticket>-<slug>` and the label is `<ticket> <slug words>`, such as
   `ABC-740 annual report release`, so the workspace shows what the ticket is about.
2. Create the worktree without taking focus:

   ```bash
   herdr worktree create --cwd <repo> --branch <branch> --label "<label>" --no-focus
   ```

   Read `root_pane.pane_id`, `workspace.workspace_id` and `worktree.path` from the
   JSON (under `.result` if the output has that wrapper). If the command fails,
   report it, skip this ticket and continue with the next.
3. Name the agent. herdr accepts only names that start with a lowercase letter, contain
   only `a-z`, `0-9`, `_` and `-`, and are 1 to 32 characters long, so the ticket ID alone
   (`ABC-740`, `1234`) is rejected. Use `t-` plus the lowercased branch name, with any other
   character turned into `-` and the result cut to 32 characters:

   ```bash
   name=$(printf 't-%s' "<branch>" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' - | cut -c1-32)
   ```

   `ABC-740-annual-report-release` gives `t-abc-740-annual-report-release`, and `1234` with no
   title gives `t-1234`. Use this name wherever the steps
   below say `<name>`.
4. Start Claude in that pane, then wait until it is ready:

   ```bash
   herdr agent start <name> --kind claude --pane <pane_id>
   herdr agent wait <name> --until idle --timeout 120000
   ```

   `agent start` times out when the new session stops at a startup prompt, such as
   Claude's "Do you trust this folder?" for a new worktree. If it times out, still run the
   wait. If the session is not idle after the wait, it is not ready: tell the user which
   workspace needs their attention, send no brief to it, and continue with the other tickets.

   - Claude keys folder trust for a worktree on the main checkout's root, so trusting the
     repo's main checkout once should avoid the trust prompt.
   - If a pane shows a password prompt, a shell wrapper around `claude` is the cause.
5. Send the brief only after the session is idle, with `herdr agent prompt <name> "<brief>"`.
   If the target is not accepted, use the name that `herdr agent list` shows for the pane.
   The brief says:

   - Your ticket is `<ticket>`. Read the ticket first, then work on it in this worktree.
   - Before anything that needs the environment, run `envlock acquire --wait 3600`.
     It prints the environment name, and `envlock env` prints it again.
   - Pick the version flags for `envlock acquire` from the ticket, using a `key=value` that
     `envlock status` shows: `--need wp=6.9` when the ticket must be tested on that version,
     `--want wp=6.9` when that version is preferred but any will do, and neither when the
     version does not matter.
   - The lease ends by itself when you finish your turn, so run
     `envlock acquire --wait 3600` again in the next turn that needs the environment.
   - `envlock release` ends the lease early.
   - Never use the seed environment or another session's environment directly.
   - `envlock status` shows who holds which environment and who is queued.

## Finish

List one line per ticket as `ticket -> workspace id -> branch`, then the output of
`envlock status` run from `<repo>`. Name any ticket that was skipped and why, and any session that was not ready, with its workspace id.
