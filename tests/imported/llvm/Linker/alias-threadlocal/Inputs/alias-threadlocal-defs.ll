; @origin: llvm/test/Linker/Inputs/alias-threadlocal-defs.ll (llvmorg-23.1.5)
@tlsvar1 = thread_local global i32 0, align 4
@tlsvar2 = hidden thread_local alias i32, ptr @tlsvar1
