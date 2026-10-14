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

1. Build the branch name. Use `<ticket>-<slug>`, with the slug from the title in
   lowercase words joined by hyphens. Use `<ticket>` alone when no title is known.
2. Create the worktree without taking focus:

   ```bash
   herdr worktree create --cwd <repo> --branch <branch> --label <ticket> --no-focus
   ```

   Read `root_pane.pane_id`, `workspace.workspace_id` and `worktree.path` from the
   JSON (under `.result` if the output has that wrapper). If the command fails,
   report it, skip this ticket and continue with the next.
3. Start Claude in that pane:

   ```bash
   herdr agent start <ticket> --kind claude --pane <pane_id>
   ```

4. Send the brief with `herdr agent prompt <ticket> "<brief>"`. If the target is
   not accepted, use the name that `herdr agent list` shows for the pane. The brief says:

   - Your ticket is `<ticket>`. Read the ticket first, then work on it in this worktree.
   - Before anything that needs the environment, run `envlock acquire --wait 3600`.
     It prints the environment name, and `envlock env` prints it again.
   - The lease ends by itself when you finish your turn, so run
     `envlock acquire --wait 3600` again in the next turn that needs the environment.
   - `envlock release` ends the lease early.
   - Never use the seed environment or another session's environment directly.
   - `envlock status` shows who holds which environment and who is queued.

## Finish

List one line per ticket as `ticket -> workspace id -> branch`, then the output of
`envlock status` run from `<repo>`. Name any ticket that was skipped and why.
