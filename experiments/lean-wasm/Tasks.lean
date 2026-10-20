import Std.Async.Basic

/-!
Tries the task manager of the single-threaded runtime (runtime/task-manager.patch, see
README.md). `tasks <case>` runs one case, which prints a trace, and `tasks list` prints the
cases, each with its kind:

- `shared`: the trace must be the same natively, where Lean's own task manager runs the code,
  with one worker (`lean --threads=1`), so that continuations run in the order in which they were
  queued. These cases print from the main thread only after `IO.wait`, which natively blocks until
  the worker is done.
- `wasm`: the trace depends on the single-threaded order, in which a continuation runs inside the
  `resolve` that makes it ready, or a task spawned inside a task runs when that task returns.
- `trap`: the case must end with an internal panic, exit status 1, after the trace.

nix/wasm.nix runs them under wasmtime, and the `shared` ones also natively, and compares the
traces with tasks/<case>.txt (the check `lean-wasm-tasks-runs`).

An `IO.Promise` is a task that something else resolves, as the reply of a call to another
canister resolves one in lean-canister; the continuations are `IO.mapTask`, `IO.bindTask` and
`Std.Async`'s monads, which bind through them.
-/

open Std.Async

def showResult [ToString α] : Except IO.Error α → String
  | .ok a => s!"ok {a}"
  | .error e => s!"error {e}"

/-- Waits for the task, and prints its result. -/
def waitResult [ToString α] (t : Task (Except IO.Error α)) : IO Unit := do
  IO.println s!"result: {showResult (← IO.wait t)}"

def dropped : IO.Error := IO.userError "the promise was dropped"

/-- A continuation on a promise runs when the promise is resolved, not before. -/
def bindPending : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let t ← IO.mapTask (fun v => do IO.println s!"continuation {v}"; return v.getD 0 + 1) p.result?
  IO.println "setup done"
  p.resolve 5
  waitResult t

/-- A continuation that itself waits on a second promise: the task of the first continuation
becomes a dependent of the second promise. Either promise may be resolved first. -/
def nested (pFirst : Bool) : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let q ← IO.Promise.new (α := Nat)
  let t ← IO.bindTask p.result? fun v => do
    IO.println s!"p continuation {v}"
    IO.mapTask (fun w => do IO.println s!"q continuation {w}"; return v.getD 0 + w.getD 0) q.result?
  IO.println "setup done"
  if pFirst then
    p.resolve 1
    q.resolve 2
  else
    q.resolve 2
    p.resolve 1
  waitResult t

/-- A `do` block in `Async` with three awaits: the part up to the first pending await runs when
the block is started, each later segment when its promise is resolved. With `printResolved`, a
line after each `resolve` shows that the segment ran inside it (single-threaded order). -/
def asyncDo (printResolved : Bool) : IO Unit := do
  let p0 ← IO.Promise.new (α := Nat)
  let p1 ← IO.Promise.new (α := Nat)
  let p2 ← IO.Promise.new (α := Nat)
  let act : Async Nat := do
    IO.println "segment 0"
    let some a ← await p0.result? | throw dropped
    IO.println s!"segment 1: {a}"
    let some b ← await p1.result? | throw dropped
    IO.println s!"segment 2: {b}"
    let some c ← await p2.result? | throw dropped
    IO.println s!"segment 3: {c}"
    return a + b + c
  let t ← EAsync.toBaseIO act
  IO.println "setup done"
  for (p, i) in [p0, p1, p2].zip [0, 1, 2] do
    p.resolve (i + 1)
    if printResolved then IO.println s!"resolved {i}"
  waitResult t

/-- `for` over a list, whose iterations await, and `repeat`, which `Std.Async` runs through a
promise of its own. -/
def loops : IO Unit := do
  let p0 ← IO.Promise.new (α := Nat)
  let p1 ← IO.Promise.new (α := Nat)
  let p2 ← IO.Promise.new (α := Nat)
  let act : Async Nat := do
    let mut sum := 0
    for p in [p0, p1, p2] do
      let some v ← await p.result? | throw dropped
      IO.println s!"for: {v}"
      sum := sum + v
    let mut i := 0
    repeat
      if i == 2 then break
      IO.println s!"repeat: {i}"
      i := i + 1
    return sum
  let t ← EAsync.toBaseIO act
  IO.println "setup done"
  p0.resolve 1
  p1.resolve 2
  p2.resolve 3
  waitResult t

/-- An error thrown after an await is caught by a `try` around the await. -/
def tryCatch : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let act : Async Nat := do
    try
      let some v ← await p.result? | throw dropped
      throw (IO.userError s!"failed after {v}")
    catch e =>
      IO.println s!"caught: {e}"
      return 0
  let t ← EAsync.toBaseIO act
  IO.println "setup done"
  p.resolve 1
  waitResult t

/-- `Async.race`: the result of the computation whose promise is resolved first. -/
def race : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let q ← IO.Promise.new (α := Nat)
  let x : Async Nat := do
    let some a ← await p.result? | throw dropped
    return a
  let y : Async Nat := do
    let some b ← await q.result? | throw dropped
    return b
  let t ← EAsync.toBaseIO (Async.race x y)
  q.resolve 2
  p.resolve 1
  waitResult t

/-- `Async.concurrently`: both computations run up to their awaits when started; the one whose
promise is resolved first continues first, and the pair is ready after the other. -/
def concurrently : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let q ← IO.Promise.new (α := Nat)
  let x : Async Nat := do
    IO.println "x before await"
    let some a ← await p.result? | throw dropped
    IO.println s!"x after await {a}"
    return a
  let y : Async Nat := do
    IO.println "y before await"
    let some b ← await q.result? | throw dropped
    IO.println s!"y after await {b}"
    return b
  let t ← EAsync.toBaseIO (Async.concurrently x y)
  IO.println "setup done"
  q.resolve 2
  p.resolve 1
  waitResult t

/-- A promise that is dropped without being resolved resolves its task with `none`. -/
def droppedPromise : IO Unit := do
  IO.println "setup done"
  let t ← do
    let p ← IO.Promise.new (α := Nat)
    IO.mapTask (fun v => do IO.println s!"continuation {v}"; return v.getD 0) p.result?
  waitResult t

/-- A continuation that resolves another promise: that promise's continuation runs after the
resolving one has returned, not inside `resolve`. -/
def reentrant : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let q ← IO.Promise.new (α := Nat)
  let tq ← IO.mapTask (fun v => IO.println s!"q continuation {v}") q.result?
  let tp ← IO.mapTask (fun v => do
      IO.println s!"p continuation {v}"
      q.resolve 7
      IO.println "after resolve q") p.result?
  IO.println "setup done"
  p.resolve 3
  discard <| IO.wait tp
  discard <| IO.wait tq
  IO.println "done"

/-- `IO.cancel` on a continuation's task, before it runs. -/
def cancel : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let t ← IO.mapTask (fun _ => do IO.println s!"canceled: {← IO.checkCanceled}") p.result?
  IO.cancel t
  p.resolve 1
  discard <| IO.wait t

/-- A chain of `n` promises, each resolved by the continuation of the one before: resolving the
first runs them all, on a stack that does not grow with `n`. -/
def deep (n : Nat) : IO Unit := do
  let first ← IO.Promise.new (α := Nat)
  let mut p := first
  for _ in [0:n] do
    let q ← IO.Promise.new (α := Nat)
    discard <| IO.mapTask (fun v => q.resolve (v.getD 0 + 1)) p.result?
    p := q
  first.resolve 0
  IO.println s!"deep {n}: {← IO.wait p.result?}"

/-- Continuations of three priorities on one promise: the highest first, with the dedicated
priority as the maximum (there are no dedicated workers). -/
def priorities : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let t0 ← IO.mapTask (prio := Task.Priority.default) (fun _ => IO.println "default priority") p.result?
  let t8 ← IO.mapTask (prio := Task.Priority.max) (fun _ => IO.println "max priority") p.result?
  let t9 ← IO.mapTask (prio := Task.Priority.dedicated) (fun _ => IO.println "dedicated priority") p.result?
  IO.println "setup done"
  p.resolve 0
  for t in [t0, t8, t9] do
    discard <| IO.wait t
  IO.println "done"

/-- `IO.asTask` runs its action at once, unless it is called from a task: then the action runs
when that task returns. -/
def asTask : IO Unit := do
  let t ← IO.asTask (do IO.println "spawned"; return 1)
  IO.println "after spawn"
  IO.println s!"state {← IO.getTaskState t}"
  let outer ← IO.asTask do
    IO.println "outer start"
    let inner ← IO.asTask (IO.println "inner")
    IO.println s!"inner state inside outer: {← IO.getTaskState inner}"
    IO.println "outer end"
  discard <| IO.wait outer
  IO.println "done"

/-- `IO.wait` on a promise that nothing resolves: an internal panic, as there is nothing to wait
for. The promise is used after the wait, so that it is alive during it: a promise that is dropped
resolves its task with `none` (see `droppedPromise`). -/
def waitPending : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  IO.println "waiting"
  let v ← IO.wait p.result?
  IO.println s!"unreachable {v}"
  p.resolve 0

/-- `Promise.result!` of a promise that is dropped: an internal panic, where the runtime with
threads would block forever. -/
def resultBang : IO Unit := do
  IO.println "dropping"
  let t ← do
    let p ← IO.Promise.new (α := Nat)
    pure p.result!
  IO.println s!"unreachable {← IO.wait t}"

/-- `IO.Promise.discard` of runtime/task-manager.patch, which only the runtime without threads
has: resolves the promise with `none`, and frees what waits on it without running it, as
lean-canister's cleanup callback does after a callback trapped. -/
@[extern "lean_io_promise_discard"]
opaque discardPromise (promise : @& IO.Promise Nat) : BaseIO Unit

/-- Discarding a promise: the continuation does not run, nor does the one on the inner promise
that it captured, which is dropped with it, so that its task resolves to `none`; the outer
continuation's task, whose handle is kept, never finishes. Resolving the promise afterwards does
nothing. -/
def discard : IO Unit := do
  let p ← IO.Promise.new (α := Nat)
  let (t, tq) ← do
    let q ← IO.Promise.new (α := Nat)
    let t ← IO.bindTask p.result? fun v => do
      IO.println s!"continuation {v}"
      IO.mapTask (fun w => do IO.println s!"q continuation {w}"; return w.getD 0) q.result?
    pure (t, q.result?)
  IO.println "setup done"
  discardPromise p
  IO.println "discarded"
  IO.println s!"outer task: {← IO.getTaskState t}"
  IO.println s!"inner promise's task: {← IO.wait tq}"
  p.resolve 1
  IO.println "after resolve p"

/-- The cases: name, kind (see above), and the case. -/
def cases : List (String × String × IO Unit) := [
  ("bind-pending", "shared", bindPending),
  ("nested-pq", "shared", nested true),
  ("nested-qp", "shared", nested false),
  ("async-do", "shared", asyncDo false),
  ("async-do-inline", "wasm", asyncDo true),
  ("loops", "shared", loops),
  ("try-catch", "shared", tryCatch),
  ("race", "shared", race),
  ("concurrently", "wasm", concurrently),
  ("dropped", "shared", droppedPromise),
  ("reentrant", "shared", reentrant),
  ("cancel", "shared", cancel),
  ("deep-10000", "shared", deep 10000),
  ("deep-100000", "shared", deep 100000),
  ("priorities", "wasm", priorities),
  ("as-task", "wasm", asTask),
  ("discard", "wasm", discard),
  ("wait-pending", "trap", waitPending),
  ("dropped-bang", "trap", resultBang)
]

def main : List String → IO UInt32
  | ["list"] => do
    for (name, kind, _) in cases do
      IO.println s!"{name} {kind}"
    return 0
  | [name] => do
    match cases.find? (·.1 == name) with
    | some (_, _, run) =>
      run
      return 0
    | none =>
      IO.eprintln s!"there is no case {name}"
      return 2
  | _ => do
    IO.eprintln "usage: tasks <case> | tasks list"
    return 2
