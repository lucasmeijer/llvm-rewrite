# Skipped while importing llvm/test/Instrumentation/Instrumentor (llvmorg-23.1.5)

4 of 26 files imported. Regenerate with `./harness/run import-llvm Instrumentation/Instrumentor`.

- `bad_function_regexp.ll` RUN `not opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/bad_function_regex.json -S 2>&1 | FileCheck %s`: not an opt invocation
- `bad_spelling.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/bad_spelling_config.json -S 2>&1 | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/bad_spelling_config.json
- `cast.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/cast_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/cast_config.json
- `cast_filter.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/cast_filter_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/cast_filter_config.json
- `compare.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/compare_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/compare_config.json
- `counters.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/counters_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/counters_config.json
- `function_regex.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/function_regex.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/function_regex.json
- `generate_bad_rt.ll` RUN `not opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/bad_rt_config.json 2>&1 | FileCheck %s --ignore-case`: not an opt invocation
- `generate_rt.ll` RUN `rm -rf %t && mkdir -p %t && cd %t`: not an opt invocation
- `generate_rt.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/rt_config.json -S`: uses lit substitution -instrumentor-read-config-files=%S/rt_config.json
- `generate_rt.ll` RUN `diff -b default_rt.c %S/default_rt.c`: not an opt invocation
- `generate_rt.ll` RUN `diff -b default_rt.h %S/default_rt.h`: not an opt invocation
- `load_store.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/load_store_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/load_store_config.json
- `load_store_args.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/load_store_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/load_store_config.json
- `load_store_noreplace.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/load_store_noreplace_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/load_store_noreplace_config.json
- `multi_config.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/multi_config_1.json,%S/multi_config_2.json -instrumentor-read-config-paths-file=%S/multi_config_paths -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/multi_config_1.json,%S/multi_config_2.json
- `numeric.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/numeric_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/numeric_config.json
- `numeric_subtypeid.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/numeric_subtypeid_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/numeric_subtypeid_config.json
- `read_config.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/custom_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/custom_config.json
- `test_filter.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/test_filter_config.json
- `test_filter_bad.ll` RUN `not opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_malformed_filter.json -S 2>&1 | FileCheck %s --check-prefix=A`: not an opt invocation
- `test_filter_bad.ll` RUN `not opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_config_bad.json -S 2>&1 | FileCheck %s --check-prefix=B`: not an opt invocation
- `test_filter_bad.ll` RUN `not opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_errors.json -S 2>&1 | FileCheck %s --check-prefix=C`: not an opt invocation
- `test_filter_bad.ll` RUN `not opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_pointer_error.json -S 2>&1 | FileCheck %s --check-prefix=D`: not an opt invocation
- `test_filter_parentheses.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_parentheses_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/test_filter_parentheses_config.json
- `test_filter_pointer_null.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_pointer_null_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/test_filter_pointer_null_config.json
- `test_filter_strings.ll` RUN `opt < %s -passes=instrumentor -instrumentor-read-config-files=%S/test_filter_strings_config.json -S | FileCheck %s`: uses lit substitution -instrumentor-read-config-files=%S/test_filter_strings_config.json
- `write_config.ll` RUN `opt < %s -passes=instrumentor -instrumentor-write-config-file=%t.json`: uses lit substitution -instrumentor-write-config-file=%t.json
- `write_config.ll` RUN `diff -b %t.json %S/default_config.json`: not an opt invocation
