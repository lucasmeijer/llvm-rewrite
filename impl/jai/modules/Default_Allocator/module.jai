// Replaces the compiler's modules/Default_Allocator (a stripped-down rpmalloc) for our tools: build.sh and
// build_optimized.jai put impl/jai/modules first in the import path, and Runtime_Support's
// `#import "Default_Allocator"` finds this one. Performance only (NOTES.md "Performance").
//
// Why: the stripped rpmalloc has no span cache, so a span that becomes empty is decommitted at once
// (madvise(MADV_DONTNEED)) and faulted back in by the next allocation. Our passes allocate and free analysis
// tables per function, so -O2 on SPASS.ll did ~1M page faults (2-3 s of system time; LLVM's opt: 0.07 s).
// This is glibc malloc with trimming and mmap of large blocks turned off: freed memory is reused, never returned.

#module_parameters (
    ENABLE_ASSERTS       := true,   // same parameters as the module this replaces (unused)
    ENABLE_VALIDATE_ARGS := true
)();

allocator :: Allocator.{allocator_proc, null};

allocator_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    if !initialized initialize();
    if mode == {
        case .ALLOCATE;
            return c_malloc(cast(u64) requested_size);
        case .RESIZE;
            return c_realloc(old_memory, cast(u64) requested_size);
        case .FREE;
            c_free(old_memory);
            return null;
        case .STARTUP; #through;
        case .SHUTDOWN; #through;
        case .THREAD_START; #through;
        case .THREAD_STOP;
            return null;
        case .CAPS;
            if old_memory { (cast(*string) old_memory).* = CAPS_VERSION_STRING; }
            return cast(*void) (Allocator_Caps.HINT_I_AM_A_GENERAL_HEAP_ALLOCATOR | .MULTIPLE_THREADS | .FREE | .ACTUALLY_RESIZE);
    }
    // CREATE_HEAP, DESTROY_HEAP, IS_THIS_YOURS: not supported (nothing in impl/jai uses them)
    context.handling_assertion_failure = true;
    context.assertion_failed(#location(), "Default_Allocator (impl/jai/modules, glibc malloc): unsupported allocator mode.\n");
    context.handling_assertion_failure = false;
    return null;
}

// Process/posix.jai calls this in a forked child (:AllocatorAfterFork:); glibc malloc handles fork itself.
unsafe_reset :: inline () { }
finalize :: () { }

#scope_module

CAPS_VERSION_STRING :: "glibc malloc (impl/jai/modules/Default_Allocator)";

libc :: #system_library "libc";
c_malloc  :: (size: u64) -> *void #foreign libc "malloc";
c_realloc :: (p: *void, size: u64) -> *void #foreign libc "realloc";
c_free    :: (p: *void) #foreign libc "free";
c_mallopt :: (param: s32, value: s32) -> s32 #foreign libc "mallopt";

M_TRIM_THRESHOLD :: -1;
M_TOP_PAD        :: -2;
M_MMAP_THRESHOLD :: -3;

initialized := false;
initialize :: () {
    initialized = true;
    // Fixed values also turn off glibc's dynamic mmap threshold.
    c_mallopt(M_MMAP_THRESHOLD, 32 * 1024 * 1024);   // the maximum glibc accepts on 64-bit
    c_mallopt(M_TRIM_THRESHOLD, 0x7FFF_FFFF);
    c_mallopt(M_TOP_PAD, 16 * 1024 * 1024);
}
