module

public import Ic0
public import Interface
public import Std.Async.Basic

/-!
Calls to other canisters, for the handlers of Canister.lean.

A canister calls another with the System API's `ic0.call_*` functions, and the response, the
reply or a reject, comes in a later message, to a callback (Ic0.lean's `call`, c/ic0.c). So a
handler that calls cannot wait for the response: it ends the message, and the rest of it runs in
the callback's message. `Ic.call` makes a call and awaits its response in `Ic.Async`, the monad of
an update's handler, which is `Std.Async`'s `EAsync` with `Ic.Error` as the error:

```lean
def greetVia : BaseIO Unit := serve Interface.greetVia fun (canister, name) => do
  IO.println s!"asking {canister.toText}"                    -- an IO action, lifted
  let greeting : String ← Ic.call canister "greet" name     -- the call; the rest runs in the callback
  return s!"{greeting} (via {canister.toText})"
```

`EAsync` runs a computation up to its first `await` of a task that has not finished, and the rest
of it when that task finishes: the call's promise, which the callback resolves, is such a task.
Canister.lean's `serve` starts the handler, and replies when it is done, from the message that
finishes it. Its `bind` is `BaseIO.bindTask`, which is why the single-threaded runtime needs a task
manager (lean-wasm's runtime/task-manager.patch). `do`, `←`, `throw`, `try … catch`, `for` and
`Std.Async.EAsync.concurrently` work as in `IO`. What to know:

- Nothing after an `await` runs in the message that made the call. Other messages run in between,
  and may change the canister's state. What a message changes stays when it returns, also when a
  later message of the handler throws or traps: a trap discards only its own message's changes.
- `Ic.call` makes the call when it runs. For calls at the same time, run several before awaiting
  them: `EAsync.concurrently`, `concurrentlyAll` and `race` do that.
- A reject, a refused call, a Candid error and the error of an `IO` action are `Ic.Error`s, which
  `serve` turns into a reject of the handler's message, with `toString`. A trap in a handler's
  callback discards the callback's changes, and the IC rejects the handler's message with
  `CANISTER_ERROR`.
- `IO.wait`, `Task.get` and `EAsync.block` on a task that has not finished trap: there is nothing
  to wait for.
- A query cannot call: its handler is an `IO` action (`Ic.Handler`), in which `Ic.call` does not
  typecheck. The System API traps on a call in a query.
- The response is awaited in the call context of the handler. A task made in one message and
  awaited in another handler's would run that handler's continuation in the first one's callback,
  and reply there: it must not be done.
-/

public section

namespace Ic

open Std.Async

/-- Why a call was rejected: by the callee, or by the system. -/
inductive RejectCode where
  /-- 1: a fatal system error, which a retry is unlikely to fix. -/
  | sysFatal
  /-- 2: a transient system error, which a retry may fix. -/
  | sysTransient
  /-- 3: the canister does not exist. -/
  | destinationInvalid
  /-- 4: the callee rejected the call, with `ic0.msg_reject`: the only code a canister can give. -/
  | canisterReject
  /-- 5: the callee trapped, did not respond, or has no such method. -/
  | canisterError
  /-- 6: the system stopped waiting for the response of a bounded-wait call. The callee may or
  may not have run. -/
  | sysUnknown
  /-- A code that this module does not know. -/
  | other (code : UInt32)
  deriving BEq, Inhabited

def RejectCode.ofCode : UInt32 → RejectCode
  | 1 => .sysFatal
  | 2 => .sysTransient
  | 3 => .destinationInvalid
  | 4 => .canisterReject
  | 5 => .canisterError
  | 6 => .sysUnknown
  | code => .other code

def RejectCode.toCode : RejectCode → UInt32
  | .sysFatal => 1
  | .sysTransient => 2
  | .destinationInvalid => 3
  | .canisterReject => 4
  | .canisterError => 5
  | .sysUnknown => 6
  | .other code => code

/-- What goes wrong in a handler that calls. -/
inductive Error where
  /-- The call was rejected, with a message. -/
  | rejected (code : RejectCode) (message : String)
  /-- `ic0.call_perform` refused the call, for lack of resources or of cycles: it was not made,
  and no callback runs. -/
  | performFailed
  /-- The canister's liquid cycles, `available`, are less than `required`, the call's cost and
  the cycles to attach, so the call was not made. -/
  | insufficientCycles (available required : Nat)
  /-- Encoding the arguments, or decoding the reply at the expected types, failed. -/
  | candid (error : Candid.Error)
  /-- The error of an `IO` action of the handler. -/
  | io (error : IO.Error)
  /-- The call's promise was dropped before it was resolved, which does not happen for a call
  that was made. -/
  | dropped
  deriving Inhabited

/-- The messages are ic_cdk's, for the errors that it has. -/
instance : ToString Error where
  toString
    | .rejected code message => s!"call rejected: {code.toCode} - {message}"
    | .performFailed => "call perform failed"
    | .insufficientCycles available required =>
      s!"insufficient liquid cycles balance, available: {available}, required: {required}"
    | .candid error => toString error
    | .io error => toString error
    | .dropped => "the call's response was dropped"

/-- Whether the callee did not run: the call was not made, or the system rejected it before it
was delivered. As ic_cdk's `is_clean_reject`. -/
def Error.isCleanReject : Error → Bool
  | .rejected .sysFatal _ | .rejected .sysTransient _ | .rejected .destinationInvalid _ => true
  | .performFailed | .insufficientCycles .. => true
  | _ => false

/-- Whether making the call again at once may succeed. As ic_cdk's `is_immediately_retryable`. -/
def Error.isImmediatelyRetryable : Error → Bool
  | .rejected .sysTransient _ | .rejected .sysUnknown _ => true
  | _ => false

/-- The monad of an update's handler: `Std.Async`'s `EAsync`, with `Error` as the error. `IO`,
`BaseIO` and `EIO Error` actions lift into it. -/
abbrev Async (α : Type) := EAsync Error α

instance : MonadLift IO Async where
  monadLift act := EAsync.lift (act.toEIO Error.io)

/-- An `Except` of the Candid library as an `Async` action. -/
def ofCandid : Except Candid.Error α → Async α
  | .ok a => pure a
  | .error e => throw (.candid e)

/-- How long to wait for the response. -/
inductive Wait where
  /-- Bounded wait (`ic0.call_with_best_effort_response`): after `seconds`, which the IC caps at
  its maximum, 300, the call may be rejected with `sysUnknown`, and the callee may or may not
  have run. -/
  | bounded (seconds : UInt32)
  /-- Unbounded wait: the response is guaranteed, but the canister cannot stop, and so cannot be
  upgraded, while it waits. -/
  | unbounded

/-- A call to make: the callee, the method, the argument, a Candid message, by default `()`, the
cycles to attach, and how long to wait, by default 300 seconds, bounded, as ic_cdk recommends for
a callee that one does not control. -/
structure Call where
  callee : Candid.Principal
  method : String
  arg : ByteArray := ⟨#[0x44, 0x49, 0x44, 0x4c, 0, 0]⟩
  cycles : Nat := 0
  wait : Wait := .bounded 300

/-- A 128-bit value from its high and its low 64 bits. -/
private def natOfPair : UInt64 × UInt64 → Nat
  | (high, low) => high.toNat * 2 ^ 64 + low.toNat

/-- The timeout of a wait, for `Ic0.call`. -/
private def Wait.timeout : Wait → Option UInt32
  | .bounded seconds => some seconds
  | .unbounded => none

/-- Checks that the canister has the cycles for the call, as ic_cdk does, makes it, and awaits
its response. The call is made when this runs; what follows the await runs in the message of the
callback. -/
def Call.perform (c : Call) : Async Ic0.Response := do
  let cost ← natOfPair <$> Ic0.costCall c.method.utf8ByteSize.toUInt64 c.arg.size.toUInt64
  let available ← natOfPair <$> Ic0.canisterLiquidCycleBalance128
  let required := c.cycles + cost
  if available < required then throw (.insufficientCycles available required)
  let promise ← IO.Promise.new
  let code ← Ic0.call c.callee.bytes c.method c.arg (c.cycles >>> 64).toUInt64 c.cycles.toUInt64
    c.wait.timeout promise
  if code != 0 then throw .performFailed
  let some response ← await promise.result? | throw .dropped
  if response.code == 0 then return response
  throw (.rejected (.ofCode response.code) (String.fromUTF8! response.data))

/-- As `Call.perform`, but one-way: the response is dropped. Not asynchronous, so an `EIO`
action, which lifts into `Async`. -/
def Call.oneway (c : Call) : EIO Error Unit := do
  let cost ← natOfPair <$> Ic0.costCall c.method.utf8ByteSize.toUInt64 c.arg.size.toUInt64
  let available ← natOfPair <$> Ic0.canisterLiquidCycleBalance128
  let required := c.cycles + cost
  if available < required then throw (.insufficientCycles available required)
  let code ← Ic0.callOneway c.callee.bytes c.method c.arg (c.cycles >>> 64).toUInt64
    c.cycles.toUInt64 c.wait.timeout
  if code != 0 then throw .performFailed

/-- Calls the method `method` of `callee` with `args`, encoded at their Candid types, and decodes
the reply at the Candid types of `β`, which the expected type gives:
`let greeting : String ← Ic.call canister "greet" name`. -/
def call (callee : Candid.Principal) (method : String) (args : α) [CandidArgs α] [CandidArgs β]
    (cycles : Nat := 0) (wait : Wait := .bounded 300) : Async β := do
  let arg ← ofCandid (Candid.encode args)
  let response ← Call.perform { callee, method, arg, cycles, wait }
  ofCandid (Candid.decode response.data)

/-- Calls the method `method` of `callee` with `args`, and drops the response. -/
def oneway (callee : Candid.Principal) (method : String) (args : α) [CandidArgs α]
    (cycles : Nat := 0) (wait : Wait := .bounded 300) : EIO Error Unit := do
  let arg ← match Candid.encode args with
    | .ok arg => pure arg
    | .error e => throw (.candid e)
  Call.oneway { callee, method, arg, cycles, wait }

/-- 32 random bytes from the management canister's `raw_rand`. -/
def rawRand : Async ByteArray :=
  call Candid.Principal.managementCanister "raw_rand" ()

/-- The monad of the handler of a method of a kind: an `IO` action for a query, which cannot
call, so `call` does not typecheck in it; an `Async` action for an update, into which `IO`
lifts. -/
abbrev Handler : Interface.Kind → Type → Type
  | .query => IO
  | .update => Async

/-- A handler as an `Async` action: a query's `IO` action is lifted. -/
def Handler.run : (kind : Interface.Kind) → Handler kind α → Async α
  | .query, handler => monadLift (handler : IO α)
  | .update, handler => handler

end Ic
