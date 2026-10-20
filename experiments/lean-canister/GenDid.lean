import Interface

/-!
Prints the canister's Candid interface, canister.did, from Interface.lean, or with `--exports`
the names of the functions that canister.wasm must export, one per line. nix/did.nix runs it with
`lean --run`, and checks the committed canister.did and canister.wasm's exports against its
output.

A program file, not a module: `lean --run` of a module can run only code that the module defines
itself, while a plain file has the compiled code of all of its imports.
-/

def main : List String → IO UInt32
  | [] => do
    IO.print Interface.toDid
    return 0
  | ["--exports"] => do
    for name in Interface.exports do
      IO.println name
    return 0
  | _ => do
    IO.eprintln "usage: GenDid [--exports]"
    return 2
