module

/-!
The program behind the canister's `hello` query: Canister.lean runs its `main` with the query's
arguments, and replies with what it prints, which nix/measure.nix compares with what
`lean --run Hello.lean` prints natively.

Besides printing a greeting, it exercises runtime features that work differently on a 32-bit
target such as `wasm32`. On 64-bit platforms a `Nat` below 2^63 is stored unboxed. On 32-bit
platforms that limit drops to 2^31, and anything larger goes through the runtime's
arbitrary-precision arithmetic.

It is a module file (`module`), as Canister.lean, which imports it, is one: a module can import
only modules. In a module, a definition is private unless it is `public`, so `main` is, for
Canister.lean, which calls it, and for `lean --run`.
-/

public def main (args : List String) : IO Unit := do
  -- The compiler evaluates closed terms such as `2 ^ 100` at compile time. Making the
  -- numbers depend on the command line (`k` is 0 without arguments) leaves that work to
  -- the runtime, in the canister.
  let k := args.length
  IO.println "Hello from Lean on WebAssembly!"
  IO.println s!"2^{100 + k} = {2 ^ (100 + k)}"
  IO.println s!"2^{31 + k} + 1 = {2 ^ (31 + k) + 1}"
  IO.println s!"UInt64 max = {UInt64.ofNat (2 ^ (64 + k)) - 1}"
  IO.println s!"sum of 0..100 = {(List.range 101).foldl (· + ·) 0}"
  IO.println s!"{"lean".toUpper} {#[3, 1, 2].qsort (· < ·)}"
