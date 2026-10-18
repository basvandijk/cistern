/-!
Lean bindings of the Internet Computer's System API: the Wasm module `ic0`, whose functions a
canister imports
(https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md).

Each binding is an `@[extern]` function that c/ic0.c implements with the System API function of
the same name. Lean has no raw pointers, so where the System API takes an address and a size, a
binding takes or returns a `ByteArray` or a `String`. Only the functions that Canister.lean uses
are here, and `countInstructions`, which measures with `ic0.performance_counter`.

None of them returns an error, so they are `BaseIO` actions. The System API traps instead, which
rolls back the message, for example when a function is called where it is not allowed, such as
`msgReply` in `canister_init`.
-/

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

end Ic0
