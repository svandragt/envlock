---
name: ticket-fleet
description: >-
  Prepare one worktree, ticket file and idle Claude session per ticket in
  herdr, for the user to start with their approach summary. Use when the user gives a repo
  and several ticket IDs (ABC-740, 1234) and asks to "fan out", "start a fleet",
  or work on these tickets in parallel.
---

# Ticket fleet

Starts a herdr workspace with its own git worktree and Claude session for each
ticket, writes the ticket into the worktree as a Markdown file, and stops with
each session idle. The user opens each pane and starts with their approach
summary. Sessions lease local environments with `envlock` (see the `envlock`
skill), so two sessions never use the same environment.

## Inputs

- A repo path (the main checkout).
- Ticket references that `ticket2md` reads: a Jira key or URL (`ABC-740`),
  `owner/repo#123`, or a GitHub or Zenhub issue URL. A bare number such as `1234` is
  allowed but gets no ticket file, because it does not say which repository or
  workspace holds the ticket. Never guess one from the code repository.
- Optional titles, if the user gives them.

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

Each ticket session is the user's: the user directs it in its own pane. The session that starts
the fleet sends the sessions nothing and receives no reports.

## Steps for each ticket

1. Fetch the ticket and get its title. Unless the reference is a bare number, run
   `ticket2md <ref> > "$tmp"` with `tmp=$(mktemp)`; on success its first line is
   `# <title>`. Use the title the user gave, else that line. If `ticket2md` fails or
   the reference is a bare number, there is no ticket file: look the title up instead,
   with `gh issue view <ticket> --json title` for a GitHub issue number or the Jira
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

   Move the ticket file, if there is one, to the path the `approach` skill reads:

   ```bash
   dir="$(git -C <worktree path> rev-parse --absolute-git-dir)/approach"
   mkdir -p "$dir" && mv "$tmp" "$dir/<branch>.ticket.md"
   ```
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
   workspace needs their attention, and continue with the other tickets.

   Stop here for this ticket. Send the session no brief: the user starts it.

   - Claude keys folder trust for a worktree on the main checkout's root, so trusting the
     repo's main checkout once should avoid the trust prompt.
   - If a pane shows a password prompt, a shell wrapper around `claude` is the cause.

## Status checks

To ask the fleet for a status, run `gh pr view` for each ticket's PR yourself first, then ask
each session about anything GitHub can't show: uncommitted or unpushed work and envlock leases.
Compare their answers with the PR states before proposing to close or keep a workspace.

## Resume a fleet

herdr forgets agent names when it restarts, so `herdr agent prompt` to a session fails with
`agent_not_found`. `SendMessage` uses Claude Code session names and keeps working. Before you
send the first herdr prompt to a resumed fleet, name each session again: run `herdr agent list`,
and for each pane whose `cwd` is a worktree of `<repo>`, run `herdr agent rename <pane_id> <name>`.
Build `<name>` as in step 3 of "Steps for each ticket", from the last part of the worktree path
without its leading `.`. That part is the branch the worktree was created with, so the name stays
the same even if the session later switched branch.

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
3. Ask each session, with `SendMessage`, to save what it learned before you close it: lessons that
   apply to later tickets as memories, and each follow-up that outlives the session as a park item
   tagged with the ticket. Wait for its answer. Worktrees of one repo share the repo's memory
   directory, so a saved memory outlives the workspace. Anything the session did not write down is
   lost when the workspace closes.
4. Close each clean workspace with `herdr workspace close <workspace_id>`. Leave the worktrees and
   branches until their PRs merge.
5. Run `envlock status` and check that no environment is still held.

## Finish

List one line per ticket as `ticket -> workspace id -> branch (from <base>) -> ticket file path`
(or "no ticket file"), then the output of
`envlock status` run from `<repo>`. Name any ticket that was skipped and why, and any session that was not ready, with its workspace id.
