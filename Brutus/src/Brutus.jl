module Brutus

using MLIR.IR
using MLIR: API
using MLIR.Dialects: arith, func, cf, memref, index, builtin, llvm
using Core: PhiNode, GotoNode, GotoIfNot, SSAValue, Argument, ReturnNode, PiNode

const BrutusScalarType = Union{Bool, Int64, UInt64, Int32, UInt32, Float16, Float32, Float64, UInt64}
const BrutusType = Union{BrutusScalarType, Array{BrutusScalarType}}

include("intrinsics.jl")
include("pass.jl")
include("overlay.jl")
include("codegencontext.jl")
include("ValueTypes.jl")

IR.MLIRType(::Type{Nothing}) = IR.MLIRType(API.mlirLLVMVoidTypeGet(IR.context()))

struct InstructionContext{I}
    args::Vector
    result_type::Type
    loc::Location
end

function cmpi_pred(predicate)
    function(lhs, rhs; loc=Location())
        arith.cmpi(lhs, rhs; predicate, location=loc)
    end
end

function single_op_wrapper(fop)
    (cg::CodegenContext, ic::InstructionContext)->IR.get_result(push!(currentblock(cg), fop(indextoi64.(Ref(cg), get_value.(Ref(cg), ic.args))...)))
end

indextoi64(cg::CodegenContext, x; loc=IR.Location()) = x
function indextoi64(cg::CodegenContext, x::Value; loc=IR.Location())
    mlirtype = IR.get_type(x)
    if API.mlirTypeIsAIndex(mlirtype)
        return push!(currentblock(cg), arith.index_cast(
            x;
            out=MLIRType(Int), location=loc)
            ) |> IR.get_result
    else
        return x
    end
end
function i64toindex(cg, x::Value; loc=IR.Location())
    mlirtype = IR.get_type(x)
    if API.mlirTypeIsAInteger(mlirtype)
        return push!(currentblock(cg), arith.index_cast(
            x;
            out=IR.IndexType(), location=loc
        )) |> IR.get_result
    else
        return x
    end
end

emit(cg::CodegenContext, ic::InstructionContext{Base.and_int}) = cg, single_op_wrapper(arith.andi)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.add_int}) = cg, single_op_wrapper(arith.addi)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.sub_int}) = cg, single_op_wrapper(arith.subi)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.sle_int}) = cg, single_op_wrapper(cmpi_pred(arith.Predicates.sle))(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.slt_int}) = cg, single_op_wrapper(cmpi_pred(arith.Predicates.slt))(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.ult_int}) = cg, single_op_wrapper(cmpi_pred(arith.Predicates.slt))(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.:(===)}) = cg, single_op_wrapper(cmpi_pred(arith.Predicates.eq))(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.mul_int}) = cg, single_op_wrapper(arith.muli)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.add_float}) = cg, single_op_wrapper(arith.addf)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.sub_float}) = cg, single_op_wrapper(arith.subf)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.mul_float}) = cg, single_op_wrapper(arith.mulf)(cg, ic)
emit(cg::CodegenContext, ic::InstructionContext{Base.div_float}) = cg, single_op_wrapper(arith.divf)(cg, ic)

function emit(cg::CodegenContext, ic::InstructionContext{Base.not_int})
    arg = get_value(cg, only(ic.args))
    ones = push!(currentblock(cg), arith.constant(value=-1, result=IR.get_type(arg), location=ic.loc)) |> IR.get_result
    return cg, IR.get_result(push!(currentblock(cg), arith.xori(arg, ones; location=ic.loc)))
end
function emit(cg::CodegenContext, ic::InstructionContext{Base.bitcast})
    @show ic.args
    type, value = get_value.(Ref(cg), ic.args)
    value = indextoi64(cg, value)
    return cg, IR.get_result(push!(currentblock(cg), arith.bitcast(value; out=type, location=ic.loc)))
end
function emit(cg::CodegenContext, ic::InstructionContext{Base.getfield})
    object = get_value(cg, first(ic.args))
    field = ic.args[2]
    if field isa QuoteNode; field=field.value; end
    return cg, getfield(object, field)
end
function emit(cg::CodegenContext, ic::InstructionContext{Core.tuple})
    inputs = get_value.(Ref(cg), ic.args)
    outputs = IR.get_type.(inputs)
    
    op = push!(currentblock(cg), builtin.unrealized_conversion_cast(
        inputs;
        outputs,
        location=ic.loc
    ))
    return cg, Tuple(IR.get_result.(Ref(op), 1:fieldcount(ic.result_type)))
end
function emit(cg::CodegenContext, ic::InstructionContext{Core.ifelse})
    T = get_type(cg, ic.args[2])
    @assert T == get_type(cg, ic.args[3]) "Branches in Core.ifelse should have the same type."
    condition, true_value, false_value = get_value.(Ref(cg), ic.args)
    return cg, IR.get_result(push!(currentblock(cg), arith.select(condition, true_value, false_value; result=IR.get_type(true_value), location=ic.loc)))
end
function emit(cg::CodegenContext, ic::InstructionContext{Base.throw_boundserror})
    @warn "Ignoring potential boundserror while generating MLIR."
    return cg, nothing
end
function emit(cg::CodegenContext, ic::InstructionContext{Core.memoryref})
    @assert get_type(cg, ic.args[1]) <: MemoryRef "memoryref(::Memory) is not yet supported."
    mr = get_value(cg, ic.args[1])
    one_off = IR.get_result(push!(currentblock(cg), index.constant(value=Attribute(1, IR.IndexType()); location=ic.loc)))
    offsets = push!(currentblock(cg), index.sub(
        i64toindex(cg, get_value(cg, ic.args[2])),
        one_off;
        result=IR.IndexType(),
        location=ic.loc
    )) |> IR.get_results
    sizes = push!(currentblock(cg), index.sub(
        mr.mem.length,
        only(offsets);
        result=IR.IndexType(),
        location=ic.loc,
    )) |> IR.get_results
    flattened = push!(currentblock(cg), memref.reinterpretcast(
        mr.ptr_or_offset,
        offsets,
        sizes,
        Value[];
        result=MLIRType(Vector{eltype(get_type(cg, ic.args[1]))}),
        static_offsets=IR.Attribute(API.mlirDenseI64ArrayGet(context().context, 1, Int[API.mlirShapedTypeGetDynamicSize()])),
        static_sizes=IR.Attribute(API.mlirDenseI64ArrayGet(context().context, 1, Int[API.mlirShapedTypeGetDynamicSize()])),
        static_strides=IR.Attribute(API.mlirDenseI64ArrayGet(context().context, 1, Int[1])),
        location=Location()
    )) |> IR.get_result
    return cg, (; ptr_or_offset=flattened, mem=mr.mem)
end
function emit(cg::CodegenContext, ic::InstructionContext{Core.memoryrefget})
    @assert ic.args[2] == :not_atomic "Only non-atomic memoryrefget is supported."
    @assert ic.args[2] == :not_atomic "Only non-atomic memoryrefget is supported."
    # TODO: ic.args[3] signals boundschecking, currently ignored.
    
    mr = get_value(cg, ic.args[1]).ptr_or_offset
    indices=push!(currentblock(cg), index.constant(value=Attribute(0, IR.IndexType()), location=ic.loc)) |> IR.get_results
    return cg, push!(currentblock(cg), memref.load(
        mr,
        indices;
        result=MLIRType(eltype(get_type(cg, ic.args[1]))),
        location=ic.loc,
    )) |> IR.get_result
end
function emit(cg::CodegenContext, ic::InstructionContext{Core.memoryrefset!})
    @assert ic.args[3] == :not_atomic "Only non-atomic memoryrefset! is supported."

    mr = get_value(cg, ic.args[1])

    value = get_value(cg, ic.args[2])
    mr = mr.ptr_or_offset
    indices=push!(currentblock(cg), arith.constant(value=Attribute(0, IR.IndexType()), location=ic.loc)) |> IR.get_results
    push!(currentblock(cg), memref.store(
        value,
        mr.ptr_or_offset,
        indices;
        location=ic.loc,
    ))
    return cg, value
end

"Generates a block argument for each phi node present in the block."
function prepare_block(ir, bb)
    b = Block()

    for sidx in bb.stmts
        stmt = ir.stmts[sidx]
        inst = stmt[:inst]
        inst isa Core.PhiNode || continue

        type = stmt[:type]
        IR.push_argument!(b, MLIRType(type), Location())
    end

    return b
end

"Values to populate the Phi Node when jumping from `from` to `to`."
function collect_value_arguments(ir, from, to)
    to = ir.cfg.blocks[to]
    values = []
    for s in to.stmts
        stmt = ir.stmts[s]
        inst = stmt[:inst]
        inst isa Core.PhiNode || continue

        edge = findfirst(==(from), inst.edges)
        if isnothing(edge) # use dummy scalar val instead
            val = zero(stmt[:type])
            push!(values, val)
        else
            push!(values, inst.values[edge])
        end
    end
    values
end

"""
    code_mlir(f, types::Type{Tuple}) -> IR.Operation

Returns a `func.func` operation corresponding to the ircode of the provided method.
This only supports a few Julia Core primitives and scalar types of type $BrutusType.

!!! note
    The Julia SSAIR to MLIR conversion implemented is very primitive and only supports a
    handful of primitives. A better to perform this conversion would to create a dialect
    representing Julia IR and progressively lower it to base MLIR dialects.
"""
function code_mlir(f, types; do_simplify=true)
    ctx = context()
    ir, ret = Core.Compiler.code_ircode(f, types) |> only
    @assert first(ir.argtypes) isa Core.Const

    values = Vector(undef, length(ir.stmts))
    args = Vector(undef, length(types.parameters))
    for dialect in ("func", "cf")
        IR.get_or_load_dialect!(dialect)
    end

    blocks = [
        prepare_block(ir, bb)
        for bb in ir.cfg.blocks
    ]

    cg = CodegenContext(
        [Region()],
        [],
        blocks,
        blocks[begin],
        1,
        ir,
        ret,
        values,
        args
    )

    for (i, argtype) in enumerate(types.parameters)
        arg = IR.push_argument!(cg.entryblock, MLIRType(argtype), Location())

        if argtype <: DenseArray
            @debug argtype
            N = ndims(argtype)
            length = IR.get_result(push!(cg.entryblock, index.constant(value=Attribute(1, IR.IndexType()))))
            sizes = []
            for i in 0:N-1
                index_ = IR.get_result(push!(cg.entryblock, index.constant(value=Attribute(i, IR.IndexType()))))
                dim = IR.get_result(push!(cg.entryblock, memref.dim(arg, index_; location=IR.Location(), result=IR.IndexType())))
                push!(sizes, dim)
                length = IR.get_result(push!(cg.entryblock, index.mul(length, dim; result=IR.IndexType(), location=IR.Location())))
            end
            sizes = Tuple(sizes)

            if argtype <: MemRef
                arg = (;
                    # allocated_pointer, # shouldn't occur in ircode so doesn't matter
                    aligned_pointer=arg,
                    # offset, # shouldn't occur in ircode so doesn't matter
                    sizes = sizes,
                )
            elseif argtype <: Array
                # This NamedTuple mirrors the layout of a Julia Array:
                arg = (;
                    ref=(;
                        ptr_or_offset=arg,
                        mem=(; length=length, ptr=nothing)
                    ),
                    size=sizes
                )
            else throw("Array type $argtype not supported.")
            end
        end

        println("adding argument $i")
        cg.args[i] = argtype(arg) # Note that Core.Argument(index) ends up at index-1 in this array. We handle this in get_value.
        println("$argtype => $(MLIRType(argtype))")
    end

    for (block_id, bb) in enumerate(cg.ir.cfg.blocks)
        cg.currentblockindex = block_id
        @info "number of regions: $(length(cg.regions))"
        push!(currentregion(cg), currentblock(cg))
        n_phi_nodes = 0

        for sidx in bb.stmts
            stmt = cg.ir.stmts[sidx]
            inst = stmt[:inst]
            @info "Working on: $(inst)"
            if inst == nothing
                inst = Core.GotoNode(block_id+1)
                line = Core.LineInfoNode(Brutus, :code_mlir, Symbol(@__FILE__), Int32(@__LINE__), Int32(@__LINE__))
            else
                line = cg.ir.linetable[stmt[:line]]
            end

            if Meta.isexpr(inst, :call)
                val_type = stmt[:type]
                called_func, args... = inst.args

                if called_func isa GlobalRef # TODO: should probably use something else here
                    called_func = getproperty(called_func.mod, called_func.name)
                end
                args = map(args) do arg
                    if arg isa GlobalRef
                        arg = getproperty(arg.mod, arg.name)
                    elseif arg isa QuoteNode
                        arg = arg.value
                    end
                    return arg
                end

                getintrinsic(gr::GlobalRef) = Core.Compiler.abstract_eval_globalref(gr)
                getintrinsic(inst::Expr) = getintrinsic(first(inst.args))
                getintrinsic(mod::Module, name::Symbol) = getintrinsic(GlobalRef(mod, name))

                loc = Location(string(line.file), line.line, 0)
                ic = InstructionContext{called_func}(args, val_type, loc)
                # return cg, ic
                @show typeof(ic)
                cg, res = emit(cg, ic)

                values[sidx] = res
            elseif Meta.isexpr(inst, :invoke)
                val_type = stmt[:type]
                _, called_func, args... = inst.args

                if called_func isa GlobalRef # TODO: should probably use something else here
                    called_func = getproperty(called_func.mod, called_func.name)
                end
                args = map(args) do arg
                    if arg isa GlobalRef
                        arg = getproperty(arg.mod, arg.name)
                    elseif arg isa QuoteNode
                        arg = arg.value
                    end
                    return arg
                end
                loc = Location(string(line.file), line.line, 0)
                ic = InstructionContext{called_func}(args, val_type, loc)

                argvalues = get_value.(Ref(cg), ic.args)

                out = mlircompilationpass() do
                    called_func(argvalues...)
                end
                @info out

                values[sidx] = out


            elseif inst isa PhiNode
                values[sidx] = IR.get_argument(currentblock(cg), n_phi_nodes += 1)
            elseif inst isa PiNode
                values[sidx] = get_value(values, inst.val)
            elseif inst isa GotoNode
                args = Value[get_value.(Ref(cg), collect_value_arguments(cg.ir, cg.currentblockindex, inst.label))...]
                dest = cg.blocks[inst.label]
                loc = Location(string(line.file), line.line, 0)
                push!(currentblock(cg), cf.br(args; dest, location=loc))
            elseif inst isa GotoIfNot
                false_args = Value[get_value.(Ref(cg), collect_value_arguments(cg.ir, cg.currentblockindex, inst.dest))...]
                cond = get_value(cg, inst.cond)
                @assert length(bb.succs) == 2 # NOTE: We assume that length(bb.succs) == 2, this might be wrong
                trueDest = setdiff(bb.succs, inst.dest) |> only
                true_args = Value[get_value.(Ref(cg), collect_value_arguments(cg.ir, cg.currentblockindex, trueDest))...]
                trueDest = cg.blocks[trueDest]
                falseDest = cg.blocks[inst.dest]

                location = Location(string(line.file), line.line, 0)
                # @show cond
                # if inst.cond.id == 54; return 1; end
                cond_br = cf.cond_br(cond, true_args, false_args; trueDest, falseDest, location)
                push!(currentblock(cg), cond_br)
            elseif inst isa ReturnNode
                line = cg.ir.linetable[stmt[:line]]
                loc = Location(string(line.file), line.line, 0)

                returnvalue = isdefined(inst, :val) ? indextoi64(cg, get_value(cg, inst.val)) : IR.get_result(push!(currentblock(cg), llvm.mlir_undef(; res=MLIRType(cg.ret), location=loc)))
                push!(currentblock(cg), func.return_([returnvalue]; location=loc))

            elseif Meta.isexpr(inst, :code_coverage_effect)
                # Skip
            elseif Meta.isexpr(inst, :boundscheck)
                @warn "discarding boundscheck"
                cg.values[sidx] = IR.get_result(push!(currentblock(cg), arith.constant(value=true)))
            else
                # @warn "unhandled ir $(inst)"
                # return inst
                error("unhandled ir $(inst)")
            end
        end        
    end
    
    func_name = nameof(f)
    
    # add fallthrough to next block if necessary
    for (i, b) in enumerate(cg.blocks)
        if (i != length(cg.blocks) && IR.mlirIsNull(API.mlirBlockGetTerminator(b)))
            @warn "Block $i did not have a terminator, adding one."
            args = []
            dest = cg.blocks[i+1]
            loc = IR.Location()
            push!(b, cf.br(args; dest, location=loc))
        end
    end

    LLVM15 = true

    input_types = MLIRType[
        IR.get_type(IR.get_argument(cg.entryblock, i))
        for i in 1:IR.num_arguments(cg.entryblock)
    ]
    result_types = [MLIRType(ret)]

    ftype = MLIRType(input_types => result_types)
    op = IR.create_operation(
        LLVM15 ? "func.func" : "builtin.func",
        Location();
        attributes = [
            NamedAttribute("sym_name", IR.Attribute(string(func_name))),
            NamedAttribute(LLVM15 ? "function_type" : "type", IR.Attribute(ftype)),
            NamedAttribute("llvm.emit_c_interface", IR.Attribute(API.mlirUnitAttrGet(IR.context())))
        ],
        owned_regions = Region[currentregion(cg)],
        result_inference=false,
    )

    IR.verifyall(op)

    if IR.verify(op) && do_simplify
        simplify(op)
    end

    op
end

"""
    @code_mlir f(args...)
"""
macro code_mlir(call)
    @assert Meta.isexpr(call, :call) "only calls are supported"

    f = first(call.args) |> esc
    args = Expr(:curly,
        Tuple,
        map(arg -> :($(Core.Typeof)($arg)),
            call.args[begin+1:end])...,
    ) |> esc

    quote
        code_mlir($f, $args)
    end
end

end # module Brutus
