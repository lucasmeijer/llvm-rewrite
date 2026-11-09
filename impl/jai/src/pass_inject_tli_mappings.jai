// InjectTLIMappings: port of llvm/lib/Transforms/Utils/InjectTLIMappings.cpp. addMappingsFromTLI returns at
// `!TLI.isFunctionVectorizable(ScalarName)`, which is always false here: vector-library mappings (VecFuncs.def,
// -vector-library) are not ported and opt rejects -vector-library (tli.jai). So the pass never changes the IR.
inject_tli_mappings_run :: (f: Value_Id) -> Preserved { return PRESERVE_ALL; }
