// Value handles: WeakVH, WeakTrackingVH and TrackingVH.
// Port of the handle kinds of llvm/include/llvm/IR/ValueHandle.h and ValueHandleBase::ValueIsDeleted /
// ValueIsRAUWd (llvm/lib/IR/Value.cpp), DESIGN.md §5.
//
// A handle is an id into `wvhs`; `wvh_get(h)` is the value it holds (-1 = null). Every value with handles has an
// intrusive list of them (`val_wvh[v]`, grown on demand). ir.goose calls `wvh_value_deleted` from val_set_dead
// (every erase ends there) and `wvh_value_rauwd` from rauw, before the uses change (Value::doRAUW notifies the
// handles first):
//   WVH_WEAK          deleted: null;   RAUW: keeps the old value (WeakVH)
//   WVH_WEAK_TRACKING deleted: null;   RAUW: follows the new value (WeakTrackingVH)
//   WVH_TRACKING      deleted: null;   RAUW: follows the new value (TrackingVH, a WeakTrackingVH inside)
// Handles are allocated on a stack: a pass takes `wvh_mark()` and calls `wvh_release(mark)` when its handles go
// out of scope (the SmallVector<WeakTrackingVH> is destroyed). Since value ids are never reused, an
// AssertingVH or PoisoningVH is a plain id.
import std;
import ir;

let WVH_WEAK: u8 = 0;
let WVH_WEAK_TRACKING: u8 = 1;
let WVH_TRACKING: u8 = 2;

struct WVh { val: i32, kind: u8, next: i32, prev: i32 }
var wvhs: WVh[>..<];
var val_wvh: i32[>..];       // per value id: first handle (-1)
var wvh_live: i64 = 0;       // number of linked handles (the hooks are free while it is 0)

fn wvh_link(h: i32, v: i32) {
    if v < 0 { return; }
    while val_wvh.len <= v as i64 { val_wvh.push(-1); }
    let f = val_wvh[v];
    wvhs[h].prev = -1;
    wvhs[h].next = f;
    if f >= 0 { wvhs[f].prev = h; }
    val_wvh[v] = h;
    wvh_live++;
}
fn wvh_unlink(h: i32) {
    let v = wvhs[h].val;
    if v < 0 { return; }
    let p = wvhs[h].prev;
    let n = wvhs[h].next;
    if p >= 0 { wvhs[p].next = n; } else { val_wvh[v] = n; }
    if n >= 0 { wvhs[n].prev = p; }
    wvhs[h].next = -1;
    wvhs[h].prev = -1;
    wvh_live--;
}

fn wvh_new(v: i32, kind: u8) -> i32 {
    let h = wvhs.len as i32;
    wvhs.push(WVh { val: -1, kind: kind, next: -1, prev: -1 });
    wvh_set(h, v);
    return h;
}
fn wvh_get(h: i32) -> i32 { wvhs[h].val }
// operator=(Value *)
fn wvh_set(h: i32, v: i32) {
    if wvhs[h].val == v { return; }
    wvh_unlink(h);
    wvhs[h].val = v;
    // handles only attach to real values (ValueHandleBase::isValid: not null, not a tombstone/empty key)
    if v >= 0 { wvh_link(h, v); }
}
fn wvh_mark() -> i64 { wvhs.len }
fn wvh_release(mark: i64) {
    var h = wvhs.len - 1;
    while h >= mark { wvh_unlink(h as i32); h--; }
    wvhs.resize(mark);
}

// ValueHandleBase::ValueIsDeleted (the Weak / WeakTracking cases)
fn wvh_value_deleted(v: i32) {
    if v as i64 >= val_wvh.len { return; }
    loop {
        let h = val_wvh[v];
        if h < 0 { break; }
        wvh_unlink(h);
        wvhs[h].val = -1;
    }
}

// ValueHandleBase::ValueIsRAUWd: tracking handles move to `nv` (appended in list order, as LLVM's
// AddToExistingUseList does for each entry)
fn wvh_value_rauwd(old: i32, nv: i32) {
    if old as i64 >= val_wvh.len || old == nv { return; }
    var h = val_wvh[old];
    while h >= 0 {
        let n = wvhs[h].next;
        if wvhs[h].kind != WVH_WEAK {
            wvh_unlink(h);
            wvhs[h].val = nv;
            if nv >= 0 { wvh_link(h, nv); }
        }
        h = n;
    }
}
