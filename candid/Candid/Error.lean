module

/-!
The library's errors. Encoding, decoding and parsing return `Except Candid.Error α`: either
`.ok a`, or `.error e` with what went wrong. `Except` is Lean's counterpart of Rust's `Result`,
with the error type first. In a `do` block of `Except Error`, `throw e` fails, and `← x` takes
the value out of `x` or passes its error on, like `?` in Rust.
-/

public section

namespace Candid

/-- What went wrong, and where in the input, as a byte offset, if it is known. `toString`
renders it as `Candid: <message> at byte <offset>`, which is how a canister rejects a message
whose argument it cannot decode. -/
structure Error where
  message : String
  offset : Option Nat := none
  deriving Inhabited, BEq, Repr

instance : ToString Error where
  toString e := match e.offset with
    | some n => s!"Candid: {e.message} at byte {n}"
    | none => s!"Candid: {e.message}"

/-- Fails with `message`: `fail m` is `throw { message := m }`, an `Error` without an offset, in
`Except Error`. -/
def fail (message : String) : Except Error α :=
  throw { message }

end Candid
