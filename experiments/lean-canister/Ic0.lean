module

/-!
Lean bindings of the Internet Computer's System API: the Wasm module `ic0`, whose functions a
canister imports
(https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md).

Each binding is an `@[extern]` function that c/ic0.c implements with the System API function of
the same name. Lean has no raw pointers, so where the System API takes an address and a size, a
binding takes or returns a `ByteArray` or a `String`, and a 128-bit value, such as cycles, is a
pair of `UInt64`, the high and the low bits. Only the functions that Canister.lean and Ic.lean use
are here, `countInstructions`, which measures with `ic0.performance_counter`, and `call`, which
makes a call to another canister with the `ic0.call_*` functions (see Ic.lean for calls in a
handler).

None of them returns an error, so they are `BaseIO` actions. The System API traps instead, which
rolls back the message, for example when a function is called where it is not allowed, such as
`msgReply` in `canister_init`.

`public section`: the bindings are public, as Canister.lean calls them; in a module file,
definitions are private by default.
-/

public section

namespace Ic0

/-- The argument of the current message (`ic0.msg_arg_data_size` and `ic0.msg_arg_data_copy`). -/
@[extern "cistern_ic0_msg_arg_data"]
opaque msgArgData : BaseIO ByteArray

/-- Appends `data` to the reply of the current message (`ic0.msg_reply_data_append`). -/
@[extern "cistern_ic0_msg_reply_data_append"]
opaque msgReplyDataAppend (data : @& ByteArray) : BaseIO Unit

/-- Replies to the current message with the data appended so far (`ic0.msg_reply`). -/
@[extern "cistern_ic0_msg_reply"]
opaque msgReply : BaseIO Unit

/-- Rejects the current message with a message (`ic0.msg_reject`). -/
@[extern "cistern_ic0_msg_reject"]
opaque msgReject (message : @& String) : BaseIO Unit

/-- Applies `f` to `a` and returns the result, with the number of instructions that this took:
the difference of `ic0.performance_counter 0`, the instructions that the current message has
executed so far as the IC counts them for its limits, after and before.

The compiled code calls c/ic0.c, which applies `f` between the two reads of the counter: in Lean,
the compiler could move the pure `f a` past them. `a` is borrowed, so `f` gets a shared value. The
definition below only states the result; it does not count. -/
@[extern "cistern_ic0_count_instructions"]
def countInstructions (f : α → β) (a : @& α) : BaseIO (β × UInt64) :=
  pure (f a, 0)

/-- The principal of this canister (`ic0.canister_self`), as bytes. -/
@[extern "cistern_ic0_canister_self"]
opaque canisterSelf : BaseIO ByteArray

/-- The caller of the current message (`ic0.msg_caller`), as bytes. In a callback, it is the
caller of the message that made the call. -/
@[extern "cistern_ic0_msg_caller"]
opaque msgCaller : BaseIO ByteArray

/-- The deadline of the current message (`ic0.msg_deadline`), in nanoseconds since 1970, after
which its caller may stop waiting: 0 unless the message is a bounded-wait call. -/
@[extern "cistern_ic0_msg_deadline"]
opaque msgDeadline : BaseIO UInt64

/-- The cycles that a call with a method name and an argument of these sizes needs the canister
to have above its freezing threshold (`ic0.cost_call`), including what it reserves for the
response and the callback. -/
@[extern "cistern_ic0_cost_call"]
opaque costCall (methodNameSize payloadSize : UInt64) : BaseIO (UInt64 × UInt64)

/-- The cycles that the canister can spend on calls and on execution
(`ic0.canister_liquid_cycle_balance128`). -/
@[extern "cistern_ic0_canister_liquid_cycle_balance128"]
opaque canisterLiquidCycleBalance128 : BaseIO (UInt64 × UInt64)

/-- The cycles that came back with the response of a call (`ic0.msg_cycles_refunded128`): in a
reply or reject callback of an update only. -/
@[extern "cistern_ic0_msg_cycles_refunded128"]
opaque msgCyclesRefunded128 : BaseIO (UInt64 × UInt64)

/-- The response to a call to another canister, as its callback sees it: `code` is
`ic0.msg_reject_code`, 0 for a reply, and `data` the reply (`ic0.msg_arg_data`), or the reject
message (`ic0.msg_reject_msg`), which is UTF-8. -/
structure Response where
  code : UInt32
  data : ByteArray
  deriving Inhabited

/-- c/ic0.c makes a `Response` with this, so that it need not know the structure's layout. -/
@[export cistern_ic0_mk_response]
def Response.make (code : UInt32) (data : ByteArray) : Response := { code, data }

/-- Makes a call to the method `method` of the canister `callee`, a principal's bytes, with the
Candid message `arg`: `ic0.call_new`, `call_on_cleanup`, `call_data_append`,
`call_cycles_add128` of the cycles if they are not 0, `call_with_best_effort_response` of
`timeout` seconds if it is `some`, which makes the call bounded-wait, and `call_perform`, whose
code it returns: 0, and then the reply or the reject callback resolves `promise` with the
response, in a later message, or 2, and then the call was not made, and no callback runs. The
call is sent when the current message returns without trapping. `promise` is the environment of
the callbacks, which c/ic0.c implements: the IC keeps it until a callback has run. Allowed in
updates, in callbacks and in composite queries; traps in queries, `canister_init` and
`canister_post_upgrade`. -/
@[extern "cistern_ic0_call"]
opaque call (callee : @& ByteArray) (method : @& String) (arg : @& ByteArray)
    (cyclesHigh cyclesLow : UInt64) (timeout : @& Option UInt32) (promise : IO.Promise Response) :
    BaseIO UInt32

/-- As `call`, but without callbacks: the response is dropped (the IC traps, harmlessly, where it
would call an index that the function table does not have, as it does for ic_cdk's one-way
calls), and there is no cleanup. -/
@[extern "cistern_ic0_call_oneway"]
opaque callOneway (callee : @& ByteArray) (method : @& String) (arg : @& ByteArray)
    (cyclesHigh cyclesLow : UInt64) (timeout : @& Option UInt32) : BaseIO UInt32

/-- The calls made with `call` whose callback has not run yet, which c/ic0.c counts. -/
@[extern "cistern_ic0_outstanding_calls"]
opaque outstandingCalls : BaseIO UInt32

end Ic0
