import Probes

/-!
The probes of Probes.lean as a program: `lean --run RunProbe.lean <probe> <n>...` prints the
result of the probe on its input of each size `n`, one per line.

measure.py runs it so, natively (nix/measure.nix's `--native`), for the results of `repr`, which
it cannot compute itself; the canister's `probe` query runs the same probes in PocketIC.
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
    IO.eprintln "usage: lean --run RunProbe.lean <probe> <n>..."
    return 2
