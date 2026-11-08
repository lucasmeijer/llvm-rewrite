# L1.sccp hides FunctionSpecialization, PredicateInfo and half of ConstantFolding

- **Date / implementation / unit:** 2026-11-09 / goose / L1.sccp
- **What happened:** The unit says "SCCP and IPSCCP", but reproducing them needs PredicateInfo (a separate
  880-line utility), a full ConstantRange and an arbitrary-width APInt, ValueLatticeElement, and, because
  `ipsccp` enables function specialization by default, FunctionSpecialization.cpp with CodeMetrics and the
  TTI code-size model. The imported SCCP tests never trigger specialization, so the unit can be completed
  without it, but every real program (sqlite3, lua, SPASS) reaches the specializer's candidate check, so
  `ipsccp` in an `-O2` pipeline stops loudly. Several of the remaining failures were ConstantFolding gaps
  (vector bitcasts, denormal modes, constrained fcmp, libm calls) in a file owned by another agent who was
  still working on it; I asked twice who should fix them and got no answer, so I fixed the ones SCCP needed.
- **Time or effort lost:** about an hour on coordination and rebases: two agents picked the same pass id
  (150) in passmgr.goose, giving a rebase conflict, and the arbitrary-width APInt rewrite landed under my
  constrange.goose midway. Also ~10 minutes self-inflicted: a `git checkout <file>` to undo a temporary
  experiment threw away an uncommitted edit.
- **What would have helped:** a roadmap entry listing the utilities a pass unit depends on
  (PredicateInfo, FunctionSpecialization) and whether default-on sub-features like `ipsccp`'s func-spec are in
  scope; a convention for allocating pass ids (or ids generated from the pass table) so concurrent agents
  don't collide; an owner per shared file (cfold.goose) who answers "may I change X".
- **What you did instead:** ported everything except FunctionSpecialization, which fails loudly only when a
  function could really be specialized (a candidate with a constant call-site argument and a code-size
  over-estimate of at least 500). Measured that LLVM's ipsccp output on the three perf programs equals the
  no-specialization output, and wrote that down in NOTES.md and knowledge/llvm/sccp.md. A sweep of sccp and
  ipsccp over all 6800 imported test files, compared with LLVM, found 7 bugs that the unit's own tests missed;
  sweeps like that should be part of every pass unit's checklist.
