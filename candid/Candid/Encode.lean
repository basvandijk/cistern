module

public import Candid.Leb128
public import Candid.Value

/-!
The encoder: `Candid.encodeValues` writes a message, the bytes that carry a method's arguments or
results (spec: "Parameters and Results", the function `B`):

    "DIDL"                              the magic number
    leb128(n) entry₀ … entryₙ₋₁         the type table
    leb128(k) I(t₀) … I(tₖ₋₁)           the types of the arguments
    M(v₀ : t₀) … M(vₖ₋₁ : tₖ₋₁)         the values of the arguments

`I(t)` stands for a type. A primitive type is its opcode, a negative number, in SLEB128: `nat` is
-3, the byte `7d`. A composite type (`opt`, `vec`, `record`, `variant`, `func`, `service`) is the
index of its *entry* in the type table, a number from 0 up, also in SLEB128. An entry is the
type's opcode followed by its parts: `opt nat` is `6e 7d`, and `vec (opt nat)` is `6d 01` if
`opt nat` is entry 1. As entries refer to each other by index, the table can describe recursive
types: the entry `6e 00`, at index 0, is `opt` of itself (`type Opt = opt Opt`). `M(v : t)` is the
bytes of the value `v` at the type `t` (spec: "Memory").

The table is built as the Rust crate builds it (`TypeSerialize` in rust/candid/src/ser.rs), so that
both write the same bytes for the same types and values:

- An entry's index is taken *before* its parts are visited, so entries are numbered in pre-order,
  left to right: `vec (opt nat)` is entry 0 and `opt nat` entry 1. A recursive reference to a type
  whose entry is still being written finds its index taken already, which is where a recursive
  definition ends.
- A composite type gets one entry however often it occurs: an anonymous type such as `record {}`
  is looked up by its structure, a `var` by its name. A `var` that stands for a primitive type
  (`type N = nat`) is written as the primitive's opcode: primitive types never have entries.

Rust's `#[derive(CandidType)]` refers to a recursive type inside itself by a "knot" rather than by
a name, which can make its table longer: for `opt List`, with `List = record { head : int; tail :
opt List }`, the outer and the inner `opt List` are different types there and take two entries,
while here both are `opt (var "List")`, one type and one entry. Types with the same names give the
same table as the Rust encoder, which keys a named type by its name too.

The values must match their types constructor for constructor: `Value.nat` is a value of `Ty.nat`
only, not of `Ty.int`, and a record value has exactly its type's fields. The typed layer
(`Candid.encode`) and the text format's parser make such values. A `vec nat8` may be given as a
`Value.blob` or as a `Value.vec` of `Value.nat8`s, which are written alike.
-/

public section

namespace Candid

namespace Encode

/-! ## Helpers -/

/-- The text of a type on one line, cut after 100 characters, for error messages. -/
private def tyText (t : Ty) : String := t.toDidCapped

/-- The error for a value that is not of its type. `{ message := … }` is an `Error` with that
message, whose other field, `offset`, keeps its default, `none`: an encoder has no input to point
into. -/
private def mismatch (t : Ty) (v : Value) : Error :=
  { message := s!"expected a value of type {tyText t}, got {v.toTextCapped}" }

/-- The error for a record value that lacks a field of its type. -/
private def missingField (label : Label) (v : Value) : Error :=
  { message := s!"record field {label.text} is missing in {v.toTextCapped}" }

/-- The error for the types that only the decoder makes, which have no encoding. -/
private def notEncodable (t : Ty) : Error :=
  -- `match` takes a value apart by its constructor, as in Rust; the first arm that fits is taken,
  -- and `_` fits anything.
  match t with
  | .table i => { message := s!"cannot encode at table{i}, an entry of a decoded message's types" }
  | .future op => { message := s!"cannot encode at a future type (opcode {op})" }
  | t => { message := s!"cannot encode at {tyText t}" }

/-- The type that `t` stands for: `t` itself, or if it is a `var`, its definition in `env`,
following definitions that are names themselves (`type A = B`). Fails on a name that `env` does not
define, and on a cycle of names (`type A = B; type B = A`), which stands for no type.
`TypeEnv.resolve` does the same for the decoder, which also follows `table` references into a
message's type table; the encoder has no such table.

`go` is a helper defined in the `where` clause after the body, and visible only to it; it can use
the arguments of `resolve`, such as `t`. Its first argument is the number of steps left: a chain of
names longer than the number of definitions has a cycle. Each call takes one step off, which Lean
sees from the pattern `n + 1`, so it accepts that the recursion ends. -/
private def resolve (env : TypeEnv) (t : Ty) : Except Error Ty :=
  go (env.defs.size + 1) t
where
  go : Nat → Ty → Except Error Ty
    | 0, _ => fail s!"cyclic type definition of {tyText t}"
    | n + 1, .var name => match env.find? name with
      | some definition => go n definition
      | none => fail s!"unbound type identifier {name}"
    | _, other => pure other

/-- Whether the ids of `fields` increase strictly, as `Ty.recordOf` and `Ty.variantOf` order them.

`Id.run do` writes a function as a sequence of steps, with local variables that can change
(`let mut`), loops (`for`) and an early `return`, while the function stays pure: `Id` is the monad
without effects. -/
private def idsIncrease (fields : Array Field) : Bool := Id.run do
  let mut previous : Option UInt32 := none
  for f in fields do
    -- `if let some p := previous then` runs only if `previous` is `some p`, with `p` bound.
    if let some p := previous then
      if p ≥ f.label.id then return false
    previous := some f.label.id
  return true

/-- The fields sorted by id, the order of the binary format, or an error if two have the same id.
Fields that `Ty.recordOf` or `Ty.variantOf` made are sorted already, which is checked first, as it
is cheaper than sorting. -/
private def sortedFields (fields : Array Field) : Except Error (Array Field) :=
  if idsIncrease fields then pure fields
  else
    let sorted := Field.sortById fields
    match Field.duplicate? sorted with
    | some (a, b) => fail s!"duplicate field id {a.label.id}: {a.label.text} and {b.label.text}"
    | none => pure sorted

/-- Whether the names of `methods` increase strictly, as `Ty.serviceOf` orders them. `<` on
`String` compares code points, which is the byte order of their UTF-8. -/
private def namesIncrease (methods : Array Method) : Bool := Id.run do
  let mut previous : Option String := none
  for m in methods do
    if let some p := previous then
      if !(p < m.name) then return false
    previous := some m.name
  return true

/-- The methods sorted by name, or an error if two have the same name. -/
private def sortedMethods (methods : Array Method) : Except Error (Array Method) := do
  if namesIncrease methods then return methods
  let sorted := methods.qsort (·.name < ·.name)
  let mut previous : Option String := none
  for m in sorted do
    if previous == some m.name then
      fail s!"duplicate method name {quote m.name}"
    previous := some m.name
  return sorted

/-! ## The type table -/

/-- The state of the type table while it is built. -/
private structure Table where
  /-- The bytes of each entry, by index. An entry is empty from when its index is taken until its
  parts have entries and its bytes are known. -/
  entries : Array ByteArray := #[]
  /-- The anonymous composite types that have an entry: hash, type, index. Lean's `Init` has no
  hash map, so this is an array, searched in order, comparing the hashes first. -/
  anonymous : Array (UInt64 × Ty × Nat) := #[]
  /-- The names whose definitions have an entry, with its index. -/
  names : Array (String × Nat) := #[]

/-- The monad in which the table is built. `EStateM ε σ α` is Lean's type of computations that
have a state of type `σ` and may fail with an error of type `ε`: functions from a state to either
a result of type `α` and a new state, or an error. Such a type of computations is a *monad*, and a
`do` block writes one as a sequence of steps: `← x` runs `x` and takes its result, `get` reads the
state, `modify f` replaces it with `f` of it, and `throw e` fails with `e`. The state is passed
from step to step without appearing in the code, as a `&mut Table` would be in Rust. -/
private abbrev TableM := EStateM Error Table

/-- Takes the next index of the table, for an entry whose bytes come later. `modifyGet f` changes
the state with `f`, which also returns the result; `{ s with entries := e }` is the structure `s`
with its field `entries` replaced by `e`. -/
private def allocate : TableM Nat :=
  modifyGet fun s => (s.entries.size, { s with entries := s.entries.push .empty })

/-- Sets the bytes of the entry at `index`. -/
private def setEntry (index : Nat) (bytes : ByteArray) : TableM Unit :=
  modify fun s => { s with entries := s.entries.setIfInBounds index bytes }

-- The next three functions call each other, which `mutual … end` allows. They are `partial`: Lean
-- accepts a recursive function only if it can prove that the recursion ends, or if it is marked
-- `partial`, which skips the proof (the function can then not be used in proofs, and its result
-- type needs a default value, an `Inhabited` instance, which `EStateM` has). These functions
-- recurse into the arrays of a `Ty`, which Lean's automatic proofs do not see through. They end
-- because a type is a finite tree and each name is expanded once: its index is recorded before
-- its definition is visited.
mutual

/-- `I(t)`: the reference to `t`, its opcode if it is primitive, else the index of its entry. A
type without an entry yet gets the next index, then its parts get theirs, then its entry's bytes
are set. -/
private partial def typeRef (env : TypeEnv) (t : Ty) : TableM Int := do
  if let some opcode := t.primOpcode? then
    return opcode
  match t with
  | .var name =>
    if let some (_, index) := (← get).names.find? (·.1 == name) then
      return index
    -- `liftExcept` turns the `Except` of `resolve` into a step of this monad.
    let definition ← liftExcept (resolve env t)
    if let some opcode := definition.primOpcode? then
      return opcode
    let index ← allocate
    modify fun s => { s with names := s.names.push (name, index) }
    setEntry index (← entryBytes env definition)
    return index
  | .table _ | .future _ => throw (notEncodable t)
  | _ =>
    let h := hash t
    if let some (_, _, index) := (← get).anonymous.find? fun (h', t', _) => h' == h && t' == t then
      return index
    let index ← allocate
    modify fun s => { s with anonymous := s.anonymous.push (h, t, index) }
    setEntry index (← entryBytes env t)
    return index

/-- The bytes of the entry of the composite type `t`, whose parts get entries first if they have
none. The bytes are built in a local variable, which no one else refers to, so that each `push`
and `++` extends it in place rather than copying it. -/
private partial def entryBytes (env : TypeEnv) (t : Ty) : TableM ByteArray := do
  match t with
  | .opt t => return Leb128.pushInt (Leb128.ofInt Ty.optOpcode) (← typeRef env t)
  | .vec t => return Leb128.pushInt (Leb128.ofInt Ty.vecOpcode) (← typeRef env t)
  | .record fields => fieldsEntry env Ty.recordOpcode fields
  | .variant cases => fieldsEntry env Ty.variantOpcode cases
  | .func args rets modes =>
    if modes.size > 1 then
      throw { message := s!"a function type has at most one mode, not {modes.size}: {tyText t}" }
    let mut out := Leb128.ofInt Ty.funcOpcode
    out := Leb128.pushNat out args.size
    for arg in args do
      out := Leb128.pushInt out (← typeRef env arg)
    out := Leb128.pushNat out rets.size
    for ret in rets do
      out := Leb128.pushInt out (← typeRef env ret)
    out := Leb128.pushNat out modes.size
    for mode in modes do
      out := out.push mode.code
    return out
  | .service methods =>
    let methods ← liftExcept (sortedMethods methods)
    let mut out := Leb128.ofInt Ty.serviceOpcode
    out := Leb128.pushNat out methods.size
    for m in methods do
      -- The spec: "The serialised data type representing a method type must denote a function
      -- type", which decoders check.
      let .func .. ← liftExcept (resolve env m.ty)
        | throw { message := s!"method {quote m.name} has type {tyText m.ty}, not a function type" }
      let name := m.name.toUTF8
      out := Leb128.pushNat out name.size
      out := out ++ name
      out := Leb128.pushInt out (← typeRef env m.ty)
    return out
  | t => throw (notEncodable t)

/-- The bytes of the entry of a record or variant type: its opcode, the number of fields, and the
id and type of each, in the order of the ids. -/
private partial def fieldsEntry (env : TypeEnv) (opcode : Int) (fields : Array Field) :
    TableM ByteArray := do
  let fields ← liftExcept (sortedFields fields)
  let mut out := Leb128.ofInt opcode
  out := Leb128.pushNat out fields.size
  for f in fields do
    out := Leb128.pushNat out f.label.id.toNat
    out := Leb128.pushInt out (← typeRef env f.ty)
  return out

end

/-- The type table of a message with arguments of the types `tys`, and the reference `I(t)` to
each of them. `run` starts the computation with an empty table, `{}`, and returns its result with
the final state, or the error. -/
private def typeTable (env : TypeEnv) (tys : Array Ty) :
    Except Error (Array ByteArray × Array Int) :=
  match (tys.mapM (typeRef env)).run {} with
  | .ok refs table => pure (table.entries, refs)
  | .error e _ => throw e

/-! ## Values -/

/-- The monad in which values are written: its state is the message so far, which each step
extends. As the state is only ever passed on, never copied, it is extended in place. -/
private abbrev WriteM := EStateM Error ByteArray

/-- Appends a byte. `(·.push b)` is the function `fun out => out.push b`. -/
private def emit (b : UInt8) : WriteM Unit := modify (·.push b)

/-- Appends bytes. -/
private def emitBytes (bytes : ByteArray) : WriteM Unit := modify (· ++ bytes)

/-- Appends a number in LEB128. -/
private def emitNat (n : Nat) : WriteM Unit := modify (Leb128.pushNat · n)

/-- Appends a number in SLEB128. -/
private def emitInt (i : Int) : WriteM Unit := modify (Leb128.pushInt · i)

/-- Appends the `width` low bytes of `n`, least significant first (little-endian): the fixed-width
numbers, and the IEEE 754 bits of floats. -/
private def emitLittleEndian (n : UInt64) (width : Nat) : WriteM Unit :=
  modify fun out => Id.run do
    let mut out := out
    for i in [0:width] do
      out := out.push (n >>> (8 * i).toUInt64).toUInt8
    return out

/-- Appends a text: the length of its UTF-8, then the UTF-8. -/
private def emitText (s : String) : WriteM Unit := do
  let bytes := s.toUTF8
  emitNat bytes.size
  emitBytes bytes

/-- Appends a principal, the value of a `principal` or a `service`: `01`, which marks a
transparent reference (the spec's `id(b)`; `00` would be an opaque one, which only the system
understands), then the length and the bytes. A principal has at most 29 bytes, which decoders
check. -/
private def emitPrincipal (p : Principal) : WriteM Unit := do
  if p.bytes.size > Principal.maxLength then
    throw { message := s!"a principal has at most {Principal.maxLength} bytes, not {p.bytes.size}" }
  emit 1
  emitNat p.bytes.size
  emitBytes p.bytes

/-- The value of the field with id `id` among a record value's fields, looked for at `position`
first, which is where it is when the value's fields are in the type's order, as usual. -/
private def fieldValue? (values : Array (Label × Value)) (position : Nat) (id : UInt32) :
    Option Value :=
  match values[position]? with
  | some (label, v) => if label.id == id then some v else search
  | none => search
where
  search : Option Value := (values.find? (·.1.id == id)).map (·.2)

/-- The position of the case with id `id` among `cases`, which are sorted by id, and the case: a
binary search, as a variant can have many cases, and a name's id is computed each time it is
needed. -/
private def findCase (cases : Array Field) (id : UInt32) : Option (Nat × Field) := Id.run do
  let mut lo := 0
  let mut hi := cases.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let c := cases[mid]!
    let cid := c.label.id
    if cid == id then return some (mid, c)
    if cid < id then lo := mid + 1 else hi := mid
  return none

/-- `M(value : ty)`: appends the bytes of `value` at the type `ty`, or fails if `value` is not of
that type. `partial`, as it recurses into a value's arrays; it ends because each call is on a part
of `value`, and a type name is followed to a type that is not a name. -/
private partial def writeValue (env : TypeEnv) (ty : Ty) (value : Value) : WriteM Unit := do
  -- `match ty, value with` matches both at once; the arms are tried in order.
  match ty, value with
  | .var _, v => writeValue env (← liftExcept (resolve env ty)) v
  | .null, .null => pure ()
  | .bool, .bool b => emit (if b then 1 else 0)
  | .nat, .nat n => emitNat n
  | .int, .int i => emitInt i
  | .nat8, .nat8 n => emit n
  | .nat16, .nat16 n => emitLittleEndian n.toUInt64 2
  | .nat32, .nat32 n => emitLittleEndian n.toUInt64 4
  | .nat64, .nat64 n => emitLittleEndian n 8
  -- A signed number's bytes are those of its two's complement, which `toUInt8` … `toUInt64` give.
  | .int8, .int8 i => emit i.toUInt8
  | .int16, .int16 i => emitLittleEndian i.toUInt16.toUInt64 2
  | .int32, .int32 i => emitLittleEndian i.toUInt32.toUInt64 4
  | .int64, .int64 i => emitLittleEndian i.toUInt64 8
  | .float32, .float32 x => emitLittleEndian x.toBits.toUInt64 4
  | .float64, .float64 x => emitLittleEndian x.toBits 8
  | .text, .text s => emitText s
  | .reserved, .reserved => pure ()
  | .empty, _ => throw { message := "cannot encode a value of type empty, which has no values" }
  | .principal, .principal p => emitPrincipal p
  | .service _, .service p => emitPrincipal p
  | .func .., .func p m =>
    -- `01` marks a public method (the spec's `pub(s, n)`): its service, then its name.
    emit 1
    emitPrincipal p
    emitText m
  | .opt _, .opt none => emit 0
  | .opt t, .opt (some v) =>
    emit 1
    writeValue env t v
  | .vec t, .vec elems =>
    -- The element type is resolved once, rather than for each element.
    let t ← liftExcept (resolve env t)
    emitNat elems.size
    for e in elems do
      writeValue env t e
  | .vec t, .blob bytes =>
    let .nat8 ← liftExcept (resolve env t) | throw (mismatch ty value)
    emitNat bytes.size
    emitBytes bytes
  | .record fields, .record values =>
    let fields ← liftExcept (sortedFields fields)
    for h : i in [0:fields.size] do
      let field := fields[i]
      -- `let some v := e | alt` binds `v` if `e` is `some v`, and runs `alt` otherwise.
      let some v := fieldValue? values i field.label.id | throw (missingField field.label value)
      writeValue env field.ty v
    if values.size != fields.size then
      -- Every field of the type has a value, so the value has a field that the type does not, or
      -- has one twice.
      match values.find? fun (label, _) => !fields.any (·.label.id == label.id) with
      | some (label, _) =>
        throw { message := s!"record field {label.text} is not in the type {tyText ty}" }
      | none =>
        throw { message := s!"a field is given twice in the record {value.toTextCapped}" }
  | .variant cases, .variant label v =>
    let cases ← liftExcept (sortedFields cases)
    -- A variant value is the position of its case among the type's cases, then its payload.
    let some (index, found) := findCase cases label.id
      | throw { message := s!"variant case {label.text} is not in the type {tyText ty}" }
    emitNat index
    writeValue env found.ty v
  | .table _, _ | .future _, _ => throw (notEncodable ty)
  | _, _ => throw (mismatch ty value)

/-- Appends the values of `args`, each at its type, to `out`. -/
private def writeValues (env : TypeEnv) (args : Array (Ty × Value)) (out : ByteArray) :
    Except Error ByteArray :=
  match (args.forM fun (t, v) => writeValue env t v).run out with
  | .ok () out => pure out
  | .error e _ => throw e

end Encode

/-- The message of the arguments `args`, each a type and a value of it, as the spec's `B` defines
it: `DIDL`, the type table, the argument types, and the values. `var`s in the types are names of
definitions in `env`. `encodeValues {} #[(.bool, .bool true)]` is the message `(true)`, the bytes
`44 49 44 4c 00 01 7e 01`.

Fails if a value is not of its type (see the module's description), on a value of type `empty`, on
a name that `env` does not define, on two fields with the same id, on a function type with more
than one mode, on a service with two methods of the same name or a method whose type is not a
function type, on a principal of more than 29 bytes, and on a `table` or `future` type, which only
the decoder makes. -/
def encodeValues (env : TypeEnv) (args : Array (Ty × Value)) : Except Error ByteArray := do
  let (table, refs) ← Encode.typeTable env (args.map (·.1))
  let mut out := "DIDL".toUTF8
  out := Leb128.pushNat out table.size
  for entry in table do
    out := out ++ entry
  out := Leb128.pushNat out refs.size
  for r in refs do
    out := Leb128.pushInt out r
  Encode.writeValues env args out

end Candid
