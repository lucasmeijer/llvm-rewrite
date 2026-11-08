#!/usr/bin/env bash
# Builds llvm-min-tblgen from /opt/llvm-project-23.1.5/llvm (no CMake: the llvm-project top-level cmake/ and
# third-party/ directories are not in the workspace) and writes IntrinsicImpl.inc next to it.
# Output: $OUT/min-tblgen, $OUT/IntrinsicImpl.inc (default OUT=/persistent/llvm-rewrite/min-tblgen).
# Used by tools/gen_intrinsics.py. Takes ~15 s on 16 cores.
set -euo pipefail
L=/opt/llvm-project-23.1.5/llvm
OUT=${OUT:-/persistent/llvm-rewrite/min-tblgen}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT/inc/llvm/Config" "$OUT/inc/shared" "$OUT/inc/siphash" "$OUT/obj"
cd "$OUT"
python3 "$HERE/tblgen_config.py"
sed -i 's/""x86_64-unknown-linux-gnu""/"x86_64-unknown-linux-gnu"/; s/""23.1.5""/"23.1.5"/' inc/llvm/Config/llvm-config.h
sed -i 's/""x""/"x"/; s/<<execinfo.h>>/<execinfo.h>/' inc/llvm/Config/config.h
echo '#define HAVE_SYSEXITS_H 1' >> inc/llvm/Config/config.h
echo '#define HAVE_SYSEXITS_H 1' >> inc/llvm/Config/llvm-config.h
# Stubs for libc's shared math (only APFloat's exp folding uses it) and siphash (not used by TableGen).
cat > inc/shared/math.h <<'H'
#include <cmath>
namespace LIBC_NAMESPACE { namespace shared { namespace check { inline int exp_exceptions(float, int){return 0;} inline int exp_exceptions(double,int){return 0;} }
inline float expf(float x){return std::exp(x);} inline double exp(double x){return std::exp(x);} } }
H
echo '#include <cfenv>' > inc/shared/math_check_exceptions.h
cat > inc/siphash/SipHash.h <<'H'
#include <cstdint>
#include <cstddef>
template <int C, int D, typename T> void siphash(const unsigned char *, size_t, const unsigned char (&)[16], T &out) { for (auto &x : out) x = 0; }
H
ls $L/lib/Support/*.cpp $L/lib/Support/*.c $L/lib/TableGen/*.cpp $L/utils/TableGen/Basic/*.cpp \
   $L/utils/TableGen/llvm-min-tblgen.cpp $L/lib/Demangle/*.cpp | while read f; do echo "$f obj/$(echo "$f" | md5sum | cut -c1-12).o"; done > list.txt
export L OUT
xargs -P "$(nproc)" -n 2 sh -c 'case "$0" in
  *.c) /opt/llvm-23.1.5/bin/clang -O1 -c -I$OUT/inc -I$L/include "$0" -o "$1" ;;
  *) /opt/llvm-23.1.5/bin/clang++ -std=c++17 -O1 -c -I$OUT/inc -I$L/include -I$L/utils/TableGen -I$L/lib/Support "$0" -o "$1" ;;
esac' < list.txt
/opt/llvm-23.1.5/bin/clang++ obj/*.o -o min-tblgen -lpthread -ldl
./min-tblgen -gen-intrinsic-impl -I $L/include $L/include/llvm/IR/Intrinsics.td -o IntrinsicImpl.inc
echo "built $OUT/min-tblgen and $OUT/IntrinsicImpl.inc"
