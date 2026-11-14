---
name: envlock
description: >-
  Lease a local dev environment from a repo's shared pool with envlock before
  running, testing or browsing the site. Use in any repo whose main checkout has
  a `.envpool` file (ticket-fleet worktrees and others), before anything that
  needs a local environment: starting the site, running tests against it,
  migrations, or a build watcher.
---

# envlock

Worktrees of one repo share a pool of local environments. `envlock`
(`~/.local/bin/envlock`) leases one at a time, so two sessions never use the
same environment.

- Before anything that needs the environment, run `envlock acquire --wait 3600`.
  It prints the environment name, and `envlock env` prints it again.
- Run `envlock acquire` without piping it through `head`, `tail` or `grep`, and
  check the lease with `envlock env` before you use the environment.
- Pick the version flags for `envlock acquire` from the ticket, using a
  `key=value` that `envlock status` shows: `--need wp=6.9` when the ticket must
  be tested on that version, `--want wp=6.9` when that version is preferred but
  any will do, and neither when the version does not matter.
- Add `--watch` for front-end work that needs the project's build watcher or hot
  reloading. The watcher runs while you hold the environment.
- Add `--fresh` when the ticket runs migrations or needs clean data. It replaces
  the environment's database with the seed's.
- The lease ends by itself when you finish your turn, so run
  `envlock acquire --wait 3600` again in the next turn that needs the
  environment.
- `envlock release` ends the lease early.
- Never use the seed environment or another session's environment directly.
- `envlock status` shows who holds which environment and who is queued.
