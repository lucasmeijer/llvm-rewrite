# impl/jai notes

- The compiler (beta 0.2.030) isn't in the workspace image, because its download URL is private. `build.sh` calls
  `scripts/ensure-jai.sh`, which installs it once into `/persistent/toolchains/jai` from the `JAI_COMPILER_URL`
  environment variable. Never write that URL into the repo, reports or logs. If it's missing, stop and say so in a
  challenge report.
- Docs: `/persistent/toolchains/jai/how_to/*.jai` (numbered tutorials), `README.txt`, `CHANGELOG.txt`, and the module
  sources in `/persistent/toolchains/jai/modules`. Training data for Jai is thin and the language changes between
  betas, so check against the how_to files and modules rather than relying on memory.
- `build.sh` compiles each `src/<tool>.jai` with the x64 backend (`-x64`, fast compiles). The LLVM backend
  (default without `-x64`, `-o` for optimized) is slower to build but produces faster code. Switch when performance
  matters. Using a build metaprogram (`first.jai` with `#run`) is idiomatic. Feel free to restructure, as long
  as `build.sh` still produces `bin/{opt,llc,llvm-link}` incrementally.
- The binaries are placeholders that exit with "not implemented yet". Unit `L0.design` (writing `DESIGN.md`) comes first.
