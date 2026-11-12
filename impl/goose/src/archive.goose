// Snapshot archives: how an analysis that lives in global tables (one loaded instance at a time) keeps one result
// per function, as LLVM's FunctionAnalysisManager does (DESIGN.md §9.1). Generic helpers only; each analysis owns
// its directory and pools (ScalarEvolution: scev_archive.goose, MemorySSA: memoryssa.goose, AssumptionCache:
// assume.goose).
//
// A directory is two arrays: `own[s]` = the function snapshot s belongs to (-1 = dead: restored or dropped) and
// `dir` = `nt` (start, length) pairs per snapshot, one pair per table. A table's runs live in a pool of its element
// type; several tables may share a pool. Runs are appended in (snapshot, table) order, so `ar_compact` can move
// the live runs of a pool down in place (walking snapshots in order, and the pool's tables in increasing order),
// and `ar_drop_dead` then squeezes the dead rows out of the directory.
import std;

// a new snapshot row for fv; returns its index
fn ar_new(own: i32[>..<]&, dir: i64[>..<]&, nt: i64, fv: i32) -> i64 {
    let s = own.len;
    own.push(fv);
    for k in nt * 2 { dir.push(0); }
    return s;
}
// table t of snapshot s := a copy of src (appended to pool)
fn ar_put(dir: i64[>..<]&, nt: i64, s: i64, t: i64, pool, src) {
    let at = (s * nt + t) * 2;
    dir[at] = pool.len;
    dir[at + 1] = src.len;
    pool.append(src[..]);
}
// dst := table t of snapshot s
fn ar_get(dir: i64[>..<]&, nt: i64, s: i64, t: i64, pool, dst) {
    let at = (s * nt + t) * 2;
    let a = dir[at];
    let n = dir[at + 1];
    dst.resize(0);
    dst.append(pool[a..a + n]);
}
fn ar_len(dir: i64[>..<]&, nt: i64, s: i64, t: i64) -> i64 { dir[(s * nt + t) * 2 + 1] }
fn ar_at(dir: i64[>..<]&, nt: i64, s: i64, t: i64) -> i64 { dir[(s * nt + t) * 2] }

// moves the live runs of the tables `ts` (all the tables stored in `pool`, increasing) to the front of the pool
fn ar_compact(own: i32[>..<]&, dir: i64[>..<]&, nt: i64, ts: const i64[:], pool) {
    var cur: i64 = 0;
    for s in own.len {
        if own[s] < 0 { continue; }
        for t in ts {
            let at = (s * nt + t) * 2;
            let a = dir[at];
            let n = dir[at + 1];
            if a != cur {
                for k in n { pool[cur + k] = pool[a + k]; }
                dir[at] = cur;
            }
            cur += n;
        }
    }
    pool.resize(cur);
}
// removes dead rows (after every pool was compacted); `slot` maps a function's glob index to its row + 1, and is
// renumbered
fn ar_drop_dead(own: i32[>..<]&, dir: i64[>..<]&, nt: i64, slot: i32[>..]&, gl: i32[>..<]&) {
    var w: i64 = 0;
    for s in own.len {
        if own[s] < 0 { continue; }
        if w != s {
            own[w] = own[s];
            for k in nt * 2 { dir[w * nt * 2 + k] = dir[s * nt * 2 + k]; }
        }
        slot[gl[s]] = (w + 1) as i32;
        gl[w] = gl[s];
        w++;
    }
    own.resize(w);
    gl.resize(w);
    dir.resize(w * nt * 2);
}
