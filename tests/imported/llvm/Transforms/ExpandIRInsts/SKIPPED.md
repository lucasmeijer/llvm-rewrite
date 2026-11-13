# Skipped while importing llvm/test/Transforms/ExpandIRInsts (llvmorg-23.1.5)

14 of 18 files imported. Regenerate with `./harness/run import-llvm Transforms/ExpandIRInsts`.

- `frem-inf.ll`: in a AMDGPU target directory
- `frem.ll`: in a AMDGPU target directory
- `missing-analysis.ll`: in a AMDGPU target directory
- `pass-parameters.ll`: in a AMDGPU target directory
- `divrem-pow2.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64-- -expand-div-rem-bits 0`: oracle fails
- `expand-large-fp-convert-fpto-sat-vector.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64--`: oracle fails
- `expand-large-fp-convert-fptosi129.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64--`: oracle fails
- `expand-large-fp-convert-fptoui129.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64--`: oracle fails
- `expand-large-fp-convert-si129tofp.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64--`: oracle fails
- `expand-large-fp-convert-ui129tofp.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64--`: oracle fails
- `expand-large-fp-optnone.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64--`: oracle fails
- `sdiv129.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64-- -expand-div-rem-bits 128`: oracle fails
- `srem129.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64-- -expand-div-rem-bits 128`: oracle fails
- `udiv129.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64-- -expand-div-rem-bits 128`: oracle fails
- `urem129.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64-- -expand-div-rem-bits 128`: oracle fails
- `vector.ll` @opt `-passes=expand-ir-insts -mtriple=x86_64-- -expand-div-rem-bits 128`: oracle fails
