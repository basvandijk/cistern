import Hello
import Ic0
import Probes

/-!
A canister written in Lean, for the experiment in README.md.

c/canister.c exports the functions marked `@[export]` below as the canister's methods: `greet`,
`hello`, `probe` and `notes` as queries, `add`, `add_then_exit` and `add_then_throw` as updates,
and `add` also as the query `add_query`. Arguments and replies are UTF-8 text, not Candid:

- `greet`: replies `Hello, <argument>!`.
- `hello`: runs the `main` of ../lean-wasm/Hello.lean, with the words of the argument as its
  command-line arguments, and replies with what it prints.
- `probe`: the argument is `<probe> <n>` or `<probe> <n> <runs>`. Prepares the input of size `n`
  for the probe of that name (see Probes.lean), runs the probe on it `runs` times (once by
  default), and replies with JSON: the probe's result, and the instructions that each run took.
- `add`: adds the argument to the notes, the canister's state, and replies with how many there
  are. The IC keeps what an update changes in the canister's memory, and discards what a query
  changes, so `add_query` replies the same, but the note is gone afterwards.
- `add_then_exit`: adds the argument, and then exits, which traps: the IC discards what the
  message changed.
- `add_then_throw`: adds the argument, and then throws, which rejects the message. That does not
  trap, so the IC keeps what it changed.
- `notes`: replies with the notes. It ignores its argument.

The methods are `BaseIO` actions: `IO` actions that cannot throw an error. `serve` makes one of a
handler that can, by rejecting the message with the error.
-/

/-- The argument of the current message, which must be UTF-8. -/
def argument : IO String := do
  match String.fromUTF8? (← Ic0.msgArgData) with
  | some text => pure text
  | none => throw (IO.userError "the argument is not UTF-8")

/-- Serves a query or an update: replies with what `handler` returns for the argument, or rejects
the message with the error that it throws. Rejecting does not trap, so in an update the IC keeps
what `handler` changed before it threw: it keeps what an update that returns changed, whether it
replied, rejected or neither, and discards what one that traps changed. -/
def serve (handler : String → IO String) : BaseIO Unit :=
  EIO.catchExceptions
    (do
      let reply ← handler (← argument)
      Ic0.msgReplyDataAppend reply.toUTF8
      Ic0.msgReply)
    fun e => Ic0.msgReject (toString e)

@[export cistern_greet]
def greet : BaseIO Unit := serve fun name => do
  -- To the canister's log, through stdout (see c/wasi.c).
  IO.println s!"greeting {name}"
  return s!"Hello, {name}!"

@[export cistern_hello]
def hello : BaseIO Unit := serve fun arg => do
  let args := arg.splitOn " " |>.filter (· ≠ "")
  -- Hello's `main` prints to stdout, which this captures.
  let (output, ()) ← IO.FS.withIsolatedStreams (main args)
  return output

@[export cistern_probe]
def probe : BaseIO Unit := serve fun arg => do
  let (name, n, runs) ← match arg.splitOn " " with
    | [name, n] => pure (name, n, "1")
    | [name, n, runs] => pure (name, n, runs)
    | _ => throw (IO.userError s!"expected \"<probe> <n>\" or \"<probe> <n> <runs>\", got \"{arg}\"")
  let some p := probes.lookup name | throw (IO.userError s!"there is no probe {name}")
  let (some n, some runs) := (n.toNat?, runs.toNat?)
    | throw (IO.userError s!"expected numbers, got \"{arg}\"")
  let input := p.prepare n
  let mut result := 0
  let mut instructions := #[]
  for _ in [0:runs] do
    let (r, count) ← Ic0.countInstructions p.run input
    result := r
    instructions := instructions.push count
  return s!"\{\"result\": {result}, \"instructions\": {instructions.toList}}"

/-- The notes, the canister's state: what `add` and `add_then_throw` were given, oldest first.

An `IO.Ref` is a mutable reference, here to an array. `initialize` declares a constant whose value
an `IO` action computes when the module is initialized, here a reference to an empty array. The
module's initializer, `initialize_Canister`, runs that action; c/canister.c calls it in
`canister_init`, and again in `canister_post_upgrade`, as an upgrade starts with new memory. The
reference and the notes are in the canister's memory, which the IC keeps from one update to the
next. -/
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

@[export cistern_add]
def add : BaseIO Unit := serve fun note => return toString (← addNote note)

/-- Adds the argument, and then exits, with the number of notes as the exit code. `toUInt8` makes
it the `UInt8` that `IO.Process.exit` takes, modulo 256, so the code is the number of notes only
below 256. A canister cannot exit, so this traps (c/wasi.c's `proc_exit`), and the IC discards what
the message changed. The trap's message, `exit(<n>)`, shows that the note was added first. -/
@[export cistern_add_then_exit]
def addThenExit : BaseIO Unit := serve fun note => do
  let count ← addNote note
  IO.Process.exit count.toUInt8

/-- Adds the argument, and then throws, so that `serve` rejects the message. That does not trap,
so the IC keeps what the message changed. `discard` drops the number of notes. -/
@[export cistern_add_then_throw]
def addThenThrow : BaseIO Unit := serve fun note => do
  discard <| addNote note
  throw (IO.userError s!"added {note}, then threw")

/-- Replies with the notes, as `#[a, b]`, or `#[]` if there are none. `fun _ =>` ignores the
argument. -/
@[export cistern_notes]
def notes : BaseIO Unit := serve fun _ => return toString (← notesRef.get)
