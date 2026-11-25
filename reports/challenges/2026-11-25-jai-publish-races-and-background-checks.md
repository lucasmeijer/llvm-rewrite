# Publishing from a busy main: a background `check` died with the tool call, and every push raced other agents

- **Date / implementation / unit:** 2026-11-25 / jai / L1.sroa, L1.o2-gaps, L2.inline, L1.vectorize.loop, L1.vectorize.slp
- **What happened:** (1) I started `./harness/run check --impl jai --update &` from a Bash tool call to keep working
  while it ran; the job was killed when the tool call returned, leaving a log that only said "building impl/jai ..."
  and costing a 30-minute wait on a dead process. (2) With six jai agents pushing, origin/main moved during almost
  every 5-6 minute full check, so the rebase / recheck / push loop had to run two or three times per item, and I
  could not edit `src/` while a check in the same worktree was still building.
- **Time or effort lost:** ~45 minutes of waiting and re-running checks.
- **What would have helped:** a note in AGENTS.md that long checks must run in tmux (not `&`), and a standard
  "publish from a second, detached worktree" script.
- **What you did instead:** a small script (`/tmp/jai_tails/publish.sh <commit>`) that checks out the commit
  detached in `/work-wt/jai_tails_pub`, rebases on origin/main, runs `check --update`, commits passing.txt, re-fetches,
  retries if origin moved, pushes, and confirms the commit is an ancestor of origin/main. Run in tmux, it let me keep
  editing and building in my own worktree; it handled every race without help. Worth making a shared tool.
