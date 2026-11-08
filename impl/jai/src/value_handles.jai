// Value handles that follow RAUW: WeakTrackingVH and TrackingVH.
// Port of the tracking part of llvm/include/llvm/IR/ValueHandle.h and ValueHandleBase::ValueIsRAUWd /
// ValueIsDeleted (llvm/lib/IR/Value.cpp).
//
// Value ids are never reused (an erased value's row stays DEAD), so a WeakVH is a plain Value_Id checked with
// `vkind(v) != .DEAD`, and an AssertingVH / PoisoningVH a plain Value_Id. Only handles that must *move* on RAUW
// need this table: a handle is a slot `Vh` (u32); `vh_get` reads it. replace_all_uses_with calls vh_note_rauw
// (the slot then holds the new value, like WeakTrackingVH::allUsesReplacedWith), erase_inst calls vh_note_erase
// (the slot becomes NONE: a WeakTrackingVH becomes null; a TrackingVH must not see that, LLVM asserts).
// Handles live until vh_release_all (the pass that created them calls it before returning).

Vh :: u32;

vh_state: struct {
    slots: [..] Value_Id;
    by_value: Table(Value_Id, [..] Vh);
};

vh_new :: (v: Value_Id) -> Vh {
    h := cast(Vh) vh_state.slots.count;
    array_add(*vh_state.slots, v);
    if v != NONE vh_link(h, v);
    return h;
}
vh_get :: inline (h: Vh) -> Value_Id { return vh_state.slots[h]; }
// operator=(Value *)
vh_set :: (h: Vh, v: Value_Id) {
    old := vh_state.slots[h];
    if old == v return;
    if old != NONE vh_unlink(h, old);
    vh_state.slots[h] = v;
    if v != NONE vh_link(h, v);
}
vh_link :: (h: Vh, v: Value_Id) {
    p := table_find_pointer(*vh_state.by_value, v);
    if !p { e: [..] Vh; table_set(*vh_state.by_value, v, e); p = table_find_pointer(*vh_state.by_value, v); }
    array_add(p, h);
}
vh_unlink :: (h: Vh, v: Value_Id) {
    p := table_find_pointer(*vh_state.by_value, v);
    if !p return;
    for p.* if it == h { array_unordered_remove_by_index(p, it_index); break; }
}

// ValueHandleBase::ValueIsRAUWd (WeakTracking and Tracking handles move to the new value)
vh_note_rauw :: (old: Value_Id, new: Value_Id) {
    if vh_state.by_value.count == 0 || old == new return;
    p := table_find_pointer(*vh_state.by_value, old);
    if !p || p.count == 0 return;
    moved: [..] Vh; moved.allocator = temp;
    for p.* array_add(*moved, it);
    p.count = 0;
    for moved { vh_state.slots[it] = new; vh_link(it, new); }
}
// ValueHandleBase::ValueIsDeleted
vh_note_erase :: (v: Value_Id) {
    if vh_state.by_value.count == 0 return;
    p := table_find_pointer(*vh_state.by_value, v);
    if !p return;
    for p.* vh_state.slots[it] = NONE;
    p.count = 0;
}

vh_release_all :: () {
    vh_state.slots.count = 0;
    for * vh_state.by_value array_free(it.*);
    table_reset(*vh_state.by_value);
}
