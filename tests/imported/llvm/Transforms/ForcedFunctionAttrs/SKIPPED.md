# Skipped while importing llvm/test/Transforms/ForcedFunctionAttrs (llvmorg-23.1.5)

1 of 3 files imported. Regenerate with `./harness/run import-llvm Transforms/ForcedFunctionAttrs`.

- `FunctionAnnotator.ll` RUN `opt -passes='forceattrs' -forceattrs-csv-path="%S/FunctionAnnotation.csv" -S < %s | FileCheck %s`: uses lit substitution -forceattrs-csv-path=%S/FunctionAnnotation.csv
- `FunctionAnnotator.ll` RUN `opt -passes='forceattrs' -forceattrs-csv-path="%S/DoesNotExist.csv" -S < %s 2>&1 | FileCheck %s --check-prefix=NonexistentFunc`: uses lit substitution -forceattrs-csv-path=%S/DoesNotExist.csv
- `open-file-error.ll` RUN `not opt -disable-output -passes='forceattrs' -forceattrs-csv-path="%S/CannotOpenFile.csv"  %s 2>&1 | FileCheck -DMSG=%errc_ENOENT %s`: not an opt invocation
