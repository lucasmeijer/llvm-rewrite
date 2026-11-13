// -time-passes (llvm/lib/IR/PassTimingInfo.cpp, TimePassesHandler), for profiling only: CPU time per pass name,
// with LLVM's nesting rule (a pass's time excludes the passes nested in it: starting a pass pauses the running one).
// Unlike LLVM, analyses are not timed separately: an analysis computed on demand is charged to the pass that asked.
// The report goes to stderr; its layout is ours (LLVM's is not compared by any check).

tp_libc :: #system_library "libc";
Tp_Timespec :: struct { sec: s64; nsec: s64; }
tp_clock_gettime :: (clk: s32, ts: *Tp_Timespec) -> s32 #foreign tp_libc "clock_gettime";
TP_CLOCK_PROCESS_CPUTIME_ID :: 2;

time_passes := false;

Tp_Entry :: struct { name: string; ns: s64; runs: s64; temp_peak: s64; }   // temp_peak: temporary storage high-water mark at the end of a run
tp_entries: [..] Tp_Entry;
tp_index: Table(string, s64);
tp_stack: [..] s64;      // entry indices of the running passes, innermost last
tp_last: s64;            // clock at the last push/pop

tp_now :: () -> s64 {
    ts: Tp_Timespec;
    tp_clock_gettime(TP_CLOCK_PROCESS_CPUTIME_ID, *ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

tp_begin :: (name: string) {
    now := tp_now();
    if tp_stack.count tp_entries[tp_stack[tp_stack.count - 1]].ns += now - tp_last;
    key := bisect_pass_name(name);
    found, idx := table_find(*tp_index, key);
    if !found {
        idx = tp_entries.count;
        array_add(*tp_entries, .{name = copy_string(key), ns = 0, runs = 0});
        table_set(*tp_index, tp_entries[idx].name, idx);
    }
    tp_entries[idx].runs += 1;
    array_add(*tp_stack, idx);
    tp_last = now;
}

tp_end :: () {
    now := tp_now();
    e := *tp_entries[tp_stack[tp_stack.count - 1]];
    e.ns += now - tp_last;
    if context.temporary_storage e.temp_peak = max(e.temp_peak, context.temporary_storage.high_water_mark + max(ptemp_state.bytes, ptemp_state.high_water));
    ptemp_state.high_water = 0;
    tp_stack.count -= 1;
    tp_last = now;
}

tp_report :: () {
    if !time_passes return;
    order := NewArray(tp_entries.count, s64,, allocator = temp);
    for 0..tp_entries.count - 1 order[it] = it;
    // insertion sort by time, descending (few dozen entries)
    for i: 1..order.count - 1 {
        j := i;
        while j > 0 && tp_entries[order[j - 1]].ns < tp_entries[order[j]].ns { order[j - 1], order[j] = order[j], order[j - 1]; j -= 1; }
    }
    total: s64 = 0;
    for tp_entries total += it.ns;
    sb: String_Builder;
    print_to_builder(*sb, "===-- jai -time-passes: CPU seconds per pass (nested passes excluded; analyses charged to the caller), peak temp storage of one run --===\n");
    for order {
        e := tp_entries[it];
        print_to_builder(*sb, "  % s %  % runs  % MB temp  %\n", formatFloat(cast(float64) e.ns / 1000000000.0, width = 9, trailing_width = 4),
            formatFloat(100.0 * cast(float64) e.ns / cast(float64) max(total, 1), width = 5, trailing_width = 1), formatInt(e.runs, minimum_digits = 6, padding = #char " "),
            formatInt(e.temp_peak / (1024 * 1024), minimum_digits = 5, padding = #char " "), e.name);
    }
    print_to_builder(*sb, "  %  total\n", formatFloat(cast(float64) total / 1000000000.0, width = 9, trailing_width = 4));
    write_string(builder_to_string(*sb), to_standard_error = true);
}
