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

## Before the tickets

Run this once per fleet, before creating any worktree:

1. Fetch the remote, so new worktrees start from current code. If the fetch fails, tell the
   user and stop:

   ```bash
   git -C <repo> fetch origin
   ```

2. Find the base ref that tickets start from:

   ```bash
   git -C <repo> symbolic-ref --short refs/remotes/origin/HEAD
   ```

   It prints a ref such as `origin/main`. If it fails, use the branch the user names, as
   `origin/<branch>`. If the user named none, ask which branch tickets start from. Use this
   ref wherever the steps below say `<base>`.

3. Name your own session, so the ticket sessions can report to it:

   ```bash
   lead=$(printf 'lead-%s' "$(basename <repo>)" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' - | cut -c1-32)
   herdr agent rename "$(herdr pane current | jq -r '.result.pane.pane_id')" "$lead"
   ```

   Use this name wherever the steps below say `<lead>`. A report arrives in your session as a
   prompt. Read it, act on it within the plan, and pass to the user only what needs their
   decision.

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
   herdr worktree create --cwd <repo> --branch <branch> --label "<label>" --base <base> --no-focus \
     --path ~/.herdr/worktrees/$(basename <repo>)/.$(printf '%s' "<branch>" | tr 'A-Z' 'a-z')
   ```

   The folder name starts with `.`, so herdr-dash hides the session until it is blocked.

   A `<base>` of `origin/preprod` gives `--base origin/preprod`. Read `root_pane.pane_id`, `workspace.workspace_id` and `worktree.path` from the
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
   - Run `envlock acquire` without piping it through `head`, `tail` or `grep`, and check the
     lease with `envlock env` before you use the environment.
   - Pick the version flags for `envlock acquire` from the ticket, using a `key=value` that
     `envlock status` shows: `--need wp=6.9` when the ticket must be tested on that version,
     `--want wp=6.9` when that version is preferred but any will do, and neither when the
     version does not matter.
   - Add `--watch` to `envlock acquire` for front-end work that needs the project's build
     watcher or hot reloading. The watcher runs while you hold the environment.
   - Add `--fresh` to `envlock acquire` when the ticket runs migrations or needs clean data.
     It replaces the environment's database with the seed's.
   - The lease ends by itself when you finish your turn, so run
     `envlock acquire --wait 3600` again in the next turn that needs the environment.
   - `envlock release` ends the lease early.
   - Never use the seed environment or another session's environment directly.
   - `envlock status` shows who holds which environment and who is queued.
   - Report to the lead without being asked. At the end of any turn where your plan is ready
     for approval, a step finishes, you are blocked, you need a decision, or you stop, run
     `herdr agent prompt <lead> "[<ticket>] <done|blocked|decision|stopping>: <one line>"`.
     Put the detail in your own pane, not in the report. If the prompt fails, send it again at
     the end of your next turn, and never wait for a reply.
   - Before you open a PR as ready for review, or mark a draft ready, run `/code-review --fix`
     and commit what it fixes.
   - Before you list anything under "Not checked" in a PR body, try to check it. Only what
     can't be checked from here stays on the list, with the reason.
   - When you report a status, include your PR's state from
     `gh pr view <number> --json state,reviewDecision,reviews`: merged, approved, changes
     requested or waiting. "Nothing left" needs that check, because a review can arrive
     after you stop.

## Status checks

To ask the fleet for a status, run `gh pr view` for each ticket's PR yourself first, then ask
each session about anything GitHub can't show: uncommitted or unpushed work and envlock leases.
Compare their answers with the PR states before proposing to close or keep a workspace.

## Resume a fleet

herdr forgets agent names when it restarts, so prompts to a session fail with
`agent_not_found` and its reports to `<lead>` fail too. Before you send the first prompt to
a resumed fleet, name each session again:

1. Name your own session `<lead>`, as in step 3 of "Before the tickets".
2. Run `herdr agent list`. For each pane whose `cwd` is a worktree of `<repo>`, run
   `herdr agent rename <pane_id> <name>`. Build `<name>` as in step 3 of "Steps for each
   ticket", from the last part of the worktree path without its leading `.`. That part is the
   branch the worktree was created with, so the name stays the same even if the session later
   switched branch.

## Branches without a PR

A session can leave finished work on local branches that never get a PR, for example per-change
branches it tested together on an integration branch. Before you tick a ticket's checklist item,
move the ticket to QA, or stand the fleet down, compare the ticket's branches with its PRs:

```bash
git -C <repo> branch --list '<ticket>*' --format='%(refname:short)'
gh pr list -R <owner/repo> --state all --search '<ticket>' --json headRefName -q '.[].headRefName'
```

Report every branch that has commits not on `<base>` and no PR, with its last commit subject.
Don't tick the item or move the ticket until each one has a PR or the user says to drop it.

## Stand down

1. Run the branch check above for every ticket in the fleet.
2. For each worktree, check `git status --short` and `git log @{u}..HEAD`. Report uncommitted or
   unpushed work, and stop before closing that workspace.
3. Close each clean workspace with `herdr workspace close <workspace_id>`. Leave the worktrees and
   branches until their PRs merge.
4. Run `envlock status` and check that no environment is still held.

## Finish

List one line per ticket as `ticket -> workspace id -> branch (from <base>)`, then the output of
`envlock status` run from `<repo>`. Name any ticket that was skipped and why, and any session that was not ready, with its workspace id.
