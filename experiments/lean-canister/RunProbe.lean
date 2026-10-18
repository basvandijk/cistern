import Probes

/-!
The probes of Probes.lean as a program: `run-probe <probe> <n>...` prints the result of the probe
on its input of each size `n`, one per line.

measure.py runs it under wasmtime, compiled to wasm32-wasip1 like lean-wasm's Hello.lean, to
compare its recursion depths with the canister's. It also runs it natively, with `lean --run`,
for the results of `repr`, which it cannot compute itself.
-/

def main : List String → IO UInt32
  | name :: sizes@(_ :: _) => do
    let some p := probes.lookup name
      | IO.eprintln s!"there is no probe {name}"; return 2
    for n in sizes do
      let some n := n.toNat?
        | IO.eprintln s!"expected a number, got \"{n}\""; return 2
      IO.println (p.run (p.prepare n))
    return 0
  | _ => do
    IO.eprintln "usage: run-probe <probe> <n>..."
    return 2
