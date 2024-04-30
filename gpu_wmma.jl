using MLIR
includet("utils.jl")

using Brutus.Library: index, f32, f16, i64, memref, MLIRMemref
using Brutus.Library.GPU: threadIdx, blockIdx, blockDim, GPUFunc, gpu_module
import Brutus: MemRef, @intrinsic, MLIRInterpreter, generate, unpack, entryblock, returntype, region, CodegenContext, simplify
using BenchmarkTools, MLIR, MacroTools

import MLIR.Dialects
using MLIR.Dialects: arith, gpu
using MLIR.IR: Context, @affinemap, Attribute, AffineMap, DenseArrayAttribute, Type, context
using MLIR.API: mlirRegisterAllPasses, mlirRegisterAllLLVMTranslations

ctx = IR.Context()
registerAllDialects!();
mlirRegisterAllPasses()
mlirRegisterAllLLVMTranslations(ctx.context)

import Brutus.Library.GPU: MMA_Matrix, OperandType, AOp, BOp, COp

@intrinsic function mma_load(src::MLIRMemref{T, 2}, operandtype, I::Tuple{index, index}) where {T<:Union{f32, f16}}
    I = I .- 1
    T_out = MMA_Matrix{T, operandtype}
    return T_out(
        IR.result(Dialects.gpu.subgroup_mma_load_matrix(
            src, I;
            res=IR.Type(T_out),
            leadDimension=IR.Attribute(16, IR.Type(index)))
            )
    )
end
mma_load(src, operandtype, I) = mma_load(src, operandtype, (index(I[1]), index(I[2])))
mma_load(src, operandtype) = mma_load(src, operandtype, (index(1), index(1)))

@intrinsic function _mma_store(dest::D, src::S, I::Tuple{index, index}) where {T, D<:MLIRMemref{T}, S<:MMA_Matrix{T}}
    I = I .- 1
    Dialects.gpu.subgroup_mma_store_matrix(
        src, dest, I;
        leadDimension=IR.Attribute(16, IR.Type(index)))
    return nothing
end
mma_store(dest, src, I) = _mma_store(dest, src, (index(I[1]), index(I[2])))
mma_store(dest, src) = _mma_store(dest, src, (index(1), index(1)))

@intrinsic function mma_compute(a::A, b::B, c::C) where {T, A<:MMA_Matrix{T, AOp}, B<:MMA_Matrix{T, BOp}, C<:MMA_Matrix{T, COp}}
    C(
        IR.result(Dialects.gpu.subgroup_mma_compute(
            a, b, c;
            )
        )
    )
end

function mma(a, b, c)
    a_mma = mma_load(a, AOp)
    b_mma = mma_load(b, BOp)
    c_mma = mma_load(c, COp)
    c_mma = mma_compute(a_mma, b_mma, c_mma)
    mma_store(c, c_mma)
    return nothing
end

T_in = MLIRMemref{f16, 2, Tuple{16, 16}, nothing, Tuple{16, 1}, 0}

@time gpu_mod_op = gpu_module([
    IR.attr!(
        generate(CodegenContext{GPUFunc}(mma, Tuple{T_in, T_in, T_in})),
        "gpu.kernel", IR.UnitAttribute())
])  |> simplify;


mod = IR.Module()
push!(IR.body(mod), gpu_mod_op)
IR.attr!(IR.Operation(mod), "gpu.container_module", IR.UnitAttribute())

mlir_opt(mod, "gpu.module(strip-debuginfo,convert-gpu-to-nvvm),nvvm-attach-target{chip=sm_75 O=3},gpu-to-llvm")
mlir_opt(mod, "reconcile-unrealized-casts")
data = API.mlirSerializeGPUModuleOp(gpu_mod_op)

print(String(data))

using CUDA

A, B, C = CUDA.rand(Float16, 16, 16), CUDA.rand(Float16, 16, 16), CUDA.zeros(Float16, 16, 16)

import CUDA: CuPtr, CuModule, CuFunction, CuArray, cudacall

md = CuModule(data.data)
mma_cu = CuFunction(md, "mma")

null = CuPtr{Cfloat}(0);
cudacall(mma_cu,
            (CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat},
            CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat},
            CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}),
            null, A, null, null, null, null, null,
            null, B, null, null, null, null, null,
            null, C, null, null, null, null, null;
            threads=(32, 1, 1))

#=
Generated code assumes row-major matrices.
Simply providing changing the memref stride to (1, 16) to make it column-major isn't supported.
This can probably be solved by adding an affine map to the memref description that does the
transformation from row-major to column-major, (i, j)->(j, i).
But simply using the transpose of the matrices works for verification:
=#
@assert C' ≈ A'*B'
