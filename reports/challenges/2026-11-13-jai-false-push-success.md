# A rejected `git push` looked like a successful one to my publish loop

- **Date / implementation / unit:** 2026-11-13 / jai / L1.extra.guards .. L1.extra.loop-misc (/root/jai_loopextras_r)
- **What happened:** to follow the "commit, rebase, rerun the full check, push, retry on reject" rule with many
  agents pushing to main, I scripted the loop and decided success by grepping the push output for `-> main`. A
  rejected push prints `! [rejected]        HEAD -> main (fetch first)`, which matches too. Three units (guards,
  fusion/flatten, half of loop-misc) were reported "PUSHED" but never reached origin/main; I only noticed when a
  later rebase replayed commits I believed were upstream (`git merge-base --is-ancestor` said otherwise).
- **Time or effort lost:** ~30 minutes: one large conflict-resolving rebase of 8 commits (passes.jai, opt.jai,
  assume_builder.jai, port-progress.txt all touched by other agents meanwhile) plus an extra full check.
- **What would have helped:** a shared, tested `scripts/publish.sh` (rebase, `check --update`, push, decide on
  `git push`'s exit status, retry) instead of every agent writing its own loop; or a line in AGENTS.md: "verify the
  push with `git fetch && git merge-base --is-ancestor HEAD origin/main`".
- **What you did instead:** the loop now tests `git push`'s exit status and stops on any rebase conflict; after
  each publish I check `merge-base --is-ancestor`. The conflict resolver takes the union of both sides, dropping
  my lines that duplicate a line of theirs (two agents had added the same `weh_parse_cl_opt` call).
