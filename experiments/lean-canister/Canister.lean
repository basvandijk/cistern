module

import Hello
import Ic0
import Probes
import Interface
import Ic

/-!
A canister written in Lean, for the experiment in README.md.

c/canister.c exports the functions marked `@[export]` below as the canister's methods: `greet`,
`hello`, `probe`, `notes` and `call_in_query` as queries, the others as updates, and `add` also as
the query `add_query`. Their arguments and replies are Candid, of the types that Interface.lean
gives them, from which canister.did is generated:

- `greet : (text) -> (text)`: replies `Hello, <argument>!`.
- `hello : (vec text) -> (text)`: runs the `main` of ../lean-wasm/Hello.lean, with the argument
  as its command-line arguments, and replies with what it prints.
- `probe : (text, nat, opt nat) -> (record { result : nat; instructions : vec nat64 })`: prepares
  the input of size `n` for the probe of that name (see Probes.lean), runs the probe on it `runs`
  times (once if `runs` is `null`), and replies with the probe's result and the instructions that
  each run took.
- `add : (text) -> (nat)`: adds the argument to the notes, the canister's state, and replies with
  how many there are. The IC keeps what an update changes in the canister's memory, and discards
  what a query changes, so `add_query` replies the same, but the note is gone afterwards.
- `add_then_exit : (text) -> ()`: adds the argument, and then exits, which traps: the IC discards
  what the message changed.
- `add_then_throw : (text) -> ()`: adds the argument, and then throws, which rejects the message.
  That does not trap, so the IC keeps what it changed.
- `notes : (text) -> (vec text)`: replies with the notes. It ignores its argument.
- The methods that call other canisters, through Ic.lean: `random : () -> (blob)`, 32 random
  bytes from the management canister's `raw_rand`; `greet_via : (principal, text) -> (text)`,
  the greeting of the given canister's `greet`; `add_twice : (text) -> (nat, nat)`, two calls to
  this canister's `add`, one after the other, and `add_both : (text, text) -> (nat, nat)`, two at
  the same time, with the counts that they reply; `call_raw : (principal, text, blob) ->
  (variant { Ok : blob; Err : text })`, any call, with the reply as it is, or the error;
  `call_then_exit : (text) -> ()`, which calls `add` and exits when the reply comes, so that the
  callback traps; `call_then_throw : (text) -> ()`, which throws instead, so that the callback
  rejects; and `oneway_add : (text) -> ()`, which calls `add` without waiting for the reply.
- `call_in_query : (text) -> (text)`: a query that makes a call, which traps.

The methods are `BaseIO` actions: `IO` actions that cannot throw an error. `serve` makes one of a
handler that can, by rejecting the message with the error.
-/

/-- Serves a query or an update, the method `e` of Interface.lean: decodes the argument of the
current message at `e`'s argument types, and replies with what `handler` returns for it, encoded
at `e`'s result types, or rejects the message with the error that decoding or `handler` throws.
A decoding error's message starts with `Candid:`. Rejecting does not trap, so in an update the IC
keeps what `handler` changed before it threw: it keeps what an update that returns changed,
whether it replied, rejected or neither, and discards what one that traps changed.

`e.Args` and `e.Rets` are types, so the type of `handler` depends on `e`, and so does its monad
(`Ic.Handler`): for `Interface.greet`, a query, it is `String → IO String`; for an update it is
an `Ic.Async` action, in which the handler can call other canisters, and into which `IO` actions
lift. `have := e.args` puts `e`'s `CandidArgs` instances in scope, where `Candid.decode` and
`Candid.encode` find them. Both return an `Except`, which `Ic.ofCandid` turns into an action
that throws the error.

The handler runs, as an `Ic.Async` action, up to its first await of a call's response, which
ends the message; the rest of it, and the reply, run in the message of the callback that
resolves the response, which `BaseIO.chainTask` arranges: it runs its continuation when the task
finishes, at once if it has (`sync`: inside `resolve`, or here, for a handler that did not
await). So a method that does not call replies in its own message, as before. -/
def serve (e : Interface.Endpoint) (handler : e.Args → Ic.Handler e.kind e.Rets) : BaseIO Unit :=
  have := e.args
  have := e.rets
  let run : Ic.Async Unit := do
    let args : e.Args ← Ic.ofCandid (Candid.decode (← Ic0.msgArgData))
    let reply ← Ic.Handler.run e.kind (handler args)
    Ic0.msgReplyDataAppend (← Ic.ofCandid (Candid.encode reply))
    Ic0.msgReply
  do
    let task ← Std.Async.EAsync.toBaseIO run
    BaseIO.chainTask (sync := true) task fun
      | .ok () => pure ()
      | .error err => Ic0.msgReject (toString err)

@[export cistern_greet]
def greet : BaseIO Unit := serve Interface.greet fun name => do
  -- To the canister's log, through stdout (see c/wasi.c).
  IO.println s!"greeting {name}"
  return s!"Hello, {name}!"

@[export cistern_hello]
def hello : BaseIO Unit := serve Interface.hello fun args => do
  -- Hello's `main` prints to stdout, which this captures.
  let (output, ()) ← IO.FS.withIsolatedStreams (main args.toList)
  return output

/-- `fun (name, n, runs) =>` takes the argument, a `String × Nat × Option Nat`, apart. -/
@[export cistern_probe]
def probe : BaseIO Unit := serve Interface.probe fun (name, n, runs) => do
  let some p := probes.lookup name | throw (IO.userError s!"there is no probe {name}")
  let input := p.prepare n
  let mut result := 0
  let mut instructions := #[]
  for _ in [0:runs.getD 1] do
    let (r, count) ← Ic0.countInstructions p.run input
    result := r
    instructions := instructions.push count
  return { result, instructions : Interface.ProbeResult }

/-- The notes, the canister's state: what `add` and `add_then_throw` were given, oldest first.

An `IO.Ref` is a mutable reference, here to an array. `initialize` declares a constant whose value
an `IO` action computes when the module is initialized, here a reference to an empty array. The
module's runtime initializer, `runtime_initialize_Canister`, runs that action; c/canister.c
calls it in `canister_init`, and again in `canister_post_upgrade`, as an upgrade starts with new
memory. The reference and the notes are in the canister's memory, which the IC keeps from one
update to the next. -/
initialize notesRef : IO.Ref (Array String) ← IO.mkRef #[]

/-- Adds `note` to the notes, and returns how many there are. As it cannot fail, it is a `BaseIO`
action, which an `IO` action can run as well.

`modifyGet` takes the array out of the reference, applies the function to it, and puts the
function's new array back. While `push` runs, nothing else refers to the array, so `push` can add
the note in place, instead of copying the array; reading the array with `get` and writing it with
`set` would share it, and `push` would copy it. `push` still copies the first time, the empty
array `#[]`, which is a constant, and moves the array to one with room for (c + 1) * 2 notes when
its c places are full. That `push` adds in place relies on this runtime being built without
threads (see README.md): Lean's default runtime marks what a reference that `initialize` created
holds as shared, and `push` copies a shared array. -/
def addNote (note : String) : BaseIO Nat :=
  notesRef.modifyGet fun old => let new := old.push note; (new.size, new)

/-- `add`, and `add_query`, which c/canister.c exports with the same code: `Interface.addQuery`
is `Interface.add` with another name. -/
@[export cistern_add]
def add : BaseIO Unit := serve Interface.add fun note => addNote note

/-- Adds the argument, and then exits, with the number of notes as the exit code. `toUInt8` makes
it the `UInt8` that `IO.Process.exit` takes, modulo 256, so the code is the number of notes only
below 256. A canister cannot exit, so this traps (c/wasi.c's `proc_exit`), and the IC discards what
the message changed. The trap's message, `exit(<n>)`, shows that the note was added first. -/
@[export cistern_add_then_exit]
def addThenExit : BaseIO Unit := serve Interface.addThenExit fun note => do
  let count ← addNote note
  IO.Process.exit count.toUInt8

/-- Adds the argument, and then throws, so that `serve` rejects the message. That does not trap,
so the IC keeps what the message changed. `discard` drops the number of notes. The error is an
`IO.Error`, as an `Ic.Error`, whose message `serve` rejects with. -/
@[export cistern_add_then_throw]
def addThenThrow : BaseIO Unit := serve Interface.addThenThrow fun note => do
  discard <| addNote note
  throw (.io (IO.userError s!"added {note}, then threw"))

/-- Replies with the notes. `fun _ =>` ignores the argument. -/
@[export cistern_notes]
def notes : BaseIO Unit := serve Interface.notes fun _ => notesRef.get

/-! The methods that call other canisters. Their handlers are `Ic.Async` actions (see Ic.lean):
`Ic.call` makes a call, and what follows it runs in a later message, when the response comes. -/

/-- This canister's principal. -/
def self : BaseIO Candid.Principal := do
  return ⟨← Ic0.canisterSelf⟩

/-- Replies with 32 random bytes from the management canister's `raw_rand`: the reply comes in a
later message, in which the handler finishes and `serve` replies. -/
@[export cistern_random]
def random : BaseIO Unit := serve Interface.random fun () => Ic.rawRand

/-- Replies with the greeting of the given canister's `greet` for the name. The `IO.println`
reaches the log in the first message, `return` in the callback's. -/
@[export cistern_greet_via]
def greetVia : BaseIO Unit := serve Interface.greetVia fun (canister, name) => do
  IO.println s!"asking {canister.toText} to greet {name}"
  let greeting : String ← Ic.call canister "greet" name
  return greeting

/-- Two calls to this canister's `add`, one after the other: three messages, with the second
call made in the callback of the first. -/
@[export cistern_add_twice]
def addTwice : BaseIO Unit := serve Interface.addTwice fun note => do
  let self ← self
  let first : Nat ← Ic.call self "add" s!"{note}/1"
  let second : Nat ← Ic.call self "add" s!"{note}/2"
  return (first, second)

/-- Two calls to this canister's `add` at the same time: both are made in the first message, and
their replies come in two later messages, in either order. -/
@[export cistern_add_both]
def addBoth : BaseIO Unit := serve Interface.addBoth fun (a, b) => do
  let self ← self
  Std.Async.EAsync.concurrently (Ic.call (β := Nat) self "add" a) (Ic.call (β := Nat) self "add" b)

/-- Calls the method of the canister with the argument, which must be a Candid message, and
replies with the reply, as it is, or with the error's message: a reject's reads
`call rejected: <code> - <message>`. -/
@[export cistern_call_raw]
def callRaw : BaseIO Unit := serve Interface.callRaw fun (canister, method, arg) => do
  try
    let response ← Ic.Call.perform { callee := canister, method, arg }
    return (.ok response.data : Except String ByteArray)
  catch err =>
    return .error (toString err)

/-- Calls this canister's `add` with the argument, and when the reply comes adds a second note
and exits, which traps: the IC discards the callback's changes, the second note, and runs the
cleanup callback; the first note stays, as `add`'s message was kept. The handler's message is
then rejected by the IC, as nothing can reply to it. -/
@[export cistern_call_then_exit]
def callThenExit : BaseIO Unit := serve Interface.callThenExit fun note => do
  let self ← self
  let count : Nat ← Ic.call self "add" note
  discard <| addNote s!"{note}/callback"
  IO.Process.exit count.toUInt8

/-- Calls this canister's `add` with the argument, and when the reply comes throws, so that
`serve` rejects the handler's message from the callback. The note stays. -/
@[export cistern_call_then_throw]
def callThenThrow : BaseIO Unit := serve Interface.callThenThrow fun note => do
  let self ← self
  let count : Nat ← Ic.call self "add" note
  throw (.io (IO.userError s!"added {note} as note {count}, then threw"))

/-- Calls this canister's `add` with the argument, one-way: the reply is dropped, and this
message replies at once. The note is there when the call has been handled, after this message. -/
@[export cistern_oneway_add]
def onewayAdd : BaseIO Unit := serve Interface.onewayAdd fun note => do
  let self ← self
  Ic.oneway self "add" note

/-- A query that makes a one-way call, through `Ic0.callOneway` directly, as `Ic.call` does not
typecheck in a query's handler: the System API traps, as a query cannot call. -/
@[export cistern_call_in_query]
def callInQuery : BaseIO Unit := serve Interface.callInQuery fun note => do
  let self ← self
  let code ← Ic0.callOneway self.bytes "add" (← IO.ofExcept (Candid.encode note)) 0 0 none
  return s!"call_perform returned {code}"
