// The inliner (placeholder until Inliner.cpp is ported)
inliner_run :: (node: *Pass_Node, c: s32, ur: *Cgscc_Ur) -> Preserved {
    fatal("pass 'inline' is not implemented yet");
    return PRESERVE_ALL;
}
inliner_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool { return false; }
