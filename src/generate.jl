struct InstructionContext{I}
    args::Vector
    result_type::Union{Type, Core.Const}
    loc::Location
end

emit(cg::AbstractCodegenContext, ic::InstructionContext{F}) where {F} = mlircompilationpass() do 
    # F(get_value.(Ref(cg), ic.args)...)
    # work around https://github.com/JuliaDebug/CassetteOverlay.jl/issues/39:
    args = []
    for arg in ic.args
        push!(args, get_value(cg, arg))
    end
    cg, F(args...)
end


function emit(cg::AbstractCodegenContext, ic::InstructionContext{Base.getfield})
    object = get_value(cg, first(ic.args))
    field = ic.args[2]
    if field isa QuoteNode; field=field.value; end
    return cg, getfield(object, field)
end
function emit(cg::AbstractCodegenContext, ic::InstructionContext{Core.tuple})
    inputs = get_value.(Ref(cg), ic.args)
    if all(IR.MLIRValueTrait.(typeof.(inputs)) .== Ref(IR.Convertible))
        outputs = IR.Type.(typeof.(inputs))
        op = push!(currentblock(cg), builtin.unrealized_conversion_cast(
            inputs;
            outputs,
            location=ic.loc
        ))
        return cg, Tuple(typeof(inputs[i])(IR.result(op, i)) for i in 1:fieldcount(ic.result_type))
    else    
        # If there are non-convertible types in the IR, the operation can't be emitted.
        # This doesn't necessarily lead to an error, as long as the tuple values are not used in emitted MLIR. 
        return cg, Tuple(inputs)
    end
end
function emit(cg::AbstractCodegenContext, ic::InstructionContext{Base.throw_boundserror})
    @debug "Ignoring potential boundserror while generating MLIR."
    return cg, nothing
end

"Generates a block argument for each phi node present in the block."
function prepare_block(ir, bb)
    b = Block()

    for sidx in bb.stmts
        stmt = ir.stmts[sidx]
        inst = stmt[:inst]
        inst isa Core.PhiNode || continue

        type = stmt[:type]
        IR.push_argument!(b, IR.Type(type))
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
            @debug stmt[:type]

            # execute within pass so that operation is pushed in the block
            val = mlircompilationpass() do
                IR.result(ub.poison(; result=IR.Type(stmt[:type])))
            end

            push!(values, val)
        else
            push!(values, inst.values[edge])
        end
    end
    values
end

macro __splatnew__(T, args)
    esc(Expr(:splatnew, T, args))
end
unwrap(x) = x
unwrap(q::QuoteNode) = q.value
@inline __new__(T, args...) = @__splatnew__(T, unwrap.(args))

generate(f, types; emit_region=false, skip_return=false, do_simplify=true) = generate(CodegenContext(f, types); emit_region, skip_return, do_simplify)

function generate(cg::AbstractCodegenContext; emit_region=false, skip_return=false, do_simplify=true)
    codegencontext!(cg) do

    for (block_id, bb) in enumerate(ir(cg).cfg.blocks)
        setcurrentblockindex!(cg, block_id)
        push!(region(cg), currentblock(cg))
        n_phi_nodes = 0

        for sidx in bb.stmts
            stmt = ir(cg).stmts[sidx]
            inst = stmt[:inst]
            @debug "Working on: $(inst)"
            if inst == nothing
                inst = Core.GotoNode(block_id+1)
                line = Core.LineInfoNode(Jojo, :code_mlir, Symbol(@__FILE__), Int32(@__LINE__), Int32(@__LINE__))
            else
                line = ir(cg).linetable[stmt[:line]]
            end

            if Meta.isexpr(inst, :call)
                val_type = stmt[:type]
                called_func, args... = inst.args

                if called_func isa GlobalRef # TODO: should probably use something else here
                    called_func = getproperty(called_func.mod, called_func.name)
                elseif called_func isa Core.SSAValue
                    called_func = get_value(cg, called_func)
                elseif called_func isa QuoteNode
                    called_func = called_func.value
                end
                args = map(args) do arg
                    if arg isa GlobalRef
                        arg = getproperty(arg.mod, arg.name)
                    elseif arg isa QuoteNode
                        arg = arg.value
                    end
                    return arg
                end

                getintrinsic(gr::GlobalRef) = Core.Compiler.abstract_eval_globalref_type(gr)
                getintrinsic(inst::Expr) = getintrinsic(first(inst.args))
                getintrinsic(mod::Module, name::Symbol) = getintrinsic(GlobalRef(mod, name))

                loc = Location(string(line.file), line.line, 0)
                # return called_func, args, val_type, loc
                ic = InstructionContext{called_func}(args, val_type, loc)
                # return cg, ic
                @debug ic
                cg, res = emit(cg, ic)

                values(cg)[sidx] = res
            elseif Meta.isexpr(inst, :invoke)
                val_type = stmt[:type]
                _, called_func, args... = inst.args
                if called_func isa Core.SSAValue
                    called_func = get_value(cg, called_func)
                elseif called_func isa GlobalRef # TODO: use `abstract_eval_globalref` instead to be sure
                    called_func = getproperty(called_func.mod, called_func.name)
                elseif called_func isa QuoteNode
                    called_func = called_func.value
                end
                args = map(args) do arg
                    if arg isa GlobalRef
                        arg = getproperty(arg.mod, arg.name) # TODO: use `abstract_eval_globalref` instead to be sure
                    elseif arg isa QuoteNode
                        arg = arg.value
                    end
                    return arg
                end
                loc = Location(string(line.file), line.line, 0)
                if val_type == Core.Const(nothing)
                    val_type = Nothing
                end
                argvalues = get_value.(Ref(cg), args)

                # special case mlir_bool_conversion to just forward the argument
                if called_func == bool_conversion_intrinsic
                    @assert length(argvalues) == 1 "Expected 1 argument for bool_conversion_intrinsic, got: $(argvalues)"
                    out = argvalues[end]
                else
                    out = mlircompilationpass() do
                        called_func(argvalues...)
                    end
                end

                values(cg)[sidx] = out

            elseif inst isa PhiNode
                values(cg)[sidx] = stmt[:type](IR.argument(currentblock(cg), n_phi_nodes += 1))
            elseif inst isa PiNode
                values(cg)[sidx] = get_value(values, inst.val)
            elseif inst isa GotoNode
                # args = [get_value.(Ref(cg), collect_value_arguments(ir(cg), currentblockindex(cg), inst.label))...]
                #TODO: handle bools better?
                args = map(collect_value_arguments(ir(cg), currentblockindex(cg), inst.label)) do arg
                    if (arg isa Bool)
                        return mlircompilationpass() do
                            IR.result(arith.constant(; result=IR.Type(Bool), value=arg))
                        end
                    else
                        return get_value(cg, arg)
                    end
                end
                dest = blocks(cg)[inst.label]
                loc = Location(string(line.file), line.line, 0)
                mlircompilationpass() do
                    generate_goto(cg, args, dest; location=loc)
                end
            elseif inst isa GotoIfNot
                false_args = [get_value.(Ref(cg), collect_value_arguments(ir(cg), currentblockindex(cg), inst.dest))...]
                cond = get_value(cg, inst.cond)
                @assert length(bb.succs) == 2 # NOTE: We assume that length(bb.succs) == 2, this might be wrong
                true_dest = setdiff(bb.succs, inst.dest) |> only
                true_args = [get_value.(Ref(cg), collect_value_arguments(ir(cg), currentblockindex(cg), true_dest))...]
                true_dest = blocks(cg)[true_dest]
                false_dest = blocks(cg)[inst.dest]

                location = Location(string(line.file), line.line, 0)
                mlircompilationpass() do 
                    generate_gotoifnot(cg, cond; true_args, false_args, true_dest, false_dest, location)
                end
            elseif inst isa ReturnNode
                skip_return && continue

                line = ir(cg).linetable[stmt[:line]]
                loc = Location(string(line.file), line.line, 0)
                if isdefined(inst, :val)
                    if (inst.val isa GlobalRef)  && (getproperty(inst.val.mod, inst.val.name) == nothing)
                        returnvalue = []
                    else
                        v = get_value(cg, inst.val)
                        returnvalue = reinterpret(Tuple{unpack(typeof(v))...}, v)
                    end
                else
                    returnvalue = [IR.result(push!(currentblock(cg), llvm.mlir_undef(; res=IR.Type(returntype(cg)), location=loc)))]
                end
                mlircompilationpass() do 
                    generate_return(cg, returnvalue; location=loc)
                end
            elseif Meta.isexpr(inst, :new)
                args = get_value.(Ref(cg), inst.args)
                values(cg)[sidx] = __new__(args...)
            elseif Meta.isexpr(inst, :code_coverage_effect)
                # Skip
            elseif Meta.isexpr(inst, :boundscheck)
                @debug "discarding boundscheck"
                values(cg)[sidx] = IR.result(push!(currentblock(cg), arith.constant(value=true)))
            elseif Meta.isexpr(inst, :GlobalRef)

            else
                @debug "unhandled ir $(inst) of type $(typeof(inst))"
                if inst isa GlobalRef
                    inst = getproperty(inst.mod, inst.name)
                end
                values(cg)[sidx] = inst
            end
        end
    end
            
    # add fallthrough to next block if necessary
    for (i, b) in enumerate(blocks(cg))
        if (i != length(blocks(cg)) && IR.mlirIsNull(API.mlirBlockGetTerminator(b)))
            setcurrentblockindex!(cg, i)
            @debug "Block $i did not have a terminator, adding one."
            args = [get_value.(Ref(cg), collect_value_arguments(ir(cg), i, i+1))...]
            dest = blocks(cg)[i+1]
            loc = IR.Location()
            mlircompilationpass() do 
                generate_goto(cg, args, dest; location=loc)
            end
        end
    end
    
    return generate_function(cg)

    end # codegencontext
end
is_intrinsic(::Type{<:Tuple{typeof(generate), AbstractCodegenContext, Any, Any, Any}}) = true

@overlay MLIRCompilation function generate(cg::AbstractCodegenContext; emit_region=false, skip_return=false, do_simplify=true)
    return @nonoverlay generate(cg; emit_region, skip_return, do_simplify)
end
