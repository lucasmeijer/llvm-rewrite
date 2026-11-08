# impl/zig notes

- Toolchain: Zig 0.17.1 at `/opt/zig-0.17.1` (on PATH). The std library source is `/opt/zig-0.17.1/lib/std`. Its
  APIs (especially I/O, `std.Io`) change between releases, so read the source rather than relying on memory.
- `build.sh` runs `zig build -Doptimize=ReleaseSafe --prefix .`. The first build in a fresh workspace compiles Zig's
  build runner and takes about 2 minutes. After that, builds are cached and no-op builds take about 50 ms. Calling
  `zig build-exe` directly does not cache and takes about 15 s per binary.
- The binaries are placeholders that exit with "not implemented yet". Unit `L0.design` (writing `DESIGN.md`) comes first.
