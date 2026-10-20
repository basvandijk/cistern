module

public import Candid.Value
public import Candid.Subtype
public import Candid.Leb128

/-!
Decoding: from a message, the bytes of a method's arguments or results, to `Value`s of the types
that the receiver expects (spec: "Deserialisation", "Coercion").

A message is `DIDL`, a *type table* of composite types, the types of the arguments, which refer
to the table by index, and then the values, one after the other, written at those types. The
decoder reads the header, then each value at two types at once: the type that the message gives
it, the *wire* type, and the type that the receiver expects. Where the two differ, the spec's
coercion rules say what to make of the value: a `nat` is read as an `int`, a record's unknown
fields are skipped, a missing `opt` field is `none`, and a value that does not fit an `opt` type
is `none` too.

So decoding can fail in two ways. A *coercion* failure is a value that does not fit the
expected type: the spec's "no `v'` exists". Under `opt`, the decoder recovers from it: it goes
back to the start of the value, skips it, and makes `none` of it. Every other failure is
*fatal*: malformed input (a byte `02` for a `bool`, text that is not UTF-8, a message that ends
too soon) or a limit reached.

Limits, from `DecodeConfig`: a message is as large and as deep as its sender likes, and the
values of a type such as `vec null` take no bytes, so that fourteen bytes can describe a billion
values (the conformance suite's spacebomb.test.did). The decoder counts the values it decodes,
skips or fills in against its *fuel*, bounds how deeply values nest, and checks every count in
the message against the bytes that are left before it reads the items counted.

Skipping a value is decoding it at its own wire type and dropping the result, so skipped values
are checked as thoroughly as the others.
-/

public section

namespace Candid

/-- Limits on the work that decoding a message may take. `{}` is the default, and
`{ maxDepth := 64 }` changes one limit. -/
structure DecodeConfig where
  /-- How deeply values may nest, and subtype checks of references recurse. -/
  maxDepth : Nat := 512
  /-- How many values may be decoded, skipped, or filled in for a missing field or argument,
  each counted once, together with the steps of subtype checks of references; `none` for
  `16 × size + 10_000`, where `size` is the length of the message in bytes. -/
  fuel : Option Nat := none
  /-- How many entries the type table may have. -/
  maxTypeTableLength : Nat := 10_000
  /-- How many bytes the header (magic, type table, argument types) may take. -/
  maxHeaderLength : Nat := 65_536
  deriving Inhabited, Repr

namespace Decoder

/-! ## The decoder's monad -/

/-- Why decoding failed, with the offset of the byte where it did. A `coercion` failure is a
value that does not fit the expected type, from which an `opt` recovers; a `fatal` one is
malformed input or a limit reached.

A coercion failure's message is a function that makes the text, `Unit → String`, which is
called only if the failure ends the decoding. Under `opt`, the decoder recovers from the failure
and drops its message, and a message can make it do so for every element of a vector, while the
text can name a type of thousands of fields: making it every time would cost far more than the
values do. -/
private inductive Failure where
  | coercion (message : Unit → String) (offset : Nat)
  | fatal (message : String) (offset : Nat)
  deriving Inhabited

/-- The decoder's state: the message, the position in it, the fuel left, and what the header
says about the message. -/
private structure State where
  /-- The message. -/
  bytes : ByteArray
  /-- The position of the next byte to read. -/
  pos : Nat := 0
  /-- Where reading must stop: at `maxHeaderLength` while the header is read, then at the end of
  the message. -/
  limit : Nat
  /-- How many more values may be decoded, skipped or filled in (see `DecodeConfig.fuel`). -/
  fuel : Nat
  /-- How deeply values may nest, for error messages and subtype checks. -/
  maxDepth : Nat
  /-- The definitions of the names that the expected types use (`Ty.var`). -/
  env : TypeEnv
  /-- The message's type table, to which its types refer (`Ty.table`). -/
  table : Array Ty := #[]
  /-- Pairs of reference types known to be subtypes, and the pairs that the checks assumed. -/
  assumed : TyPairSet := {}
  /-- Pairs of reference types known not to be subtypes. -/
  refuted : TyPairSet := {}

/-- The decoder is a computation in `EStateM Failure State`: from a state, it either succeeds
with a value and a new state, or fails with a `Failure`. `abbrev` makes `M α` a short name for
the type. In its `do` blocks, `← get` reads the state, `modify f` changes it, `throw e` fails,
and `← x` runs `x` and takes its result, or passes its failure on, like `?` in Rust.

`modifyGet f` changes the state and gives a result: `f` gets the state, and gives the result and
the new state. The functions that run for every value change the state that way. Lean changes a
value in place only if nothing else refers to it, and copies it otherwise; after `let s ← get`,
both `s` and the monad refer to the state, so that a `modify` after it copies the whole state,
which costs as much as the rest of decoding a `null`. -/
private abbrev M := EStateM Failure State

/-- When `try x catch e => h` catches a failure of `x`, `EStateM` runs `h` on the state that `x`
failed in, except for what this instance saves before `x` and restores after: the position
only. So a failed attempt to read a value goes back to where the value starts, but the fuel it
spent stays spent, and pairs of types that it found to be subtypes stay known, as they are
anyway. -/
private instance : EStateM.Backtrackable Nat State where
  save s := s.pos
  restore s pos := { s with pos }

/-- Fails fatally, at byte `offset`. -/
private def fatalAt (offset : Nat) (message : String) : M α :=
  throw (.fatal message offset)

/-- Fails fatally, at the current position. -/
private def fatal (message : String) : M α := do
  fatalAt (← get).pos message

/-- Fails to coerce a value, at byte `offset`. The message is made only if it is needed, by
`message ()`: callers write `fun _ => s!"…"`, a function of the value `()` of type `Unit`. -/
private def coercionAt (offset : Nat) (message : Unit → String) : M α :=
  throw (.coercion message offset)

/-- Fails to coerce a value, at the current position. -/
private def coercion (message : Unit → String) : M α := do
  coercionAt (← get).pos message

/-- At most `max` characters of `s`, for error messages, which should not repeat the long names
and types that a message can have. -/
private def capped (s : String) (max : Nat := 100) : String :=
  if s.length ≤ max then s else String.ofList (s.toList.take max) ++ "…"

/-- A number that the message gives, such as a length, for an error message: in decimal, or from
2^64 on, only that it is that large. A message can hold a number of millions of digits, and
writing one out in decimal takes time in proportion to the square of its length. -/
private def numText (n : Nat) : String :=
  if n < 2 ^ 64 then toString n else "2^64 or more"

/-- A signed number that the message gives, for an error message, as `numText` writes one. -/
private def intText (i : Int) : String :=
  if i ≥ 2 ^ 64 then "2^64 or more" else if i ≤ -2 ^ 64 then "-2^64 or less" else toString i

/-- The text of a type, for error messages. -/
private def tyText (t : Ty) : String := t.toDidCapped

/-- Fails because a value of the wire type `w` does not fit the expected type `e`.
`@[noinline]` keeps the function a function of its own: copied into `decode`, Lean made the
message's function before it looked at the types, for every value. -/
@[noinline] private def mismatch (w e : Ty) : M α :=
  coercion fun _ => s!"{tyText w} cannot be deserialized to {tyText e}"

/-- Fails because the wire type `w` of a reference is not a subtype of the expected type `e`. -/
@[noinline] private def notSubtype (w e : Ty) : M α :=
  coercion fun _ => s!"{tyText w} is not a subtype of {tyText e}"

/-- Counts one value against the fuel, in place (see `M`). `@[inline]` copies the function into
its callers, which saves a call and the allocation of its result. -/
@[inline] private def spend : M Unit := do
  let ok ← modifyGet fun s =>
    if s.fuel == 0 then (false, s) else (true, { s with fuel := s.fuel - 1 })
  unless ok do fatal "Decoding cost exceeds the limit"

/-! ## Reading bytes and numbers -/

/-- Fails because the input ended. While the header is read, the input ends after
`maxHeaderLength` bytes, so if the message goes on, the header is too long. -/
private def truncated (message : String) : M α := do
  let s ← get
  if s.limit < s.bytes.size then fatal s!"Type table header exceeds the limit of {s.limit} bytes"
  else fatal message

/-- Reads the `n` bytes at the position with `read`, which gets the message and the position,
and moves past them, or gives `none` if fewer are left. The check and the move are one
`modifyGet`, so that the state changes in place (see `M`). -/
@[inline] private def take? (n : Nat) (read : ByteArray → Nat → α) : M (Option α) :=
  modifyGet fun s =>
    if n ≤ s.limit - s.pos then (some (read s.bytes s.pos), { s with pos := s.pos + n })
    else (none, s)

/-- Reads a little-endian number of `width` bytes, at most 8: byte `i` is bits `8i` to `8i + 7`.
The bytes are read one by one rather than copied out, which would allocate an array. `let mut`
declares a variable that the `for` loop below it can change, and `let some v ← x | alt` runs
`x`, and takes the value out of the `Option` that it gives, or does `alt` if there is none. -/
private def readFixed (width : Nat) : M UInt64 := do
  let some v ← take? width (fun bytes pos => Id.run do
      let mut v : UInt64 := 0
      for i in [0:width] do
        v := v ||| (bytes[pos + i]!.toUInt64 <<< (8 * i).toUInt64)
      return v)
    | truncated "unexpected end of input"
  return v

/-- Reads one byte. `h : c` names the proof that the condition `c` holds, of which `h.2`, the
second half, is the proof that `s.bytes[s.pos]'h.2` needs: that the index is within the array.
With `bytes[pos]!`, which checks the index itself, Lean copied the state (see `M`). -/
private def readByte : M UInt8 := do
  let b? ← modifyGet fun s =>
    if h : s.pos < s.limit ∧ s.pos < s.bytes.size then
      (some (s.bytes[s.pos]'h.2), { s with pos := s.pos + 1 })
    else (none, s)
  let some b := b? | truncated "unexpected end of input"
  return b

/-- Reads `n` bytes. -/
private def readBytes (n : Nat) : M ByteArray := do
  let some bytes ← take? n fun bytes pos => bytes.extract pos (pos + n)
    | truncated s!"Cannot read {numText n} bytes"
  return bytes

/-- Skips `n` bytes. -/
private def skipBytes (n : Nat) : M Unit := do
  if (← take? n fun _ _ => ()).isNone then truncated s!"Cannot read {numText n} bytes"

/-- Fails unless the rest of the input can hold `n` items of at least `size` bytes each. Every
count is checked so before the items are read, so that a message cannot announce a billion of
them in a few bytes (overshoot.test.did). -/
private def checkCount (n size : Nat) (what : String) : M Unit := do
  let s ← get
  if n * size > s.limit - s.pos then truncated s!"not enough bytes for {numText n} {what}"

/-- The position after the LEB128 number at `i` in `bytes`: after its first byte below 0x80, or
`none` if there is none before `limit`. The function calls itself last, so Lean compiles it to a
loop. `termination_by` says what gets smaller with each call, `limit - i`, so that Lean can
check that the recursion ends. -/
private def lebEndFrom? (bytes : ByteArray) (limit i : Nat) : Option Nat :=
  if i < limit then
    if bytes[i]! < 0x80 then some (i + 1) else lebEndFrom? bytes limit (i + 1)
  else none
termination_by limit - i

/-- The position after the LEB128 number at the current position. Overlong numbers, with high
groups that are zero, are allowed, as the spec says. -/
private def lebEnd : M Nat := do
  let s ← get
  let some stop := lebEndFrom? s.bytes s.limit s.pos | truncated "unexpected end of LEB128"
  return stop

/-- Reads a LEB128 number (spec: `leb128`), with `Leb128.groupsValue`, which takes about
`n log n` steps for a number of `n` bytes. -/
private def readNat : M Nat := do
  let stop ← lebEnd
  modifyGet fun s => (Leb128.groupsValue s.bytes s.pos stop, { s with pos := stop })

/-- Reads a signed LEB128 number (spec: `sleb128`): the groups make a number of `7k` bits in
two's complement, negative if bit 6 of the last byte is set, and then `2^(7k)` less. -/
private def readInt : M Int := do
  let stop ← lebEnd
  modifyGet fun s =>
    let n := Leb128.groupsValue s.bytes s.pos stop
    let last : UInt8 := s.bytes[stop - 1]!
    let v : Int := if last &&& 0x40 != 0 then n - (1 <<< (7 * (stop - s.pos)) : Nat) else n
    (v, { s with pos := stop })

/-- The most bytes that a count, length, index, id or opcode may take: as in the Rust crate,
which reads these as 64-bit numbers. Any longer one would be at least 2^63, more than a message
can hold, or an overlong encoding, and building it as a `Nat` would take time that grows with
its length: a number of 2 MB, the most a message to the IC can have, would take billions of
instructions. -/
private def maxCountBytes : Nat := 10

/-- Fails if the LEB128 number at the current position takes more than `maxCountBytes`. -/
private def checkCountLength : M Unit := do
  let start := (← get).pos
  let stop ← lebEnd
  if stop - start > maxCountBytes then
    fatalAt start
      s!"LEB128 number of more than {maxCountBytes} bytes, where a count, length, index or id is expected"

/-- Reads a count, length, index or id: a LEB128 number of at most `maxCountBytes`. -/
private def readCount : M Nat := do
  checkCountLength
  readNat

/-- Reads a type reference or an opcode: an SLEB128 number of at most `maxCountBytes`. -/
private def readCountInt : M Int := do
  checkCountLength
  readInt

/-- Reads a `bool`: the byte `00` or `01`. -/
private def readBool : M Bool := do
  let start := (← get).pos
  match ← readByte with
  | 0 => return false
  | 1 => return true
  | _ => fatalAt start "Expect 00 or 01"

/-- Reads a text: its length in bytes, then its UTF-8. A `String` in Lean is always valid UTF-8,
so the bytes are checked: `String.fromUTF8?` gives `none` if they are not. -/
private def readText : M String := do
  let start := (← get).pos
  match String.fromUTF8? (← readBytes (← readCount)) with
  | some s => return s
  | none => fatalAt start "invalid utf8"

/-- Reads a principal, as references carry it: the byte `01` (`00`, an opaque reference, is not
supported), the length, at most 29, and the bytes. -/
private def readPrincipal : M Principal := do
  let start := (← get).pos
  match ← readByte with
  | 1 => pure ()
  | 0 => fatalAt start "Opaque reference not supported"
  | _ => fatalAt start "Expect 00 or 01"
  let n ← readCount
  if n > Principal.maxLength then fatalAt start "Principal is longer than 29 bytes"
  return ⟨← readBytes n⟩

/-! ## The header -/

/-- Reads a type in the header (spec: `I`): the index of a table entry, below `size`, the
number of entries, or the opcode of a primitive type. -/
private def readTypeRef (size : Nat) : M Ty := do
  let start := (← get).pos
  let i ← readCountInt
  if i ≥ 0 then
    if i < size then return .table i.toNat
    fatalAt start s!"type index {intText i} out of range"
  match Ty.ofPrimOpcode? i with
  | some t => return t
  | none => fatalAt start s!"unknown opcode {intText i}"

/-- Reads a count, then that many types. -/
private def readTypeRefs (size : Nat) (what : String) : M (Array Ty) := do
  let n ← readCount
  checkCount n 1 what
  let mut tys := #[]
  for _ in [0:n] do
    tys := tys.push (← readTypeRef size)
  return tys

/-- Reads the fields of a record type or the cases of a variant type: their count, then an id
and a type each, with ids that increase, below 2^32 (spec: `T*(<fieldtype>*)`). `if let some last
:= fields.back? then` runs its block if there is a last field, `last`. -/
private def readFields (size : Nat) : M (Array Field) := do
  let start := (← get).pos
  let n ← readCount
  if n ≥ 2 ^ 32 then fatalAt start "field length out of 32-bit range"
  checkCount n 2 "fields"
  let mut fields : Array Field := #[]
  for _ in [0:n] do
    let start := (← get).pos
    let id ← readCount
    if id ≥ 2 ^ 32 then fatalAt start "field id out of 32-bit range"
    if let some last := fields.back? then
      if id ≤ last.label.id.toNat then fatalAt start s!"field id {id} collision or not sorted"
    fields := fields.push { label := .num id.toUInt32, ty := ← readTypeRef size }
  return fields

/-- Reads a function type after its opcode: the arguments, the results, and the modes. The
number of modes is one byte, at most 1, as in the Rust crate, where the spec has a LEB128 count;
the two agree for 0 and 1. -/
private def readFunc (size : Nat) : M Ty := do
  let args ← readTypeRefs size "function arguments"
  let rets ← readTypeRefs size "function results"
  let start := (← get).pos
  let count ← readByte
  if count > 1 then fatalAt start "function annotation length should be at most 1"
  let mut modes := #[]
  for _ in [0:count.toNat] do
    let start := (← get).pos
    match FuncMode.ofCode? (← readByte) with
    | some m => modes := modes.push m
    | none => fatalAt start "Unknown annotation"
  return .func args rets modes

/-- Reads a service type after its opcode: the methods, with a name and a type each, the names
valid UTF-8 and increasing in the order of their bytes, which is the order of `<` on `String`. -/
private def readService (size : Nat) : M Ty := do
  let n ← readCount
  checkCount n 2 "methods"
  let mut methods : Array Method := #[]
  for _ in [0:n] do
    let start := (← get).pos
    let name ← readText
    if let some last := methods.back? then
      unless last.name < name do
        fatalAt start s!"method name {quote (capped name)} duplicate or not sorted"
    methods := methods.push { name, ty := ← readTypeRef size }
  return .service methods

/-- Reads a future type, a type that a later version of Candid may add: an opcode below -24,
then the length of the rest of its entry, which is skipped (spec: "Deserialisation of future
types"). -/
private def readFuture : M Ty := do
  let start := (← get).pos
  let opcode ← readCountInt
  if opcode ≥ -24 then fatalAt start s!"{intText opcode} is not a valid future type"
  skipBytes (← readCount)
  return .future opcode

/-- Reads an entry of the type table, of `size` entries: a composite type, whose opcode, -18 to
-23, is the single byte 0x6e to 0x69, or a future type. A primitive type's opcode, or an index,
is not an entry: it fails as a future type. -/
private def readEntry (size : Nat) : M Ty := do
  let s ← get
  let next := if s.pos < s.limit then s.bytes[s.pos]! else 0
  match next with
  | 0x6e => skipBytes 1; return .opt (← readTypeRef size)
  | 0x6d => skipBytes 1; return .vec (← readTypeRef size)
  | 0x6c => skipBytes 1; return .record (← readFields size)
  | 0x6b => skipBytes 1; return .variant (← readFields size)
  | 0x6a => skipBytes 1; readFunc size
  | 0x69 => skipBytes 1; readService size
  | _ => readFuture

/-- Reads the type table, of at most `maxLength` entries. The methods of a service must have
function types, which only table entries can be. `where` introduces `isFunc`, a definition
local to this one. -/
private def readTable (maxLength : Nat) : M (Array Ty) := do
  let start := (← get).pos
  let n ← readCount
  if n > maxLength then fatalAt start "type table size exceeded"
  checkCount n 2 "type table entries"
  let mut table := #[]
  for _ in [0:n] do
    table := table.push (← readEntry n)
  for t in table do
    if let .service methods := t then
      for m in methods do
        unless isFunc table m.ty do
          fatal s!"Method {capped m.name} has a non-function type {tyText m.ty}"
  return table
where
  isFunc (table : Array Ty) : Ty → Bool
    | .table i => match table[i]? with
      | some (.func ..) => true
      | _ => false
    | _ => false

/-- Reads the header: `DIDL`, the type table, which goes into the state, and the types of the
arguments, which it returns. Then the rest of the message may be read, past
`maxHeaderLength`. -/
private def readHeader (config : DecodeConfig) : M (Array Ty) := do
  unless (← get).bytes.extract 0 4 == "DIDL".toUTF8 do fatalAt 0 "wrong magic"
  skipBytes 4
  let table ← readTable config.maxTypeTableLength
  modify fun s => { s with table }
  let args ← readTypeRefs table.size "arguments"
  modify fun s => { s with limit := s.bytes.size }
  return args

/-! ## Values -/

/-- Follows `var` and `table` references to a type that is not one. The header and
`checkExpected` make sure that every reference leads to a type. An entry of the type table is
never a reference, as `readEntry` reads composite and future types only, so a `table` takes one
step, without `TypeEnv.resolve`'s search. -/
@[inline] private def resolve (t : Ty) : M Ty := do
  match t with
  | .table i =>
    match (← get).table[i]? with
    | some t => return t
    | none => fatal s!"type index {i} out of range"
  | .var _ =>
    let s ← get
    match s.env.resolve s.table t with
    | .ok t => return t
    | .error e => fatal e.message
  | t => return t

/-- The value of a type that is absent from a message, as a missing record field or argument:
`none` at an `opt` type, `null` at `null`, `reserved` at `reserved` (spec: "Records", "Tuple
types"). Other types have none, so the result is an `Option`. -/
private def absentValue? (t : Ty) : M (Option Value) := do
  spend
  return match ← resolve t with
    | .opt _ => some (.opt none)
    | .null => some .null
    | .reserved => some .reserved
    | _ => none

/-- The value of an expected record field that the message does not have. -/
private def absentField (f : Field) : M Value := do
  match ← absentValue? f.ty with
  | some v => return v
  | none => coercion fun _ => s!"field {f.label.text} is not optional field"

/-- The fewest bytes that a value of the wire type `t` takes, to check the length of a vector of
them: 0 for types such as `null` and `record {}`, whose values may take none. -/
private def minSize (t : Ty) : M Nat := do
  return match ← resolve t with
    | .null | .reserved | .empty | .record _ => 0
    | .nat16 | .int16 => 2
    | .nat32 | .int32 | .float32 => 4
    | .nat64 | .int64 | .float64 => 8
    | .principal | .service _ | .future _ => 2
    | .func .. => 4
    | _ => 1

/-- The case with id `id` among `cases`, which are sorted by id: a binary search. -/
private def findCase (cases : Array Field) (id : UInt32) : Option Field := Id.run do
  let mut lo := 0
  let mut hi := cases.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let c := cases[mid]!
    if c.label.id == id then return some c
    if c.label.id < id then lo := mid + 1 else hi := mid
  return none

/-- Whether the wire type of a reference is a subtype of the expected one, as the spec requires
for `func` and `service` values. Pairs found to be subtypes, or not, are kept for the other
values of the message, and the check's steps are paid for with fuel. -/
private def refSubtype (wire expected : Ty) : M Bool := do
  let s ← get
  if s.refuted.contains wire expected then return false
  let limits := { maxDepth := s.maxDepth, fuel := s.fuel }
  match checkSubtype s.env s.table (some limits) s.assumed wire expected with
  | .holds assumed steps =>
    modify fun s => { s with assumed, fuel := s.fuel - steps }
    return true
  | .fails steps =>
    modify fun s => { s with refuted := s.refuted.insert wire expected, fuel := s.fuel - steps }
    return false
  | .exceeded message => fatal message

/-- `opt v`, where `v` is the value that `attempt` decodes. If it does not fit, the decoder goes
back to where `attempt` started, runs `skip` instead, which reads the wire value at its own
type, and makes `none` (spec: "Options"). Fatal failures pass through: `throw e` fails again
with the failure caught. -/
private def orNone (attempt skip : M Value) : M Value := do
  try
    return .opt (some (← attempt))
  catch e =>
    match e with
    | .coercion .. =>
      discard skip
      return .opt none
    | .fatal .. => throw e

/-- Decodes a value of the wire type `wire` at the type `expected`, as the spec's coercion rules
say, with `budget` levels of nesting left: at 0 it fails, which bounds the depth of values and
of type definitions such as `type Opt = opt Opt`, which a value of type `bool` would otherwise
unfold forever.

The definition matches on `budget` first: `0`, or `budget + 1` for any other number, and calls
itself with `budget`, a smaller number, so Lean sees that it ends (structural recursion). Then
it matches on the pair of types; the first pattern that fits wins, and `_` fits anything. -/
private def decode : (budget : Nat) → (wire expected : Ty) → M Value
  | 0, _, _ => do fatal s!"Recursion limit exceeded at depth {(← get).maxDepth}"
  | budget + 1, wire, expected => do
    spend
    let w ← resolve wire
    let e ← resolve expected
    match w, e with
    -- Primitive types: the identity, and a `nat` at `int`. Numbers of a fixed width are read
    -- only at that width.
    | .null, .null => return .null
    | .bool, .bool => return .bool (← readBool)
    | .nat, .nat => return .nat (← readNat)
    | .int, .int => return .int (← readInt)
    | .nat, .int => return .int (← readNat)
    | .nat8, .nat8 => return .nat8 (← readFixed 1).toUInt8
    | .nat16, .nat16 => return .nat16 (← readFixed 2).toUInt16
    | .nat32, .nat32 => return .nat32 (← readFixed 4).toUInt32
    | .nat64, .nat64 => return .nat64 (← readFixed 8)
    | .int8, .int8 => return .int8 (← readFixed 1).toUInt8.toInt8
    | .int16, .int16 => return .int16 (← readFixed 2).toUInt16.toInt16
    | .int32, .int32 => return .int32 (← readFixed 4).toUInt32.toInt32
    | .int64, .int64 => return .int64 (← readFixed 8).toInt64
    -- Floats as their bits, so that any bits are a float, NaNs too.
    | .float32, .float32 => return .float32 (.ofBits (← readFixed 4).toUInt32)
    | .float64, .float64 => return .float64 (.ofBits (← readFixed 8))
    | .text, .text => return .text (← readText)
    -- Any value can be read as `reserved`: it is read at its own type, and dropped.
    | .null, .reserved | .reserved, .reserved => return .reserved
    | _, .reserved =>
      discard (decode budget w w)
      return .reserved
    -- `empty` has no values: a message that claims one is malformed.
    | .empty, .empty => fatal "Cannot decode empty type"
    | _, .empty => coercion fun _ => "Cannot decode empty type"
    -- A service reference is a principal too: the two are written the same way.
    | .principal, .principal | .service _, .principal => return .principal (← readPrincipal)
    -- Options: `null` and `reserved` are `none`; an `opt` on the wire has a byte that says
    -- whether a value follows; any other value is the content, if it fits.
    | .null, .opt _ | .reserved, .opt _ => return .opt none
    | .opt w', .opt t =>
      let start := (← get).pos
      match ← readByte with
      | 0 => return .opt none
      | 1 => orNone (decode budget w' t) (decode budget w' w')
      | _ => fatalAt start "Expect 00 or 01"
    | _, .opt t => orNone (decode budget wire t) (decode budget wire wire)
    | .vec w', .vec t =>
      let n ← readCount
      checkCount n (← minSize w') "vector elements"
      -- A `vec nat8` is a blob, read at once, rather than a `Value` per byte.
      if (← resolve t) == .nat8 && (← resolve w') == .nat8 then
        return .blob (← readBytes n)
      let mut elems := #[]
      for _ in [0:n] do
        elems := elems.push (← decode budget w' t)
      -- At `vec nat8`, only an empty vector of another type gets here: an empty blob.
      return if (← resolve t) == .nat8 then .blob .empty else .vec elems
    | .record wfs, .record efs =>
      -- Both are sorted by id, so one pass over both pairs the fields up. The message has the
      -- values in the order of its fields.
      let mut fields := #[]
      let mut j := 0
      for wf in wfs do
        -- Expected fields before `wf` are not in the message.
        while j < efs.size && efs[j]!.label.id < wf.label.id do
          fields := fields.push (efs[j]!.label, ← absentField efs[j]!)
          j := j + 1
        if j < efs.size && efs[j]!.label.id == wf.label.id then
          fields := fields.push (efs[j]!.label, ← decode budget wf.ty efs[j]!.ty)
          j := j + 1
        else
          -- A field that the receiver does not know is read at its own type, and dropped.
          discard (decode budget wf.ty wf.ty)
      for ef in efs[j:] do
        fields := fields.push (ef.label, ← absentField ef)
      return .record fields
    | .variant wcs, .variant ecs =>
      let start := (← get).pos
      let i ← readCount
      -- `let some wc := x | alt` takes the value out of the `Option` `x`, or does `alt` if there
      -- is none.
      let some wc := wcs[i]?
        | fatalAt start s!"Variant index {numText i} larger than length {wcs.size}"
      -- The receiver must know the case that the message has; the other cases do not matter.
      let some ec := findCase ecs wc.label.id
        | coercionAt start fun _ => s!"Unknown variant field {wc.label.id}"
      return .variant ec.label (← decode budget wc.ty ec.ty)
    -- References: their types must be subtypes, which the decoder has to check.
    | .service _, .service _ =>
      unless (← refSubtype wire expected) do notSubtype w e
      return .service (← readPrincipal)
    | .func .., .func .. =>
      unless (← refSubtype wire expected) do notSubtype w e
      let start := (← get).pos
      match ← readByte with
      | 1 => pure ()
      | 0 => fatalAt start "Opaque reference not supported"
      | _ => fatalAt start "Expect 00 or 01"
      let p ← readPrincipal
      return .func p (← readText)
    -- A future value: its length, a number of references (none, here), and the bytes, which
    -- are skipped. A future type is a subtype of `reserved` and of `opt` types only.
    | .future a, .future b =>
      unless a == b do mismatch w e
      let m ← readCount
      discard readCount
      skipBytes m
      return .reserved
    | _, _ => mismatch w e

/-- Fails if bytes are left after the last value. -/
private def checkEnd : M Unit := do
  let s ← get
  if s.pos < s.bytes.size then fatal "Trailing value after finishing deserialization"

/-- Reads a message and decodes its arguments at the `expected` types, as the spec's rule for
argument sequences says, which is that of tuples: an expected argument that the message does not
have must be of type `opt`, `null` or `reserved`, and arguments that the receiver does not
expect are read, and dropped. So the result has a value for each expected type. -/
private def readArgs (config : DecodeConfig) (expected : Array Ty) : M (Array Value) := do
  let wire ← readHeader config
  let mut values := #[]
  -- `h : i ∈ [0:expected.size]` is the proof that `expected[i]` needs: that `i` is an index.
  for h : i in [0:expected.size] do
    if let some w := wire[i]? then
      values := values.push (← decode config.maxDepth w expected[i])
    else
      match ← absentValue? expected[i] with
      | some v => values := values.push v
      | none => fatal s!"No more values on the wire, the expected type {tyText expected[i]} is not \
          opt, null, or reserved"
  for w in wire[expected.size:] do
    discard (decode config.maxDepth w w)
  checkEnd
  return values

/-- Checks what the decoder relies on in the expected types and the definitions in `env`: that
fields are sorted by id and methods by name, without duplicates, that every name is defined
and leads to a type, and that no type refers to a type table, which only a message has.
`partial`: Lean does not see that the walk over the nested arrays ends. -/
private partial def checkExpected (env : TypeEnv) (tys : Array Ty) : Except Error Unit := do
  for (name, t) in env.defs do
    discard (env.resolve #[] (.var name))
    walk t
  for t in tys do
    walk t
where
  walk : Ty → Except Error Unit
    | .opt t | .vec t => walk t
    | t@(.record fields) | t@(.variant fields) => do
      for i in [1:fields.size] do
        unless fields[i - 1]!.label.id < fields[i]!.label.id do
          fail s!"fields not sorted by id, or not unique: {tyText t}"
      for f in fields do
        walk f.ty
    | .func args rets _ => do
      for t in args do walk t
      for t in rets do walk t
    | t@(.service methods) => do
      for i in [1:methods.size] do
        unless methods[i - 1]!.name < methods[i]!.name do
          fail s!"methods not sorted by name, or not unique: {tyText t}"
      for m in methods do
        walk m.ty
    | .var name =>
      if (env.find? name).isSome then pure () else fail s!"unbound type identifier {name}"
    | .table i => fail s!"an expected type refers to entry {i} of a type table"
    | _ => pure ()

/-- Runs the decoder on `bytes`, and turns a failure into an `Error`. -/
private def run (env : TypeEnv) (bytes : ByteArray) (config : DecodeConfig) (x : M α) :
    Except Error α :=
  let fuel := config.fuel.getD (16 * bytes.size + 10_000)
  let state : State :=
    { bytes, limit := min bytes.size config.maxHeaderLength, fuel, maxDepth := config.maxDepth,
      env }
  match x.run state with
  | .ok a _ => .ok a
  | .error (.coercion message offset) _ => .error { message := message (), offset := some offset }
  | .error (.fatal message offset) _ => .error { message, offset := some offset }

end Decoder

-- `open Decoder in` lets the definition below use the names in `Decoder` without the prefix.
open Decoder in
/-- The arguments of a message, at the `expected` types, whose `var`s refer to `env`: a value for
each expected type, converted from the message's values as the spec's coercion rules say. Fails
on a malformed message, on a value that cannot be converted, and when the message takes more
work than `config` allows. -/
def decodeValues (env : TypeEnv) (expected : Array Ty) (bytes : ByteArray)
    (config : DecodeConfig := {}) : Except Error (Array Value) := do
  checkExpected env expected
  run env bytes config (readArgs config expected)

open Decoder in
/-- A message at its own types: its type table, and its arguments with their types, which refer
to the table with `Ty.table`. A value of a future type is `reserved`, as it can only be
skipped. -/
def decodeAny (bytes : ByteArray) (config : DecodeConfig := {}) :
    Except Error (Array Ty × Array (Ty × Value)) :=
  run {} bytes config do
    let wire ← readHeader config
    let mut args := #[]
    for w in wire do
      args := args.push (w, ← decode config.maxDepth w w)
    checkEnd
    return ((← get).table, args)

end Candid
