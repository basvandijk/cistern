import Hello
import Ic0
import Probes

/-!
A canister written in Lean, for the experiment in README.md.

c/canister.c exports the functions marked `@[export]` below as the canister's query methods.
Arguments and replies are UTF-8 text, not Candid:

- `greet`: replies `Hello, <argument>!`.
- `hello`: runs the `main` of ../lean-wasm/Hello.lean, with the words of the argument as its
  command-line arguments, and replies with what it prints.
- `probe`: the argument is `<probe> <n>` or `<probe> <n> <runs>`. Prepares the input of size `n`
  for the probe of that name (see Probes.lean), runs the probe on it `runs` times (once by
  default), and replies with JSON: the probe's result, and the instructions that each run took.
-/

/-- The argument of the current message, which must be UTF-8. -/
def argument : IO String := do
  match String.fromUTF8? (← Ic0.msgArgData) with
  | some text => pure text
  | none => throw (IO.userError "the argument is not UTF-8")

/-- Serves a query: replies with what `handler` returns for the argument, or rejects the message
with the error that it throws. -/
def query (handler : String → IO String) : BaseIO Unit :=
  EIO.catchExceptions
    (do
      let reply ← handler (← argument)
      Ic0.msgReplyDataAppend reply.toUTF8
      Ic0.msgReply)
    fun e => Ic0.msgReject (toString e)

@[export cistern_greet]
def greet : BaseIO Unit := query fun name => do
  -- To the canister's log, through stdout (see c/wasi.c).
  IO.println s!"greeting {name}"
  return s!"Hello, {name}!"

@[export cistern_hello]
def hello : BaseIO Unit := query fun arg => do
  let args := arg.splitOn " " |>.filter (· ≠ "")
  -- Hello's `main` prints to stdout, which this captures.
  let (output, ()) ← IO.FS.withIsolatedStreams (main args)
  return output

@[export cistern_probe]
def probe : BaseIO Unit := query fun arg => do
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
