# Skipped while importing llvm/test/Transforms/Internalize (llvmorg-23.1.5)

9 of 9 files imported. Regenerate with `./harness/run import-llvm Transforms/Internalize`.

- `comdat.ll` RUN `opt < %s -mtriple=wasm32 -passes=internalize -internalize-public-api-list main -internalize-public-api-list c1 -internalize-public-api-list c2 -internalize-public-api-list c3 -internalize-public-api-list c4 -S | FileCheck %s --check-prefixes=CHECK,WASM`: non-x86_64 target wasm32
- `lists.ll` RUN `opt < %s -passes=internalize -internalize-public-api-file /nonexistent/file 2> /dev/null -S | FileCheck --check-prefix=ALL %s`: redirects or chains commands
- `lists.ll` RUN `opt < %s -S -passes=internalize -internalize-public-api-list bar -internalize-public-api-list foo -internalize-public-api-file /nonexistent/file  2> /dev/null | FileCheck --check-prefix=FOO_AND_BAR %s`: redirects or chains commands
- `lists.ll` RUN `opt < %s -passes=internalize -internalize-public-api-list bar -internalize-public-api-file %S/apifile -S | FileCheck --check-prefix=FOO_J_AND_BAR %s`: uses lit substitution %S/apifile
- `stackguard.ll` RUN `opt -mtriple=powerpc64-ibm-aix-xcoff < %s -passes=internalize -S | FileCheck %s --check-prefix=AIX`: non-x86_64 target powerpc64-ibm-aix-xcoff
