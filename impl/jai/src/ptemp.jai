// `ptemp`, which is what `temp` means in our code (ir.jai): the allocator for pass-scoped scratch memory (performance
// only; the lifetime rules of Jai's `temp`: everything is released by reset_temporary_storage(), which the pass
// managers call after every pass; our reset_temporary_storage below resets both).
//
// Why not Basic's `temp`: its allocator proc costs ~75 instructions per call and a growing [..] array always
// moves (RESIZE allocates a new block and copies); temp allocation was ~5% of -O2. This is a bump allocator over
// 8 MB blocks that extends the most recent allocation in place, rolls back a FREE of the most recent allocation,
// and keeps its blocks across resets (they are faulted in once).

PTEMP_BLOCK_SIZE :: 8 * 1024 * 1024;

Ptemp_Block :: struct { next: *Ptemp_Block; size: s64; }   // header; the data follows (16-byte aligned)
PTEMP_HEADER :: 16;

ptemp_state: struct {
    cur: *u8;              // next free byte of the current block
    end: *u8;              // end of the current block
    last: *u8;             // start of the most recent allocation (for in-place RESIZE / FREE)
    used_blocks: *Ptemp_Block;   // blocks in use, current first
    free_blocks: *Ptemp_Block;   // blocks kept for reuse (standard size only)
    bytes: s64;            // bytes handed out since the last reset (for -time-passes)
    high_water: s64;
};

ptemp :: Allocator.{ptemp_proc, null};
// Every `temp` in our code means ptemp (ir.jai imports Basic without its `temp`).
temp :: ptemp;

ptemp_new_block :: (min_size: s64) {
    b: *Ptemp_Block = null;
    if min_size <= PTEMP_BLOCK_SIZE && ptemp_state.free_blocks {
        b = ptemp_state.free_blocks;
        ptemp_state.free_blocks = b.next;
    } else {
        size := max(min_size, PTEMP_BLOCK_SIZE);
        b = cast(*Ptemp_Block) alloc(size + PTEMP_HEADER,, allocator = context.default_allocator);
        b.size = size;
    }
    b.next = ptemp_state.used_blocks;
    ptemp_state.used_blocks = b;
    ptemp_state.cur = (cast(*u8) b) + PTEMP_HEADER;
    ptemp_state.end = ptemp_state.cur + b.size;
    ptemp_state.last = null;
}

ptemp_alloc :: inline (size_in: s64) -> *void {
    size := (size_in + 7) & ~7;
    if size > ptemp_state.end - ptemp_state.cur ptemp_new_block(size);
    p := ptemp_state.cur;
    ptemp_state.cur += size;
    ptemp_state.last = p;
    ptemp_state.bytes += size;
    return p;
}

ptemp_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    if mode == {
      case .ALLOCATE;
        return ptemp_alloc(requested_size);
      case .RESIZE;
        if old_memory == null return ptemp_alloc(requested_size);
        old_rounded := (old_size + 7) & ~7;
        if requested_size <= old_rounded return old_memory;
        new_rounded := (requested_size + 7) & ~7;
        // the most recent allocation grows in place when the block has room
        if cast(*u8) old_memory == ptemp_state.last && ptemp_state.last + new_rounded <= ptemp_state.end {
            ptemp_state.bytes += new_rounded - (ptemp_state.cur - ptemp_state.last);
            ptemp_state.cur = ptemp_state.last + new_rounded;
            return old_memory;
        }
        p := ptemp_alloc(requested_size);
        memcpy(p, old_memory, min(old_size, requested_size));
        return p;
      case .FREE;
        // the most recent allocation is rolled back; anything else waits for the reset
        if old_memory && cast(*u8) old_memory == ptemp_state.last {
            ptemp_state.bytes -= ptemp_state.cur - ptemp_state.last;
            ptemp_state.cur = ptemp_state.last;
            ptemp_state.last = null;
        }
        return null;
      case .STARTUP; #through;
      case .SHUTDOWN; #through;
      case .THREAD_START; #through;
      case .THREAD_STOP;
        return null;
      case .CAPS;
        if old_memory { (cast(*string) old_memory).* = "ptemp (impl/jai/src/ptemp.jai)"; }
        return cast(*void) (Allocator_Caps.HINT_I_AM_PER_FRAME_TEMPORARY_STORAGE | .FREE | .ACTUALLY_RESIZE);
    }
    assert(false, "ptemp_proc: unsupported allocator mode %", mode);
    return null;
}

// Releases everything (blocks go to the free list; oversized ones back to the heap).
ptemp_reset :: () {
    ptemp_state.high_water = max(ptemp_state.high_water, ptemp_state.bytes);
    b := ptemp_state.used_blocks;
    while b {
        next := b.next;
        if b.size == PTEMP_BLOCK_SIZE { b.next = ptemp_state.free_blocks; ptemp_state.free_blocks = b; }
        else free(b,, allocator = context.default_allocator);
        b = next;
    }
    ptemp_state.used_blocks = null;
    ptemp_state.cur = null; ptemp_state.end = null; ptemp_state.last = null;
    ptemp_state.bytes = 0;
}

// get_temporary_storage_mark / set_temporary_storage_mark for ptemp: memory allocated after the mark is released
// (the blocks opened since go back to the free list).
Ptemp_Mark :: struct { block: *Ptemp_Block; cur: *u8; end: *u8; bytes: s64; }
ptemp_get_mark :: () -> Ptemp_Mark {
    return .{ptemp_state.used_blocks, ptemp_state.cur, ptemp_state.end, ptemp_state.bytes};
}
ptemp_set_mark :: (m: Ptemp_Mark) {
    ptemp_state.high_water = max(ptemp_state.high_water, ptemp_state.bytes);
    while ptemp_state.used_blocks != m.block {
        b := ptemp_state.used_blocks;
        ptemp_state.used_blocks = b.next;
        if b.size == PTEMP_BLOCK_SIZE { b.next = ptemp_state.free_blocks; ptemp_state.free_blocks = b; }
        else free(b,, allocator = context.default_allocator);
    }
    ptemp_state.cur = m.cur; ptemp_state.end = m.end; ptemp_state.last = null;
    ptemp_state.bytes = m.bytes;
}

// Basic's reset_temporary_storage (excluded by ir.jai's import): what the pass managers call between passes, so
// it releases both kinds of scratch memory.
reset_temporary_storage :: () {
    Basic.reset_temporary_storage();
    ptemp_reset();
}
