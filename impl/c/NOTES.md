# impl/c notes

- Compiler: `/opt/llvm-23.1.5/bin/clang`, C11, `-Wall -Wextra -Werror` (see `build.sh`). Feel free to replace the
  build script, but it must stay incremental and fast, and it must produce `bin/{opt,llc,llvm-link}`.
- The sources are placeholders that exit with "not implemented yet". Unit `L0.design` (writing `DESIGN.md`) comes first.
