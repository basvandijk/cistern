module

public import Candid.Ty
public import Candid.Principal

/-!
Candid values, as Lean values of the inductive type `Candid.Value`, and their text.

A `Value` does not say what its type is: `.nat 5` is a value of `nat`, and of `int` only once
it is made `.int 5`. The encoder takes values with the types to write them at; the decoder
makes values of the types it is asked for, converting the message's values as the spec's
coercion rules say.

`==` compares values constructor for constructor, as the derived `BEq` does: `.blob` differs from
a `.vec` of the same `.nat8`s, which is why the decoder always makes a `blob` of a `vec nat8`;
`.reserved` differs from `.null`; labels compare by id; and floats compare as numbers, as IEEE
754 says: a NaN differs from itself, and `0.0` equals `-0.0`.
-/

public section

namespace Candid

/-- A Candid value. -/
inductive Value where
  | null
  | bool (b : Bool)
  | nat (n : Nat)
  | int (i : Int)
  | nat8 (n : UInt8)
  | nat16 (n : UInt16)
  | nat32 (n : UInt32)
  | nat64 (n : UInt64)
  | int8 (i : Int8)
  | int16 (i : Int16)
  | int32 (i : Int32)
  | int64 (i : Int64)
  | float32 (x : Float32)
  | float64 (x : Float)
  | text (s : String)
  | reserved
  | principal (p : Principal)
  /-- A reference to a service, by the principal of its canister. -/
  | service (p : Principal)
  /-- A reference to a function: a method of a service. -/
  | func (service : Principal) (method : String)
  /-- `opt v`, or `null` for none. -/
  | opt (v : Option Value)
  | vec (elems : Array Value)
  /-- A `vec nat8`, with its bytes in a `ByteArray` rather than one `Value` each. -/
  | blob (bytes : ByteArray)
  /-- A record's fields. The decoder makes them in the order of the type's fields, by id; the
  encoder takes them in any order. -/
  | record (fields : Array (Label × Value))
  | variant (label : Label) (v : Value)
  deriving BEq, Inhabited

/-- `x` as the text format writes a float: `nan`, `inf`, or decimal digits with at least one
after the point. Lean's `toString` writes six digits after the point (C's `%f`), so this text is
exact for whole numbers, but rounds others to six digits after the point: `1e-7` is `0.0`.
`dropEndWhile` drops the characters at the end that are `'0'`, and gives a *slice*, a part of
the string, which `copy` makes a string of its own. -/
def floatText (x : Float) : String :=
  if x.isNaN then "nan"
  else if x.isInf then (if x > 0 then "inf" else "-inf")
  else
    let s := toString x
    if s.contains '.' then
      -- Drop trailing zeros, but keep a digit after the point.
      let trimmed := (s.dropEndWhile (· == '0')).copy
      if trimmed.endsWith "." then trimmed ++ "0" else trimmed
    else s

/-- Appends a blob's bytes to `out`, as in a string literal: printable ASCII as is, but `"` and
`\`, which are escaped, and other bytes as `\HH`. -/
private def pushBlob (out : String) (bytes : ByteArray) : String := Id.run do
  let mut out := out
  for b in bytes do
    out := if b == 0x22 then out ++ "\\\""
      else if b == 0x5c then out ++ "\\\\"
      else if 0x20 ≤ b && b < 0x7f then out.push (Char.ofNat b.toNat)
      else out ++ "\\" ++ hexDigits b.toNat
  return out

/-- A blob as a string literal: printable ASCII as is, other bytes as `\HH`. -/
def blobText (bytes : ByteArray) : String :=
  pushBlob "\"" bytes ++ "\""

namespace Value

/-- The digits of `n`, for a text that is cut after `limit` characters. A number below
`2 ^ (4 * limit)`, whose decimal digits are quick to compute, is in decimal. A larger one is
written as its first `limit` hexadecimal digits, `0x…`, which a shift computes: Lean computes
the decimal digits of a number by dividing it by 10 again and again, which takes about `d²`
steps for a number of `d` digits, of which a cut text would show but the first. -/
private def natText (limit : Option Nat) (n : Nat) : String :=
  match limit with
  | some limit =>
    if n.log2 < 4 * limit then toString n
    else "0x" ++ hexDigits (n >>> (4 * (n.log2 / 4 + 1 - limit))) limit
  | none => toString n

/-- Appends the text of `v` to `out`. Each part extends `out`, which nothing else refers to, in
place, so that the work grows as the text does: if each value's text were made on its own and
then put into the text of the value around it, a value deep inside others would be copied once
for each of them.

With a `limit`, it stops once `out` has more than `limit` characters, which is all that
`toTextCapped` needs, so that the work stays small however large `v` is: it cuts a long text, a
long method name and a long blob before it writes them, and writes a long number in hexadecimal
(see `natText`). Without one, it writes all of `v`. -/
private partial def appendText (limit : Option Nat) (out : String) (v : Value) : String :=
  if full out then out else
  match v with
  | .null => out ++ "null"
  | .bool b => out ++ toString b
  | .nat n => out ++ natText limit n
  | .int i => out ++ (if i < 0 then "-" else "") ++ natText limit i.natAbs
  | .nat8 n => out ++ toString n
  | .nat16 n => out ++ toString n
  | .nat32 n => out ++ toString n
  | .nat64 n => out ++ toString n
  | .int8 i => out ++ toString i
  | .int16 i => out ++ toString i
  | .int32 i => out ++ toString i
  | .int64 i => out ++ toString i
  | .float32 x => out ++ floatText x.toFloat
  | .float64 x => out ++ floatText x
  | .text s => out ++ quote (cut s)
  | .reserved => out ++ "null"
  | .principal p => out ++ "principal " ++ quote p.toText
  | .service p => out ++ "service " ++ quote p.toText
  | .func p m =>
    -- Whether the name needs quotes depends on all of it, not only on the part that is written.
    let m' := cut m
    out ++ "func " ++ quote p.toText ++ "." ++ (if isPlainName m then m' else quote m')
  | .opt none => out ++ "null"
  | .opt (some v) => appendText limit (out ++ "opt ") v
  | .vec vs => items (out ++ "vec ") vs (appendText limit)
  | .blob bytes =>
    let bytes := match limit with
      | some limit => bytes.extract 0 limit
      | none => bytes
    pushBlob (out ++ "blob \"") bytes ++ "\""
  | .record fields =>
    -- A tuple's fields, 0, 1, …, are written without labels.
    if isTuple fields then items (out ++ "record ") fields fun out (_, v) => appendText limit out v
    else items (out ++ "record ") fields fun out (l, v) =>
      appendText limit (out ++ l.text ++ " = ") v
  | .variant l .null => out ++ "variant { " ++ l.text ++ " }"
  | .variant l v => appendText limit (out ++ "variant { " ++ l.text ++ " = ") v ++ " }"
where
  /-- Whether `out` is longer than the limit. -/
  full (out : String) : Bool := limit.any (out.length > ·)
  /-- The first `limit` characters of `s`, or all of it without a limit. -/
  cut (s : String) : String := match limit with
    | some limit => (s.take limit).copy
    | none => s
  /-- Whether a record's fields are those of a tuple: 0, 1, …. -/
  isTuple (fields : Array (Label × Value)) : Bool := Id.run do
    for h : i in [0:fields.size] do
      if fields[i].1.id != i.toUInt32 then return false
    return true
  /-- `{ x; y }` with `write` appending each of the `xs`, or `{}`. It stops at the first that
  finds `out` full. -/
  items {α : Type} (out : String) (xs : Array α) (write : String → α → String) : String := Id.run do
    if xs.isEmpty then return out ++ "{}"
    let mut out := out ++ "{ "
    let mut first := true
    for x in xs do
      if full out then return out
      out := write (if first then out else out ++ "; ") x
      first := false
    return out ++ " }"

/-- The text of a value, as in the text format: `42`, `"text"`, `opt 1`, `vec { 1; 2 }`,
`record { a = 1; b = "x" }`, `variant { ok = 1 }`, `principal "aaaaa-aa"`. The decimal digits of
a `nat` or `int` of `d` digits take about `d²` steps. -/
def toText (v : Value) : String := appendText none "" v

/-- The text of a value, cut after `max` characters, for error messages, which should not repeat
a whole message. It takes little work however large the value is; a `nat` or `int` of more than
`4 * max` bits is in hexadecimal (`0x…`). -/
def toTextCapped (v : Value) (max : Nat := 100) : String :=
  let s := appendText (some max) "" v
  if s.length ≤ max then s else (s.take max).copy ++ "…"

end Value

instance : ToString Value := ⟨Value.toText⟩

-- `ByteArray` has no `Repr`, so `Value` cannot derive one; this shows the text instead.
instance : Repr Value := ⟨fun v _ => v.toText⟩

end Candid
