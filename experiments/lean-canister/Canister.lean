module

import Hello
import Ic0
import Probes
import Interface

/-!
A canister written in Lean, for the experiment in README.md.

c/canister.c exports the functions marked `@[export]` below as the canister's methods: `greet`,
`hello`, `probe` and `notes` as queries, `add`, `add_then_exit` and `add_then_throw` as updates,
and `add` also as the query `add_query`. Their arguments and replies are Candid, of the types that
Interface.lean gives them, from which canister.did is generated:

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

The methods are `BaseIO` actions: `IO` actions that cannot throw an error. `serve` makes one of a
handler that can, by rejecting the message with the error.
-/

/-- Serves a query or an update, the method `e` of Interface.lean: decodes the argument of the
current message at `e`'s argument types, and replies with what `handler` returns for it, encoded
at `e`'s result types, or rejects the message with the error that decoding or `handler` throws.
A decoding error's message starts with `Candid:`. Rejecting does not trap, so in an update the IC
keeps what `handler` changed before it threw: it keeps what an update that returns changed,
whether it replied, rejected or neither, and discards what one that traps changed.

`e.Args` and `e.Rets` are types, so the type of `handler` depends on `e`: for `Interface.greet`
it is `String → IO String`. `have := e.args` puts `e`'s `CandidArgs` instances in scope, where
`Candid.decode` and `Candid.encode` find them. Both return an `Except`, which `IO.ofExcept` turns
into an `IO` action that throws the error. -/
def serve (e : Interface.Endpoint) (handler : e.Args → IO e.Rets) : BaseIO Unit :=
  have := e.args
  have := e.rets
  EIO.catchExceptions
    (do
      let args : e.Args ← IO.ofExcept (Candid.decode (← Ic0.msgArgData))
      let reply ← handler args
      Ic0.msgReplyDataAppend (← IO.ofExcept (Candid.encode reply))
      Ic0.msgReply)
    fun err => Ic0.msgReject (toString err)

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
so the IC keeps what the message changed. `discard` drops the number of notes. -/
@[export cistern_add_then_throw]
def addThenThrow : BaseIO Unit := serve Interface.addThenThrow fun note => do
  discard <| addNote note
  throw (IO.userError s!"added {note}, then threw")

/-- Replies with the notes. `fun _ =>` ignores the argument. -/
@[export cistern_notes]
def notes : BaseIO Unit := serve Interface.notes fun _ => notesRef.get
