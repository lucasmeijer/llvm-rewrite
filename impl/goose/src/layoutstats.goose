// -goose-layout-stats (opt): table sizes of the IR core and the big scratch tables, on stderr, after the pipeline.
// A measuring aid for layout work (DESIGN.md §2, §7); not an LLVM option.
import std;
import os;
import ir;
import irutil;
import sroa;

fn ls_line(out: u8[>..]&, name: const u8[:], n: i64, bytes: i64) {
    format(out, name, ": ", n, " (", bytes / 1024, " KiB)\n");
}

fn layout_stats_print() {
    var out: u8[>..] = [];
    var dead = 0;
    var live_cap = 0;
    for v in vals.len {
        if vals[v].kind == VK_DEAD { dead++; } else { live_cap += vals[v].cap as i64; }
    }
    ls_line(out, "vals", vals.len, bytes_of(vals).len);
    format(out, "  dead vals: ", dead, "\n");
    ls_line(out, "uses", uses.len, bytes_of(uses).len + bytes_of(use_aux).len);
    format(out, "  uses outside live operand runs (leaked or dead): ", uses.len - live_cap, "\n");
    ls_line(out, "insts", insts.len, bytes_of(insts).len);
    ls_line(out, "blocks", blocks.len, bytes_of(blocks).len);
    ls_line(out, "globs", globs.len, bytes_of(globs).len);
    ls_line(out, "types", types.len, bytes_of(types).len);
    ls_line(out, "csts", csts.len, bytes_of(csts).len);
    ls_line(out, "mds", mds.len, bytes_of(mds).len + bytes_of(md_ops).len);
    ls_line(out, "strs", strs.len, bytes_of(strs).len + bytes_of(chars).len);
    ls_line(out, "ints", ints.len, bytes_of(ints).len);
    ls_line(out, "vs/vm scratch", vs_stamp.len, bytes_of(vs_stamp).len + bytes_of(vm_stamp).len + bytes_of(vm_data).len);
    ls_line(out, "sroa scratch", sr_tab.len, bytes_of(sr_tab).len);
    write_stderr(out);
}
