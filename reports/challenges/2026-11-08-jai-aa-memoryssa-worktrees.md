# Shared refs across git worktrees made `git diff origin/main..HEAD` look like I was deleting another impl's work

- **Date / implementation / unit:** 2026-11-10 / jai / L1.analysis.aa, L1.analysis.memoryssa
- **What happened:** Following the instructions, I worked in a git worktree and checked `git diff --stat
  origin/main..HEAD` before pushing. Worktrees share refs, so another agent's `git fetch` in its own worktree moved
  `origin/main` under me between my rebase and the check: the diff suddenly listed ~5000 deleted lines of
  `impl/goose/` (goose's freshly pushed AA port), which looked like my branch was reverting it. It wasn't: my branch
  was simply behind the new `origin/main`. A second rebase fixed it. Also, `passes.jai` (pass registry and `cl_opts`)
  conflicted on the first rebase because jai_instsimplify had changed the `Cl_Opt` struct (new field) in the same
  lines; positional struct literals (`.{"name", .BOOL, null, null}`) in my code then failed to compile.
- **Time or effort lost:** ~10 minutes, mostly double-checking that I hadn't destroyed anything.
- **What would have helped:** a note in AGENTS.md / the task template that `origin/main` can move at any time in a
  worktree setup, so "inspect the diff" should be "fetch, rebase, *then* inspect", immediately before the push.
  For Jai: a convention to register cl::opts with a helper (`add_cl_opt(name, *field)`) instead of positional
  literals, so adding a field to `Cl_Opt` doesn't break every registration.
- **What you did instead:** fetch + rebase immediately before every diff check and push; my AA/MemorySSA options
  are registered from `aa.jai` through one `add_aa_cl_opts(list, start)` call, so `passes.jai` only has a two-line
  hook. Analysis-heavy code that can live in its own files did (8 new files, ~40 lines touched in shared files).
- **Jai trap worth knowing (also in NOTES):** `print`/`tprint` treat every `%` as a placeholder, even `"%/"`; a literal
  percent sign is the byte 31 (`"\x1f"`), which Basic's formatter turns into `%`.
