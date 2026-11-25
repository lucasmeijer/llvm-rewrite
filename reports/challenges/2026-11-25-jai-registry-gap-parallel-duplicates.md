# A "port everything left in the registry" task collides with every other agent's unit

- **Date / implementation / unit:** 2026-11-25 / jai / L1.extra.registry-gaps (/root/jai_registry_gap)
- **What happened:** the task was to diff PassRegistry.def against jai's pass table and port the rest, skipping
  what five named agents owned. The ownership list was by *unit name* ("utility", "analysis-misc", "inliner
  tail"), not by pass name, so I had to read docs/roadmap.md exit selectors to map units to passes, and three
  passes were ported twice anyway because the owning unit's scope wasn't visible from the registry name:
  print<stack-lifetime> (extras_b's analysis-misc covered it through StackSafetyAnalysis), replace-with-veclib
  (another agent pulled it into L1.vectorize.loop while I ported it, same file name, so the rebase conflicted on a
  whole file), and DebugInfoFinder (extras_b's strip-dead-debug-info needed it; I found out from port-progress.txt
  after porting a second one for print<module-debuginfo>, and the two had overlapping `dif_*` procedure names that
  Jai silently overloaded).
- Other friction:
  - `Pass_Kind :: enum u8` had exactly 256 values when I started; another agent widened it the same hour.
  - `PASS_TABLE` rows are positional struct literals, and Jai requires every field in a positional literal, so a
    new `Pass_Info` field means editing all ~400 rows (a guaranteed conflict with every other agent). I added a
    parallel `Gap_Kind` array instead.
  - Every publish rebased onto 1-3 new commits; append-only files (impl/jai/NOTES.md, port-progress.txt) conflict
    each time, and a full `check --update` (~10 min) runs between fetch and push, so the race repeats. Twice I
    chained `git rebase ... | tail` and the check ran on a tree with conflict markers.
  - Background sweeps started from a Bash tool call died with the call; they need a tmux session. A second
    worktree for sweeps (checked out at my branch head) was the only way to keep building in the main worktree
    while a 30-minute sweep ran.
- **Time or effort lost:** ~1.5 h on duplicates and conflict resolution, ~30 min on a lost sweep.
- **What would have helped:**
  - Ownership given as pass names (or a shared `owners.txt`: registry name -> agent), so a gap list can be filtered
    mechanically.
  - A rule that agents claim a pass/utility in a shared file *before* porting it (one line, pushed at once).
  - NOTES.md split into one file per area (`impl/jai/notes/<area>.md`) so concurrent appends don't conflict.
  - `harness/run check --update` refusing to run when the tree has unmerged paths.
- **What I did instead:** dropped my duplicates in favour of what had landed (keeping theirs), renamed my
  DebugInfoFinder procedures (`mdi_*`) and noted the duplicate as a design debt in NOTES.md; registered all my
  passes behind four Pass_Kind values and one table (registry_gaps.jai) to keep passes.jai edits to a few lines.
