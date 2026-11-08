# The workspace image's toolchain layer can't be rebuilt: GitHub release downloads return 504

- **Date / implementation / unit:** 2026-11-08 / shared (workspace image) / harness perf work
- **What happened:** To add valgrind I appended it to the existing `apt-get install` line in
  `.agents-in-the-cloud/Dockerfile`. That changed the step's text, so Docker discarded the cached layer of every later
  step, including `install-toolchains.sh`. Re-running it fails: through this network's proxy, GitHub release downloads
  (the LLVM 23.1.5 tarball, Goose, and DynamoRIO, which I tried earlier) return `504 Gateway Time-out` after about 10 s.
  ziglang.org works. New workspaces failed to start until the Dockerfile was fixed.
- **Time or effort lost:** every new workspace was broken until the user reported it; about 15 minutes to diagnose and fix.
  Nothing in the workspace could test the change: there's a `docker` CLI but no daemon.
- **What would have helped:** a warning in the Dockerfile that the toolchain layer only exists in the build cache and
  can't be rebuilt from this network. Better: a mirror of the toolchain tarballs that doesn't depend on GitHub release
  downloads (e.g. `/persistent` or an internal URL), so the image can always be rebuilt.
- **What you did instead:** restored the earlier steps byte for byte, so the cached layers match again, and installed
  valgrind in a new `RUN` step after the toolchains. The Dockerfile now says to add packages that way. Changing
  `install-toolchains.sh` itself (e.g. a new LLVM or Goose version) will hit the same 504 until downloads work or are
  mirrored.
