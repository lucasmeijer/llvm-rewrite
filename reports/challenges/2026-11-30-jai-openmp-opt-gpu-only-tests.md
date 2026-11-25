# OpenMPOpt's device code is tested almost only by GPU-target LLVM tests that the importer skips

- **Date / implementation / unit:** 2026-11-30 / jai / L1.extra.openmp-opt
- **What happened:** the unit's exit tests (21 imported files) cover the host transformations and only a few device
  paths. The interesting device code (SPMDization with guarded regions, custom state machines, deglobalization,
  kernel environment folding) is tested by ~35 LLVM files that the importer skips because their RUN lines pass
  `-mtriple=nvptx64` / `amdgpu` or the file has a GPU `target triple`. OpenMPOpt itself does not need the triple
  (device code is recognized by the `"openmp-device"` module flag), so the same files run fine without it.
- **Time or effort lost:** little, but only because I noticed; a port that passes the exit tests and the default<O2>
  sweep would have left most of AAKernelInfo / AAExecutionDomain untested.
- **What would have helped:** an importer option to keep a GPU-only test with the triple and `-mtriple` stripped
  when the pass under test is target-independent (or a note in the roadmap unit that its coverage is thin).
- **What you did instead:** `tests/pass/openmp-opt/` holds 32 such derived files (header says how they were
  derived; the ones using nvvm / amdgcn intrinsics were left out because gen_intrinsics.jai does not know them),
  added to the unit's exit selector. They found two real bugs (AAHeapToStack's globalized-local check and
  address-space idents). Sweeping with `debugify,` in front of the pass found debug-record placement bugs no test
  had; worth suggesting for every pass that creates instructions.
