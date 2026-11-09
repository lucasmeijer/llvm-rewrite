// Passes whose only effect depends on optimization remarks being enabled. Ported from
// llvm/lib/Transforms/IPO/Annotation2Metadata.cpp (convertAnnotation2Metadata returns false unless
// OptimizationRemarkEmitter::allowExtraAnalysis(Ctx, "annotation-remarks")) and
// llvm/lib/Transforms/Scalar/AnnotationRemarks.cpp (runImpl returns at once without allowExtraAnalysis; it never
// changes the IR). Our opt has no remark streamer or -pass-remarks* options (they are rejected as unsupported), so
// allowExtraAnalysis is always false and both passes leave the module unchanged.

annotation2metadata_run :: () -> Preserved { return PRESERVE_ALL; }
annotation_remarks_run :: (f: Value_Id) -> Preserved { return PRESERVE_ALL; }
