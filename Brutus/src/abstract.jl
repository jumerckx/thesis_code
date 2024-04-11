@noinline function intrinsic(T)::T
    # prevent type inference:
    invokelatest(error, "MLIR intrinsics can't be executed in a regular Julia context.")

    Base.inferencebarrier(nothing)::T
end

abstract type BoolTrait end
struct NonBoollike <: BoolTrait end
struct Boollike <: BoolTrait end
BoolTrait(T) = NonBoollike()

mlir_bool_conversion(x::Bool) = x
@inline mlir_bool_conversion(x::T) where T = mlir_bool_conversion(BoolTrait(T), x)
@noinline mlir_bool_conversion(::Boollike, x)::Bool = intrinsic(Bool)
mlir_bool_conversion(::NonBoollike, x::T) where T = error("Type $T is not marked as Boollike.")

using Core: MethodInstance, CodeInstance, OpaqueClosure
const CC = Core.Compiler
using CodeInfoTools

## custom interpreter

struct MLIRInterpreter <: CC.AbstractInterpreter
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::Vector{CC.InferenceResult}
end

function MLIRInterpreter(world::UInt = Base.get_world_counter();
                            inf_params::CC.InferenceParams = CC.InferenceParams(),
                            opt_params::CC.OptimizationParams = CC.OptimizationParams(),
                            inf_cache::Vector{CC.InferenceResult} = CC.InferenceResult[])
    @assert world <= Base.get_world_counter()

    return MLIRInterpreter(world, inf_params,
                            opt_params, inf_cache)
end

cache_token = gensym(:MLIRInterpreterCache)
function reset_cache()
    @debug "Resetting cache"
    
    global cache_token
    cache_token = gensym(:MLIRInterpreterCache)
end

CC.InferenceParams(interp::MLIRInterpreter) = interp.inf_params
CC.OptimizationParams(interp::MLIRInterpreter) = interp.opt_params
CC.get_inference_cache(interp::MLIRInterpreter) = interp.inf_cache
CC.get_inference_world(interp::MLIRInterpreter) = interp.world
CC.cache_owner(interp::MLIRInterpreter) = cache_token

# # No need to do any locking since we're not putting our results into the runtime cache
# CC.lock_mi_inference(interp::MLIRInterpreter, mi::MethodInstance) = nothing
# CC.unlock_mi_inference(interp::MLIRInterpreter, mi::MethodInstance) = nothing

function CC.add_remark!(interp::MLIRInterpreter, sv::CC.InferenceState, msg)
    @debug "Inference remark during compilation of MethodInstance of $(sv.linfo): $msg"
end

CC.may_optimize(interp::MLIRInterpreter) = true
CC.may_compress(interp::MLIRInterpreter) = true
CC.may_discard_trees(interp::MLIRInterpreter) = true
CC.verbose_stmt_info(interp::MLIRInterpreter) = false

struct MLIRIntrinsicCallInfo <: CC.CallInfo
    info::CC.CallInfo
    MLIRIntrinsicCallInfo(@nospecialize(info::CC.CallInfo)) = new(info)
end
CC.nsplit_impl(info::MLIRIntrinsicCallInfo) = CC.nsplit(info.info)
CC.getsplit_impl(info::MLIRIntrinsicCallInfo, idx::Int) = CC.getsplit(info.info, idx)
CC.getresult_impl(info::MLIRIntrinsicCallInfo, idx::Int) = CC.getresult(info.info, idx)


function CC.abstract_call_gf_by_type(interp::MLIRInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo, @nospecialize(atype),
    sv::CC.AbsIntState, max_methods::Int)

    cm = @invoke CC.abstract_call_gf_by_type(interp::CC.AbstractInterpreter, f::Any,
    arginfo::CC.ArgInfo, si::CC.StmtInfo, atype::Any, sv::CC.InferenceState, max_methods::Int)
    
    argtype_tuple = try
        Tuple{map(_type, arginfo.argtypes)...}
    catch
        @warn arginfo.argtypes
        error("stop")
    end
    
    if is_intrinsic(argtype_tuple)
        return CC.CallMeta(cm.rt, cm.exct, cm.effects, MLIRIntrinsicCallInfo(cm.info))
    else
        return cm
    end
end


"""
    _typeof(x)

Central definition of typeof, which is specific to the use-required in this package.
"""
_typeof(x) = Base._stable_typeof(x)
_typeof(x::Tuple) = Tuple{map(_typeof, x)...}
_typeof(x::NamedTuple{names}) where {names} = NamedTuple{names, _typeof(Tuple(x))}

_type(x) = x
_type(x::CC.Const) = _typeof(x.val)
_type(x::CC.PartialStruct) = _type(x.typ)
_type(x::CC.Conditional) = Union{_type(x.thentype), _type(x.elsetype)}

is_intrinsic(::Any) = false

macro is_intrinsic(sig)
    return esc(:(Brutus.is_intrinsic(::Type{<:$sig}) = true))
end

function CC.inlining_policy(interp::MLIRInterpreter,
    @nospecialize(src), @nospecialize(info::CC.CallInfo), stmt_flag::UInt32)

    if isa(info, MLIRIntrinsicCallInfo)
        return nothing
    else
        return src
    end
end

# function add_intrinsic_backedges(@nospecialize(tt);
#                       world::UInt=Base.get_world_counter(),
#                       method_table::Union{Nothing,Core.Compiler.MethodTableView}=nothing,
#                       caller::CC.AbsIntState)
#     sig = Base.signature_type(Brutus.is_primitive, Tuple{Type{tt}})
#     mt = ccall(:jl_method_table_for, Any, (Any,), sig)
#     mt isa Core.MethodTable || return false
#     if method_table === nothing
#         method_table = Core.Compiler.InternalMethodTable(world)
#     end
#     Core.println("Finding all methods for $(sig)")
#     result = Core.Compiler.findall(sig, method_table; limit=-1)
#     @assert !(result === nothing || result === missing)
#     @static if isdefined(Core.Compiler, :MethodMatchResult)
#         (; matches) = result
#     else
#         matches = result
#     end
#     fullmatch = Core.Compiler._any(match::Core.MethodMatch->match.fully_covers, matches)
#     if caller !== nothing
#         fullmatch || add_mt_backedge!(caller, mt, sig)
#     end
#     if Core.Compiler.isempty(matches)
#         return false
#     else
#         if caller !== nothing
#             for i = 1:Core.Compiler.length(matches)
#                 match = Core.Compiler.getindex(matches, i)::Core.MethodMatch
#                 edge = Core.Compiler.specialize_method(match)::Core.MethodInstance
#                 Core.println("Adding backedge from $(caller) to $(edge)")
#                 CC.add_backedge!(caller, edge)
#                 # Core.println("\t$(edge.backedges)")
#             end
#         end
#         return true
#     end
# end

# function add_backedge!(caller::Core.MethodInstance, callee::Core.MethodInstance, @nospecialize(sig))
#     ccall(:jl_method_instance_add_backedge, Cvoid, (Any, Any, Any), callee, sig, caller)
#     return nothing
# end

# function add_mt_backedge!(caller::Core.MethodInstance, mt::Core.MethodTable, @nospecialize(sig))
#     ccall(:jl_method_table_add_backedge, Cvoid, (Any, Any, Any), mt, sig, caller)
#     return nothing
# end


## utils

# create a MethodError from a function type
# TODO: fix upstream
function unsafe_function_from_type(ft::Type)
    if isdefined(ft, :instance)
        ft.instance
    else
        # HACK: dealing with a closure or something... let's do somthing really invalid,
        #       which works because MethodError doesn't actually use the function
        Ref{ft}()[]
    end
end
function MethodError(ft::Type{<:Function}, tt::Type, world::Integer=typemax(UInt))
    Base.MethodError(unsafe_function_from_type(ft), tt, world)
end
MethodError(ft, tt, world=typemax(UInt)) = Base.MethodError(ft, tt, world)

import Core.Compiler: retrieve_code_info, maybe_validate_code, InferenceState, InferenceResult
# Replace usage sites of `retrieve_code_info`, OptimizationState is one such, but in all interesting use-cases
# it is derived from an InferenceState. There is a third one in `typeinf_ext` in case the module forbids inference.
function InferenceState(result::InferenceResult, cache_mode::UInt8, interp::MLIRInterpreter)
    src = retrieve_code_info(result.linfo, interp.world)
    src === nothing && return nothing
    maybe_validate_code(result.linfo, src, "lowered")
    src = transform(interp, result.linfo, src)
    maybe_validate_code(result.linfo, src, "transformed")

    return InferenceState(result, src, cache_mode, interp)
end

struct DestinationOffsets
    indices::Vector{Int}
    DestinationOffsets() = new([])
end
function Base.insert!(d::DestinationOffsets, insertion::Int)
    candidateindex = d[insertion]+1
    if (length(d.indices) == 0)
        push!(d.indices, insertion)
    elseif candidateindex == length(d.indices)+1
        push!(d.indices, insertion)
    elseif (candidateindex == 1) || (d.indices[candidateindex-1] != insertion)
        insert!(d.indices, candidateindex, insertion)
    end
    return d
end
Base.getindex(d::DestinationOffsets, i::Int) = searchsortedlast(d.indices, i, lt= <=)

function insert_bool_conversions_pass(mi, src)
    offsets = DestinationOffsets()

    b = CodeInfoTools.Builder(src)
    for (v, st) in b
        if st isa Core.GotoIfNot
            arg = st.cond isa Core.SSAValue ? var(st.cond.id + offsets[st.cond.id]) : st.cond
            b[v] = Statement(Expr(:call, GlobalRef(Brutus, :mlir_bool_conversion), arg))
            push!(b, Core.GotoIfNot(v, st.dest))
            insert!(offsets, v.id)
        elseif st isa Core.GotoNode
            b[v] = st
        end
    end

    # fix destinations and conditions
    for i in 1:length(b.to)
        st = b.to[i].node
        if st isa Core.GotoNode
            b.to[i] = Core.GotoNode(st.label + offsets[st.label])
        elseif st isa Core.GotoIfNot
            b.to[i] = Statement(Core.GotoIfNot(st.cond, st.dest + offsets[st.dest]))
        end
    end
    finish(b)
end

function transform(interp, mi, src)
    src = insert_bool_conversions_pass(mi, src)
    return src
end
