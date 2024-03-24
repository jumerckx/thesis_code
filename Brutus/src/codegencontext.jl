using MLIR: IR, API

mutable struct CodegenContext
    region::Region
    const blocks::Vector{Block}
    const entryblock::Block
    currentblockindex::Int
    const ir::Core.Compiler.IRCode
    const ret::Type
    const values::Vector
    const args::Vector


    function CodegenContext(;
            region::Region,
            blocks::Vector{Block},
            entryblock::Block,
            currentblockindex::Int,
            ir::Core.Compiler.IRCode,
            ret::Type,
            values::Vector,
            args::Vector)
        cg = new(region, blocks, entryblock, currentblockindex, ir, ret, values, args)
        activate(cg)
        return cg
    end
end

function CodegenContext(f::Core.Function; kwargs...)
    cg = CodegenContext(; kwargs...)
    try
        f(cg)
    finally
        deactivate(cg)
    end
end

currentblock(cg::CodegenContext) = cg.blocks[cg.currentblockindex]
start_region!(cg::CodegenContext) = push!(cg.regions, Region())[end]
stop_region!(cg::CodegenContext) = pop!(cg.regions)
currentregion(cg::CodegenContext) = cg.regions[end]

_has_context() = haskey(task_local_storage(), :CodegenContext) &&
                 !isempty(task_local_storage(:CodegenContext))

function codegencontext(; throw_error::Core.Bool=true)
    if !_has_context()
        throw_error && error("No CodegenContext is active")
        return nothing
    end
    last(task_local_storage(:CodegenContext))
end

function activate(cg::CodegenContext)
    stack = get!(task_local_storage(), :CodegenContext) do
        CodegenContext[]
    end
    push!(stack, cg)
    return
end

function deactivate(cg::CodegenContext)
    codegencontext() == cg || error("Deactivating wrong CodegenContext")
    pop!(task_local_storage(:CodegenContext))
end

function codegencontext!(f, cg::CodegenContext)
    activate(cg)
    try
        f()
    finally
        deactivate(cg)
    end
end

function get_value(cg::CodegenContext, x)
    if x isa Core.SSAValue
        @assert isassigned(cg.values, x.id) "value $x was not assigned"
        return cg.values[x.id]
    elseif x isa Core.Argument
        @assert isassigned(cg.args, x.n-1) "value $x was not assigned"
        return cg.args[x.n-1]
        # return IR.argument(cg.entryblock, x.n - 1)
    elseif x isa BrutusType
        return x
    elseif (x isa Type) && (x <: BrutusType)
        #TODO: clean-up
        error("this shouldn't be hit anymore")
        return IR.Type(x)
    elseif x == GlobalRef(Main, :nothing) # This might be something else than Main sometimes?
        return IR.Type(Nothing)
    else
        # error("could not use value $x inside MLIR")
        @debug "Value could not be converted to MLIR: $x, of type $(typeof(x))."
        return x
    end
end

function get_type(cg::CodegenContext, x)
    if x isa Core.SSAValue
        return cg.ir.stmts.type[x.id]
    elseif x isa Core.Argument
        return cg.ir.argtypes[x.n]
    elseif x isa BrutusType
        return typeof(x)
    else
        @debug "Could not get type for $x, of type $(typeof(x))."
        return nothing
        # error("could not get type for $x, of type $(typeof(x))")
    end
end
