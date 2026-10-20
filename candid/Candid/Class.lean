module

public import Candid.Encode
public import Candid.Decode

/-!
The typed layer: Lean types that have Candid types, and `Candid.encode` and `Candid.decode`,
which turn a method's arguments or results, as Lean values, into a message and back.

`CandidType α` is a *type class*: an interface that a type implements with an `instance`, as a
Rust type implements a trait with an `impl`. `[CandidType α]` among a definition's arguments is
a constraint, like `T: CandidType` in Rust, and Lean finds the instance where the definition is
used. Instances can depend on others: `Option α` has a Candid type if `α` has one. When several
instances fit, Lean takes the one of highest priority, and among those the one declared last.

`deriving CandidType` (Candid/Derive.lean) writes instances for structures and inductive types.
-/

public section

open Candid

/-- A Lean type with a Candid type, and the conversions of its values to and from Candid
values. `CandidType.ty Nat` is `Ty.nat`: the type is an explicit argument, as Lean cannot infer
it from the result. `ofValue` gets a value that the decoder made at `ty`, which is all that it
needs to accept. -/
class CandidType (α : Type) where
  ty : Ty
  toValue : α → Value
  ofValue : Value → Except Candid.Error α

/-- The types of a method's arguments, or of its results, which are a sequence: `()` for none,
a type with a `CandidType` for one, and a product for more: `String × Nat × Option Nat` is
`(text, nat, opt nat)`. A product is always a sequence, never a record, and each of its parts is
one argument, a `()` too: `Nat × Unit` is `(nat, null)`. `ofValues` gets as many values as there
are `tys`, which the decoder makes sure of. -/
class CandidArgs (α : Type) where
  tys : Array Ty
  toValues : α → Array Value
  ofValues : Array Value → Except Candid.Error α

namespace CandidType

/-- The error of `ofValue` for a value that is not of the type `t`. -/
def mismatch (t : Ty) (v : Value) : Except Candid.Error α :=
  fail s!"expected a value of type {t.toDidCapped}, got {v.toTextCapped}"

end CandidType

open CandidType (mismatch)

/-- A value of type `reserved`, which carries no information: any value can be read as one. -/
structure Reserved where
  deriving Inhabited, BEq, Repr

instance : CandidType Unit where
  ty := .null
  toValue _ := .null
  ofValue | .null => pure () | v => mismatch .null v

instance : CandidType Bool where
  ty := .bool
  toValue b := .bool b
  ofValue | .bool b => pure b | v => mismatch .bool v

instance : CandidType Nat where
  ty := .nat
  toValue n := .nat n
  ofValue | .nat n => pure n | v => mismatch .nat v

instance : CandidType Int where
  ty := .int
  toValue i := .int i
  ofValue | .int i => pure i | .nat n => pure n | v => mismatch .int v

instance : CandidType UInt8 where
  ty := .nat8
  toValue n := .nat8 n
  ofValue | .nat8 n => pure n | v => mismatch .nat8 v

instance : CandidType UInt16 where
  ty := .nat16
  toValue n := .nat16 n
  ofValue | .nat16 n => pure n | v => mismatch .nat16 v

instance : CandidType UInt32 where
  ty := .nat32
  toValue n := .nat32 n
  ofValue | .nat32 n => pure n | v => mismatch .nat32 v

instance : CandidType UInt64 where
  ty := .nat64
  toValue n := .nat64 n
  ofValue | .nat64 n => pure n | v => mismatch .nat64 v

instance : CandidType Int8 where
  ty := .int8
  toValue i := .int8 i
  ofValue | .int8 i => pure i | v => mismatch .int8 v

instance : CandidType Int16 where
  ty := .int16
  toValue i := .int16 i
  ofValue | .int16 i => pure i | v => mismatch .int16 v

instance : CandidType Int32 where
  ty := .int32
  toValue i := .int32 i
  ofValue | .int32 i => pure i | v => mismatch .int32 v

instance : CandidType Int64 where
  ty := .int64
  toValue i := .int64 i
  ofValue | .int64 i => pure i | v => mismatch .int64 v

instance : CandidType Float32 where
  ty := .float32
  toValue x := .float32 x
  ofValue | .float32 x => pure x | v => mismatch .float32 v

instance : CandidType Float where
  ty := .float64
  toValue x := .float64 x
  ofValue | .float64 x => pure x | v => mismatch .float64 v

instance : CandidType String where
  ty := .text
  toValue s := .text s
  ofValue | .text s => pure s | v => mismatch .text v

instance : CandidType Principal where
  ty := .principal
  toValue p := .principal p
  ofValue | .principal p => pure p | v => mismatch .principal v

instance : CandidType Reserved where
  ty := .reserved
  toValue _ := .reserved
  ofValue _ := pure {}

/-- Lean's `Empty` has no values, as Candid's `empty`. `nomatch e` is a function of a value that
cannot exist. -/
instance : CandidType Empty where
  ty := .empty
  toValue e := nomatch e
  ofValue v := mismatch .empty v

instance [CandidType α] : CandidType (Option α) where
  ty := .opt (CandidType.ty α)
  toValue
    | some a => .opt (some (CandidType.toValue a))
    | none => .opt none
  ofValue
    | .opt (some v) => some <$> CandidType.ofValue v
    | .opt none | .null | .reserved => pure none
    | v => mismatch (.opt (CandidType.ty α)) v

/-- A `vec`. The decoder makes a `blob` of a `vec nat8`, so `Array UInt8` accepts one, a byte at a
time. `Array.mkEmpty n` is an empty array with room for `n` elements. -/
instance [CandidType α] : CandidType (Array α) where
  ty := .vec (CandidType.ty α)
  toValue xs := .vec (xs.map CandidType.toValue)
  ofValue
    | .vec vs => vs.mapM CandidType.ofValue
    | .blob bytes => do
      let mut out := Array.mkEmpty bytes.size
      for b in bytes do
        out := out.push (← CandidType.ofValue (.nat8 b))
      return out
    | v => mismatch (.vec (CandidType.ty α)) v

instance [CandidType α] : CandidType (List α) where
  ty := .vec (CandidType.ty α)
  toValue xs := CandidType.toValue xs.toArray
  ofValue v := Array.toList <$> CandidType.ofValue v

/-- A `blob`, which is a `vec nat8`, with the bytes in a `ByteArray`. -/
instance : CandidType ByteArray where
  ty := .blob
  toValue bytes := .blob bytes
  ofValue
    | .blob bytes => pure bytes
    | .vec vs => ByteArray.mk <$> vs.mapM fun | .nat8 b => pure b | v => mismatch .nat8 v
    | v => mismatch .blob v

/-- A result, `variant { Ok : α; Err : ε }`, as the Rust crate maps `Result`. -/
instance [CandidType ε] [CandidType α] : CandidType (Except ε α) where
  ty := .variantOf #[⟨.name "Ok", CandidType.ty α⟩, ⟨.name "Err", CandidType.ty ε⟩]
  toValue
    | .ok a => .variant (.name "Ok") (CandidType.toValue a)
    | .error e => .variant (.name "Err") (CandidType.toValue e)
  ofValue
    | .variant l v =>
      if l == .name "Ok" then Except.ok <$> CandidType.ofValue v
      else if l == .name "Err" then Except.error <$> CandidType.ofValue v
      else fail s!"expected the case Ok or Err, got {l.text}"
    | v => mismatch (.variantOf #[⟨.name "Ok", CandidType.ty α⟩, ⟨.name "Err", CandidType.ty ε⟩]) v

/-- No arguments, `()`. -/
instance : CandidArgs Unit where
  tys := #[]
  toValues _ := #[]
  ofValues _ := pure ()

/-- One argument. `low` priority: `Unit` has a `CandidType`, `null`, but as arguments it is
none, by the instance above. -/
instance (priority := low) [CandidType α] : CandidArgs α where
  tys := #[CandidType.ty α]
  toValues a := #[CandidType.toValue a]
  ofValues vs := match vs[0]? with
    | some v => CandidType.ofValue v
    | none => fail "expected a value, got none"

/-- An argument followed by more: `α × β × γ` is `α × (β × γ)`, so this makes a sequence. -/
instance [CandidType α] [CandidArgs β] : CandidArgs (α × β) where
  tys := #[CandidType.ty α] ++ CandidArgs.tys β
  toValues | (a, b) => #[CandidType.toValue a] ++ CandidArgs.toValues b
  ofValues vs := do
    let some v := vs[0]? | fail "expected a value, got none"
    return (← CandidType.ofValue v, ← CandidArgs.ofValues (vs.extract 1 vs.size))

/-- An argument followed by `()`, the last part of a product: `α × Unit` is two arguments, the
second `null`. The instance above would take the `()` for no more arguments, by `CandidArgs
Unit`, and make `(5, ())` the one argument `5`. Both fit `Nat × Unit`; Lean takes this one, which
is declared last. In a definition for any `α × β`, where `β` is a variable, only the instance
above fits, so a `()` there is no more arguments. -/
instance [CandidType α] : CandidArgs (α × Unit) where
  tys := #[CandidType.ty α, CandidType.ty Unit]
  toValues | (a, u) => #[CandidType.toValue a, CandidType.toValue u]
  ofValues vs := do
    let (some v, some u) := (vs[0]?, vs[1]?) | fail "expected two values"
    return (← CandidType.ofValue v, ← CandidType.ofValue u)

namespace Candid

/-- The message of a method's arguments or results: `encode ("world", 3)` is the message
`("world", 3)` of type `(text, nat)`. -/
def encode [CandidArgs α] (args : α) : Except Error ByteArray :=
  encodeValues {} ((CandidArgs.tys α).zip (CandidArgs.toValues args))

/-- A method's arguments or results from a message, as the spec's coercion rules convert the
message's values to the types of `α`: `(← IO.ofExcept (decode bytes) : String × Nat)`. -/
def decode [CandidArgs α] (bytes : ByteArray) (config : DecodeConfig := {}) : Except Error α := do
  CandidArgs.ofValues (← decodeValues {} (CandidArgs.tys α) bytes config)

/-- A method of a service, for its `.did`: `method "greet" String String (mode := some .query)`
is `greet : (text) -> (text) query`. -/
def method (name : String) (α β : Type) [CandidArgs α] [CandidArgs β]
    (mode : Option FuncMode := none) : Method :=
  { name, ty := .func (CandidArgs.tys α) (CandidArgs.tys β) (match mode with
      | some m => #[m]
      | none => #[]) }

end Candid
