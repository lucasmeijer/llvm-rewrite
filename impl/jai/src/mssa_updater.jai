// MemorySSAUpdater: port of llvm/lib/Analysis/MemorySSAUpdater.cpp (in progress; unported entry points fail loudly).

Mssa_Updater :: struct {
    mssa: *Memory_SSA;
}

mssau_wire_old_predecessors_to_new_immediate_predecessor :: (u: *Mssa_Updater, old: Value_Id, new: Value_Id, preds: [] Value_Id, identical_edges := false) {
    fatal("MemorySSAUpdater::wireOldPredecessorsToNewImmediatePredecessor is not implemented yet");
}
mssau_move_all_after_splice_blocks :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id, start: Value_Id) {
    fatal("MemorySSAUpdater::moveAllAfterSpliceBlocks is not implemented yet");
}
mssau_change_to_unreachable :: (u: *Mssa_Updater, i: Value_Id) {
    fatal("MemorySSAUpdater::changeToUnreachable is not implemented yet");
}
mssau_update_phis_when_inserting_unique_backedge_block :: (u: *Mssa_Updater, header: Value_Id, preheader: Value_Id, be: Value_Id) {
    fatal("MemorySSAUpdater::updatePhisWhenInsertingUniqueBackedgeBlock is not implemented yet");
}
mssau_move_all_after_merge_blocks :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id, start: Value_Id) {
    fatal("MemorySSAUpdater::moveAllAfterMergeBlocks is not implemented yet");
}
// MSSAU->moveToPlace(MUD of PredBB's terminator, PredBB, End) after MergeBlockIntoPredecessor moved it
mssau_move_terminator_to_end :: (u: *Mssa_Updater, b: Value_Id) {
    fatal("MemorySSAUpdater::moveToPlace is not implemented yet");
}
mssau_update_for_cloned_block_into_pred :: (u: *Mssa_Updater, header: Value_Id, ph: Value_Id, vm: *Table(Value_Id, Value_Id)) {
    fatal("MemorySSAUpdater::updateForClonedBlockIntoPred is not implemented yet");
}
mssau_apply_updates :: (u: *Mssa_Updater, updates: [] Dom_Update, dt: *Dom_Tree, update_dt: bool) {
    fatal("MemorySSAUpdater::applyUpdates is not implemented yet");
}
mssau_remove_edge :: (u: *Mssa_Updater, from: Value_Id, to: Value_Id) {
    fatal("MemorySSAUpdater::removeEdge is not implemented yet");
}
