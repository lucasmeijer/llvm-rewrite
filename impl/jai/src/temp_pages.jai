// Temporary storage setup (performance only; no effect on output).
//
// Passes allocate freely from `temp` and the pass managers call reset_temporary_storage() after every pass. Jai's
// default temporary storage is a 32 KB block plus overflow pages of the same size taken from the default allocator
// (a stripped rpmalloc), and every reset frees all overflow pages; rpmalloc then decommits the spans (madvise
// DONTNEED), so the next pass faults the same memory back in. On -O2 SPASS.ll that was ~1.3M page faults and 3.4 s
// of system time (LLVM: 0.07 s). Here the base block is 8 MB, overflow pages are 8 MB, and a freed overflow page
// is kept on a free list for the next one instead of going back to the heap: memory peaks at the largest temp use
// of one pass, as before, but is faulted in once.

TEMP_BASE_SIZE :: 8 * 1024 * 1024;

Temp_Page_Block :: struct { next: *Temp_Page_Block; size: s64; }   // header in front of every block we hand out
TEMP_PAGE_HEADER :: 16;
temp_page_free_list: *Temp_Page_Block;

temp_page_allocator_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    if mode == {
      case .ALLOCATE;
        // reuse a free block that is big enough but not more than twice the size (huge one-off requests go back)
        prev: *Temp_Page_Block = null;
        b := temp_page_free_list;
        while b {
            if b.size >= requested_size && b.size <= 2 * requested_size {
                if prev prev.next = b.next; else temp_page_free_list = b.next;
                b.next = null;
                return (cast(*u8) b) + TEMP_PAGE_HEADER;
            }
            prev = b;
            b = b.next;
        }
        mem := alloc(requested_size + TEMP_PAGE_HEADER,, allocator = context.default_allocator);
        if !mem return null;
        nb := cast(*Temp_Page_Block) mem;
        nb.next = null;
        nb.size = requested_size;
        return (cast(*u8) mem) + TEMP_PAGE_HEADER;
      case .FREE;
        if !old_memory return null;
        b := cast(*Temp_Page_Block) ((cast(*u8) old_memory) - TEMP_PAGE_HEADER);
        b.next = temp_page_free_list;
        temp_page_free_list = b;
        return null;
      case .RESIZE;
        assert(false, "temp_page_allocator_proc: RESIZE is not used by the temporary storage");
        return null;
    }
    return null;
}

// Called first thing in main, before anything is allocated in temp.
temp_pages_setup :: () {
    ts := cast(*Temporary_Storage_Paged_Alloc) context.temporary_storage;
    if !ts return;
    reset_temporary_storage();
    base := alloc(TEMP_BASE_SIZE,, allocator = context.default_allocator);
    ts.data = base;
    ts.size = TEMP_BASE_SIZE;
    ts.current_page_bytes_occupied = 0;
    ts.total_bytes_occupied = 0;
    ts.overflow_allocator = .{temp_page_allocator_proc, null};
}
