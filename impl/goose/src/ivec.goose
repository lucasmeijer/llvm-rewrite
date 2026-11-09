// Growable i32 vectors addressed by a handle (SmallVector<T *> stand-in for data structures whose elements
// own vectors: LazyCallGraph nodes, SCCs and RefSCCs, inliner worklists). A vector is a record in `ivr`
// (start, length, capacity) whose elements are a run in `ivd`; growing copies the run to the end of the pool
// (the old run is not reused). Handles are never reused; `iv_reset()` drops every vector at once (the owner
// is a module analysis such as the LazyCallGraph, rebuilt from scratch).
import std;

struct IVRec { at: i32, n: i32, cap: i32 }
var ivr: IVRec[>..];
var ivd: i32[>..];

fn iv_reset() { ivr.resize(0); ivd.resize(0); }
fn iv_new() -> i32 { let h = ivr.len as i32; ivr.push(IVRec { at: 0, n: 0, cap: 0 }); return h; }
fn iv_len(h: i32) -> i64 { ivr[h].n as i64 }
fn iv_get(h: i32, k: i64) -> i32 { ivd[(ivr[h].at as i64) + k] }
fn iv_set(h: i32, k: i64, v: i32) { ivd[(ivr[h].at as i64) + k] = v; }
fn iv_back(h: i32) -> i32 { iv_get(h, iv_len(h) - 1) }
fn iv_clear(h: i32) { ivr[h].n = 0; }
fn iv_reserve(h: i32, need: i64) {
    let cap = ivr[h].cap as i64;
    if need <= cap { return; }
    var ncap = cap * 2;
    if ncap < 4 { ncap = 4; }
    while ncap < need { ncap *= 2; }
    let nat = ivd.len;
    let at = ivr[h].at as i64;
    let n = ivr[h].n as i64;
    for k in n { let e = ivd[at + k]; ivd.push(e); }
    for k in ncap - n { ivd.push(-1); }
    ivr[h].at = nat as i32;
    ivr[h].cap = ncap as i32;
}
fn iv_push(h: i32, v: i32) {
    let n = iv_len(h);
    iv_reserve(h, n + 1);
    ivd[(ivr[h].at as i64) + n] = v;
    ivr[h].n = (n + 1) as i32;
}
fn iv_pop(h: i32) -> i32 { let v = iv_back(h); ivr[h].n--; return v; }
fn iv_resize(h: i32, n: i64) {
    let old = iv_len(h);
    iv_reserve(h, n);
    for k in old..n { iv_set(h, k, -1); }
    ivr[h].n = n as i32;
}
// Append every element of `src` (src != h).
fn iv_append(h: i32, src: i32) {
    let m = iv_len(src);
    for k in m { iv_push(h, iv_get(src, k)); }
}
fn iv_copy(dst: i32, src: i32) { iv_clear(dst); iv_append(dst, src); }
// Exchange the contents of two vectors (SmallVector::swap).
fn iv_swap(a: i32, b: i32) { let t = ivr[a]; ivr[a] = ivr[b]; ivr[b] = t; }
// Insert `cnt` elements of `src` starting at `from` before position `at` (vector::insert(pos, first, last)).
fn iv_insert_range(h: i32, at: i64, src: i32, from: i64, cnt: i64) {
    let n = iv_len(h);
    iv_reserve(h, n + cnt);
    ivr[h].n = (n + cnt) as i32;
    var k = n - 1;
    while k >= at { iv_set(h, k + cnt, iv_get(h, k)); k--; }
    for j in cnt { iv_set(h, at + j, iv_get(src, from + j)); }
}
fn iv_insert(h: i32, at: i64, v: i32) {
    let n = iv_len(h);
    iv_reserve(h, n + 1);
    ivr[h].n = (n + 1) as i32;
    var k = n - 1;
    while k >= at { iv_set(h, k + 1, iv_get(h, k)); k--; }
    iv_set(h, at, v);
}
// Erase [b, e).
fn iv_erase_range(h: i32, b: i64, e: i64) {
    let n = iv_len(h);
    let d = e - b;
    for k in e..n { iv_set(h, k - d, iv_get(h, k)); }
    ivr[h].n = (n - d) as i32;
}
fn iv_find(h: i32, v: i32) -> i64 {
    let n = iv_len(h);
    for k in n { if iv_get(h, k) == v { return k; } }
    return -1;
}
