import Candid

/-!
Tests of the decoder, `Candid.decodeValues` and `Candid.decodeAny`, and of the subtype check,
`Candid.isSubtype`. A case is a message, the types to decode it at, and what that should give:
values, or an error. Most messages are the conformance suite's (test/*.test.did), a group of cases
per file, with the types and the expected values written here by hand. The other groups test the
limits of `DecodeConfig`, the rows of the coercion table that the suite leaves out, hostile
messages beyond the suite's, `decodeAny`, and the subtype check on its own.

This is a program, not a `module`. It runs with `lean --run Candid/Tests/Decode.lean`, with
`LEAN_PATH` on the library's `.olean` files, and the Nix checks also compile it to wasm32, whose
output must be the same. It prints a line per group of cases and one per case that fails, then a
summary, and returns 1 if a case fails.
-/

open Candid

/-! ## The harness -/

/-- The value of a hexadecimal digit, or 0 for another character. -/
def hexValue (c : Char) : Nat :=
  if '0' ≤ c && c ≤ '9' then c.toNat - '0'.toNat
  else if 'a' ≤ c && c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else if 'A' ≤ c && c ≤ 'F' then c.toNat - 'A'.toNat + 10
  else 0

/-- The bytes of a blob literal of the conformance suite: `\HH` is the byte `HH` in hexadecimal,
and any other character stands for its UTF-8. The literals below are Lean's raw strings,
`r"DIDL\00\00"`, in which `\` is an ordinary character, so that they read as in the suite. -/
def blob (s : String) : ByteArray := Id.run do
  let cs := s.toList.toArray
  let mut out := ByteArray.empty
  let mut i := 0
  while i < cs.size do
    if cs[i]! == '\\' then
      out := out.push (hexValue cs[i + 1]! * 16 + hexValue cs[i + 2]!).toUInt8
      i := i + 3
    else
      for b in cs[i]!.toString.toUTF8 do
        out := out.push b
      i := i + 1
  return out

/-- What a case expects. -/
inductive Expect where
  /-- These values. -/
  | values (vs : Array Value)
  /-- Success, with any values. -/
  | ok
  /-- The values of another message at the same types. -/
  | same (bytes : ByteArray)
  /-- Success, with values that differ from those of another message at the same types. -/
  | differs (bytes : ByteArray)
  /-- Failure. -/
  | fails
  /-- Failure, with a message that contains this text. -/
  | failsWith (text : String)
  /-- Failure, with a message that contains this text, at this byte offset. -/
  | failsAt (text : String) (offset : Nat)

/-- A case: a message, decoded at types whose names refer to the definitions `env`, within the
limits `config`. The fields with a default value, after `:=`, may be left out where a case is
written. -/
structure Case where
  name : String
  env : TypeEnv := {}
  tys : Array Ty
  bytes : ByteArray
  expect : Expect
  config : DecodeConfig := {}
  /-- How many milliseconds decoding may take, for a hostile message that must not take long. The
  limit is far above what such a case takes, tens of milliseconds, so that a slow machine passes
  too: it catches work that grows with the square of the message, which takes seconds. -/
  maxMs : Option Nat := none

/-- Whether `sub` occurs in `s`: splitting `s` at it gives more than one piece. -/
def contains (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- A result of decoding as text, for the line of a case that fails. -/
def render (r : Except Error (Array Value)) : String :=
  match r with
  | .ok vs => s!"ok ({", ".intercalate (vs.toList.map Value.toText)})"
  | .error e => s!"error {e}"

/-- `none` if the result `r` of the case `c` is what the case expects, else `some` reason why it is
not. For `.same` and `.differs`, the other message is decoded at the same types, to compare with.
`match c.expect, r with` matches on both at once; `_, _` is any other pair. -/
def judge (c : Case) (r : Except Error (Array Value)) : Option String :=
  let other (bytes : ByteArray) := decodeValues c.env c.tys bytes c.config
  match c.expect, r with
  | .values vs, .ok vs' => if vs == vs' then none else some s!"expected {render (.ok vs)}"
  | .ok, .ok _ => none
  | .same bytes, .ok vs => match other bytes with
    | .ok vs' => if vs == vs' then none else some s!"expected the same as {render (.ok vs')}"
    | r' => some s!"the other message: {render r'}"
  | .differs bytes, .ok vs => match other bytes with
    | .ok vs' => if vs != vs' then none else some "expected different values"
    | r' => some s!"the other message: {render r'}"
  | .fails, .error _ => none
  | .failsWith text, .error e =>
    if contains e.message text then none else some s!"expected an error with {repr text}"
  | .failsAt text offset, .error e =>
    if contains e.message text && e.offset == some offset then none
    else some s!"expected an error with {repr text} at {offset}"
  | _, _ => some "unexpected outcome"

/-- Decodes the messages of a group of cases, prints a line for each case that fails and one for
the group, and returns how many passed and how many failed. -/
def runCases (group : String) (cases : Array Case) : IO (Nat × Nat) := do
  let mut passed := 0
  let mut failed := 0
  for c in cases do
    let start ← IO.monoMsNow
    let r := decodeValues c.env c.tys c.bytes c.config
    -- The `match` needs `judge`'s result, and so the decoding's, before it picks a branch, so the
    -- clock read in a branch comes after the decoding. (A `let` alone could be computed later,
    -- where its value is first used.)
    match judge c r with
    | none =>
      let ms := (← IO.monoMsNow) - start
      match c.maxMs with
      | some max =>
        if ms ≤ max then passed := passed + 1
        else
          failed := failed + 1
          IO.println s!"FAIL {group}: {c.name}: took {ms} ms, more than {max}"
      | none => passed := passed + 1
    | some why =>
      failed := failed + 1
      IO.println s!"FAIL {group}: {c.name}: {render r}; {why}"
  IO.println s!"{group}: {passed} passed, {failed} failed"
  -- Writes out what was printed, should the program fail after it.
  (← IO.getStdout).flush
  return (passed, failed)

/-! ## Shorthands -/

/-- One value. -/
def ok1 (v : Value) : Expect := .values #[v]

/-- `opt v`. -/
def some' (v : Value) : Value := .opt (some v)

/-- `null` at an `opt` type, the option without a value. -/
def none' : Value := .opt none

/-- A field or case with a name. -/
def field (name : String) (t : Ty) : Field := ⟨.name name, t⟩

/-- A field or case with a number. -/
def nfield (id : UInt32) (t : Ty) : Field := ⟨.num id, t⟩

/-- A record value with its fields sorted by id, as the decoder makes it. -/
def rec (fields : Array (Label × Value)) : Value := .record (fields.qsort (·.1.id < ·.1.id))

/-- The principal of these bytes. -/
def principal (bytes : List UInt8) : Principal := ⟨⟨bytes.toArray⟩⟩

/-- A `ByteArray` of these bytes. -/
def bytes (bs : List UInt8) : ByteArray := ⟨bs.toArray⟩

/-- The principal `w7x7r-cok77-xa`, of the bytes `ca ff ee`. -/
def caffee : Principal := principal [0xca, 0xff, 0xee]

/-- A function type, `func (args) -> (rets) modes`. -/
def func0 (args rets : Array Ty) (modes : Array FuncMode := #[]) : Ty := .func args rets modes

/-! ## prim.test.did -/

/-- The assertions of prim.test.did, in its order: primitive types, missing and extra arguments,
and malformed headers. -/
def prim : Array Case := #[
  -- fundamentally wrong
  { name := "empty", tys := #[], bytes := blob r"", expect := .failsWith "wrong magic" },
  { name := "no magic bytes", tys := #[], bytes := blob r"\00\00", expect := .fails },
  { name := "wrong magic bytes", tys := #[], bytes := blob r"DADL",
    expect := .failsAt "wrong magic" 0 },
  { name := "wrong magic bytes 2", tys := #[], bytes := blob r"DADL\00\00", expect := .fails },
  { name := "overlong typ table length", tys := #[], bytes := blob r"DIDL\80\00\00",
    expect := .values #[] },
  { name := "overlong arg length", tys := #[], bytes := blob r"DIDL\00\80\00",
    expect := .values #[] },
  -- nullary input
  { name := "nullary", tys := #[], bytes := blob r"DIDL\00\00", expect := .values #[] },
  { name := "nullary: too long", tys := #[], bytes := blob r"DIDL\00\00\00",
    expect := .failsAt "Trailing value after finishing deserialization" 6 },
  { name := "Additional parameters are ignored", tys := #[], bytes := blob r"DIDL\00\01\7f",
    expect := .values #[] },
  { name := "Not a primitive type", tys := #[], bytes := blob r"DIDL\00\01\6e",
    expect := .failsAt "unknown opcode -18" 6 },
  { name := "Out of range type", tys := #[], bytes := blob r"DIDL\00\01\5e",
    expect := .failsWith "unknown opcode -34" },
  -- missing arguments
  { name := "missing argument: nat fails", tys := #[.nat], bytes := blob r"DIDL\00\00",
    expect := .failsWith
      "No more values on the wire, the expected type nat is not opt, null, or reserved" },
  { name := "missing argument: empty fails", tys := #[.empty], bytes := blob r"DIDL\00\00",
    expect := .fails },
  { name := "missing argument: null", tys := #[.null], bytes := blob r"DIDL\00\00",
    expect := ok1 .null },
  { name := "missing argument: opt empty", tys := #[.opt .empty], bytes := blob r"DIDL\00\00",
    expect := ok1 none' },
  { name := "missing argument: opt null", tys := #[.opt .null], bytes := blob r"DIDL\00\00",
    expect := ok1 none' },
  { name := "missing argument: opt nat", tys := #[.opt .nat], bytes := blob r"DIDL\00\00",
    expect := ok1 none' },
  { name := "missing argument: reserved", tys := #[.reserved], bytes := blob r"DIDL\00\00",
    expect := .same (blob r"DIDL\00\01\70") },
  -- primitive types
  { name := "null", tys := #[.null], bytes := blob r"DIDL\00\01\7f", expect := ok1 .null },
  { name := "null: wrong type", tys := #[.null], bytes := blob r"DIDL\00\01\7e", expect := .fails },
  { name := "null: too long", tys := #[.null], bytes := blob r"DIDL\00\01\7f\00",
    expect := .fails },
  { name := "bool: false", tys := #[.bool], bytes := blob r"DIDL\00\01\7e\00",
    expect := ok1 (.bool false) },
  { name := "bool: true", tys := #[.bool], bytes := blob r"DIDL\00\01\7e\01",
    expect := ok1 (.bool true) },
  { name := "bool: missing", tys := #[.bool], bytes := blob r"DIDL\00\01\7e",
    expect := .failsAt "unexpected end of input" 7 },
  { name := "bool: out of range", tys := #[.bool], bytes := blob r"DIDL\00\01\7e\02",
    expect := .failsAt "Expect 00 or 01" 7 },
  { name := "bool: out of range ff", tys := #[.bool], bytes := blob r"DIDL\00\01\7e\ff",
    expect := .fails },
  { name := "nat: 0", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\00", expect := ok1 (.nat 0) },
  { name := "nat: 1", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\01", expect := ok1 (.nat 1) },
  { name := "nat: 0x7f", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\7f",
    expect := ok1 (.nat 127) },
  { name := "nat: leb (two bytes)", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\80\01",
    expect := ok1 (.nat 128) },
  { name := "nat: leb (two bytes, all bits)", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\ff\7f",
    expect := ok1 (.nat 16383) },
  { name := "nat: leb too short", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\80",
    expect := .failsWith "unexpected end of LEB128" },
  { name := "nat: leb overlong", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\80\00",
    expect := ok1 (.nat 0) },
  { name := "nat: leb overlong 127", tys := #[.nat], bytes := blob r"DIDL\00\01\7d\ff\00",
    expect := ok1 (.nat 127) },
  { name := "nat: big number", tys := #[.nat],
    bytes := blob r"DIDL\00\01\7d\80\80\98\f4\e9\b5\ca\6a",
    expect := ok1 (.nat 60000000000000000) },
  { name := "int: 0", tys := #[.int], bytes := blob r"DIDL\00\01\7c\00", expect := ok1 (.int 0) },
  { name := "int: 1", tys := #[.int], bytes := blob r"DIDL\00\01\7c\01", expect := ok1 (.int 1) },
  { name := "int: -1", tys := #[.int], bytes := blob r"DIDL\00\01\7c\7f",
    expect := ok1 (.int (-1)) },
  { name := "int: -64", tys := #[.int], bytes := blob r"DIDL\00\01\7c\40",
    expect := ok1 (.int (-64)) },
  { name := "int: leb (two bytes)", tys := #[.int], bytes := blob r"DIDL\00\01\7c\80\01",
    expect := ok1 (.int 128) },
  { name := "int: leb too short", tys := #[.int], bytes := blob r"DIDL\00\01\7c\80",
    expect := .fails },
  { name := "int: leb overlong (0s)", tys := #[.int], bytes := blob r"DIDL\00\01\7c\80\00",
    expect := ok1 (.int 0) },
  { name := "int: leb overlong (1s)", tys := #[.int], bytes := blob r"DIDL\00\01\7c\ff\7f",
    expect := ok1 (.int (-1)) },
  { name := "int: leb not overlong when signed", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\ff\00", expect := ok1 (.int 127) },
  { name := "int: leb not overlong when signed -128", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\80\7f", expect := ok1 (.int (-128)) },
  { name := "int: big number", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\80\80\98\f4\e9\b5\ca\ea\00",
    expect := ok1 (.int 60000000000000000) },
  { name := "int: negative big number", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\80\80\e8\8b\96\ca\b5\95\7f",
    expect := ok1 (.int (-60000000000000000)) },
  { name := "nat <: int: 0", tys := #[.int], bytes := blob r"DIDL\00\01\7d\00",
    expect := ok1 (.int 0) },
  { name := "nat <: int: 1", tys := #[.int], bytes := blob r"DIDL\00\01\7d\01",
    expect := ok1 (.int 1) },
  { name := "nat <: int: 127", tys := #[.int], bytes := blob r"DIDL\00\01\7d\7f",
    expect := ok1 (.int 127) },
  { name := "nat <: int: 128", tys := #[.int], bytes := blob r"DIDL\00\01\7d\80\01",
    expect := ok1 (.int 128) },
  { name := "nat <: int: 16383", tys := #[.int], bytes := blob r"DIDL\00\01\7d\ff\7f",
    expect := ok1 (.int 16383) },
  { name := "int </: nat", tys := #[.nat], bytes := blob r"DIDL\00\01\7c\01",
    expect := .failsAt "int cannot be deserialized to nat" 7 },
  { name := "nat8: 0", tys := #[.nat8], bytes := blob r"DIDL\00\01\7b\00",
    expect := ok1 (.nat8 0) },
  { name := "nat8: 255", tys := #[.nat8], bytes := blob r"DIDL\00\01\7b\ff",
    expect := ok1 (.nat8 255) },
  { name := "nat8: too short", tys := #[.nat8], bytes := blob r"DIDL\00\01\7b", expect := .fails },
  { name := "nat8: too long", tys := #[.nat8], bytes := blob r"DIDL\00\01\7b\00\00",
    expect := .fails },
  { name := "nat16: 256", tys := #[.nat16], bytes := blob r"DIDL\00\01\7a\00\01",
    expect := ok1 (.nat16 256) },
  { name := "nat16: 65535", tys := #[.nat16], bytes := blob r"DIDL\00\01\7a\ff\ff",
    expect := ok1 (.nat16 65535) },
  { name := "nat16: too short", tys := #[.nat16], bytes := blob r"DIDL\00\01\7a\00",
    expect := .fails },
  { name := "nat16: too long", tys := #[.nat16], bytes := blob r"DIDL\00\01\7a\00\00\00",
    expect := .fails },
  { name := "nat32: 256", tys := #[.nat32], bytes := blob r"DIDL\00\01\79\00\01\00\00",
    expect := ok1 (.nat32 256) },
  { name := "nat32: 4294967295", tys := #[.nat32], bytes := blob r"DIDL\00\01\79\ff\ff\ff\ff",
    expect := ok1 (.nat32 4294967295) },
  { name := "nat32: too short", tys := #[.nat32], bytes := blob r"DIDL\00\01\79\00\00\00",
    expect := .fails },
  { name := "nat32: too long", tys := #[.nat32], bytes := blob r"DIDL\00\01\79\00\00\00\00\00",
    expect := .fails },
  { name := "nat64: 4294967295", tys := #[.nat64],
    bytes := blob r"DIDL\00\01\78\ff\ff\ff\ff\00\00\00\00", expect := ok1 (.nat64 4294967295) },
  { name := "nat64: max", tys := #[.nat64], bytes := blob r"DIDL\00\01\78\ff\ff\ff\ff\ff\ff\ff\ff",
    expect := ok1 (.nat64 18446744073709551615) },
  { name := "nat64: too short", tys := #[.nat64],
    bytes := blob r"DIDL\00\01\78\00\00\00\00\00\00\00", expect := .fails },
  { name := "nat64: too long", tys := #[.nat64],
    bytes := blob r"DIDL\00\01\78\00\00\00\00\00\00\00\00\00", expect := .fails },
  { name := "int8: -1", tys := #[.int8], bytes := blob r"DIDL\00\01\77\ff",
    expect := ok1 (.int8 (-1)) },
  { name := "int8: 1", tys := #[.int8], bytes := blob r"DIDL\00\01\77\01",
    expect := ok1 (.int8 1) },
  { name := "int8: too long", tys := #[.int8], bytes := blob r"DIDL\00\01\77\00\00",
    expect := .fails },
  { name := "int16: 256", tys := #[.int16], bytes := blob r"DIDL\00\01\76\00\01",
    expect := ok1 (.int16 256) },
  { name := "int16: -1", tys := #[.int16], bytes := blob r"DIDL\00\01\76\ff\ff",
    expect := ok1 (.int16 (-1)) },
  { name := "int16: too short", tys := #[.int16], bytes := blob r"DIDL\00\01\76\00",
    expect := .fails },
  { name := "int32: 65535", tys := #[.int32], bytes := blob r"DIDL\00\01\75\ff\ff\00\00",
    expect := ok1 (.int32 65535) },
  { name := "int32: -1", tys := #[.int32], bytes := blob r"DIDL\00\01\75\ff\ff\ff\ff",
    expect := ok1 (.int32 (-1)) },
  { name := "int32: too short", tys := #[.int32], bytes := blob r"DIDL\00\01\75\00\00",
    expect := .fails },
  { name := "int64: 4294967295", tys := #[.int64],
    bytes := blob r"DIDL\00\01\74\ff\ff\ff\ff\00\00\00\00", expect := ok1 (.int64 4294967295) },
  { name := "int64: -1", tys := #[.int64], bytes := blob r"DIDL\00\01\74\ff\ff\ff\ff\ff\ff\ff\ff",
    expect := ok1 (.int64 (-1)) },
  { name := "int64: too long", tys := #[.int64],
    bytes := blob r"DIDL\00\01\74\00\00\00\00\00\00\00\00\00", expect := .fails },
  { name := "float32: 0", tys := #[.float32], bytes := blob r"DIDL\00\01\73\00\00\00\00",
    expect := ok1 (.float32 0) },
  { name := "float32: 3", tys := #[.float32], bytes := blob r"DIDL\00\01\73\00\00\40\40",
    expect := ok1 (.float32 3) },
  { name := "float32: 0.5", tys := #[.float32], bytes := blob r"DIDL\00\01\73\00\00\00\3f",
    expect := ok1 (.float32 0.5) },
  { name := "float32: -0.5", tys := #[.float32], bytes := blob r"DIDL\00\01\73\00\00\00\bf",
    expect := ok1 (.float32 (-0.5)) },
  { name := "float32: too short", tys := #[.float32], bytes := blob r"DIDL\00\01\73\00\00",
    expect := .fails },
  { name := "float32: too long", tys := #[.float32], bytes := blob r"DIDL\00\01\73\00\00\00\00\00",
    expect := .fails },
  { name := "float64: 0", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\00\00\00\00\00\00\00\00", expect := ok1 (.float64 0) },
  { name := "float64: 3", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\00\00\00\00\00\00\08\40", expect := ok1 (.float64 3) },
  { name := "float64: 0.5", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\00\00\00\00\00\00\e0\3f", expect := ok1 (.float64 0.5) },
  { name := "float64: -0.5", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\00\00\00\00\00\00\e0\bf", expect := ok1 (.float64 (-0.5)) },
  { name := "float64: NaN", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\01\00\00\00\00\00\f0\7f", expect := .ok },
  { name := "float64: max value", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\ff\ff\ff\ff\ff\ff\ef\7f", expect := .ok },
  { name := "float64: too short", tys := #[.float64], bytes := blob r"DIDL\00\01\72\00\00\00\00",
    expect := .fails },
  { name := "float64: too long", tys := #[.float64],
    bytes := blob r"DIDL\00\01\72\00\00\00\00\00\00\00\00\00", expect := .fails },
  { name := "float32 </: float64", tys := #[.float64], bytes := blob r"DIDL\00\01\73\00\00\00\00",
    expect := .fails },
  { name := "text: empty string", tys := #[.text], bytes := blob r"DIDL\00\01\71\00",
    expect := ok1 (.text "") },
  { name := "text: Motoko", tys := #[.text], bytes := blob r"DIDL\00\01\71\06Motoko",
    expect := ok1 (.text "Motoko") },
  { name := "text: too long", tys := #[.text], bytes := blob r"DIDL\00\01\71\05Motoko",
    expect := .fails },
  { name := "text: too short", tys := #[.text], bytes := blob r"DIDL\00\01\71\07Motoko",
    expect := .failsWith "Cannot read 7 bytes" },
  { name := "text: overlong length leb", tys := #[.text],
    bytes := blob r"DIDL\00\01\71\86\00Motoko", expect := ok1 (.text "Motoko") },
  { name := "text: Unicode", tys := #[.text], bytes := blob r"DIDL\00\01\71\03\e2\98\83",
    expect := ok1 (.text "☃") },
  { name := "text: Invalid utf8", tys := #[.text], bytes := blob r"DIDL\00\01\71\03\e2\28\a1",
    expect := .failsAt "invalid utf8" 7 },
  { name := "text: Unicode overshoots", tys := #[.text], bytes := blob r"DIDL\00\01\71\02\e2\98\83",
    expect := .fails },
  { name := "text: Escape sequences", tys := #[.text],
    bytes := blob r"DIDL\00\01\71\06\09\0A\0D\22\27\5C", expect := ok1 (.text "\t\n\r\"'\\") },
  { name := "reserved from null", tys := #[.reserved], bytes := blob r"DIDL\00\01\70",
    expect := .same (blob r"DIDL\00\01\7f") },
  { name := "reserved from bool", tys := #[.reserved], bytes := blob r"DIDL\00\01\70",
    expect := .same (blob r"DIDL\00\01\7e\01") },
  { name := "reserved from nat", tys := #[.reserved], bytes := blob r"DIDL\00\01\70",
    expect := .same (blob r"DIDL\00\01\7d\80\01") },
  { name := "reserved from text", tys := #[.reserved], bytes := blob r"DIDL\00\01\70",
    expect := .same (blob r"DIDL\00\01\71\06Motoko") },
  { name := "reserved extra value", tys := #[.reserved], bytes := blob r"DIDL\00\00",
    expect := ok1 .reserved },
  { name := "reserved from too short text", tys := #[.reserved],
    bytes := blob r"DIDL\00\01\71\05Motoko", expect := .fails },
  { name := "reserved from invalid utf8 text", tys := #[.reserved],
    bytes := blob r"DIDL\00\01\71\03\e2\28\a1", expect := .failsWith "invalid utf8" },
  { name := "cannot decode empty type", tys := #[.empty], bytes := blob r"DIDL\00\01\6f",
    expect := .failsWith "Cannot decode empty type" },
  { name := "okay to decode non-empty value", tys := #[.opt .empty],
    bytes := blob r"DIDL\01\6e\6f\01\00\00", expect := ok1 none' },
  { name := "multiple arguments",
    tys := #[.null, .bool, .nat, .int, .null, .reserved, .null, .nat8, .nat16, .nat32],
    bytes := blob r"DIDL\00\0a\7f\7e\7d\7c\7f\70\7f\7b\7a\79\01\2a\2a\2a\2a\00\2a\00\00\00",
    expect := .values #[.null, .bool true, .nat 42, .int 42, .null, .reserved, .null, .nat8 42,
      .nat16 42, .nat32 42] }
]

/-! ## construct.test.did -/

/-- `record { head : int; tail : tail }`. -/
def headTail (tail : Ty) : Ty := .recordOf #[field "head" .int, field "tail" tail]

/-- The type definitions of construct.test.did. -/
def constructEnv : TypeEnv := { defs := #[
  ("Opt", .opt (.var "Opt")),
  ("Vec", .vec (.var "Vec")),
  ("EmptyRecord", .tuple #[.var "EmptyRecord"]),
  ("OptRec", .opt (.tuple #[.var "OptRec"])),
  ("List", .opt (headTail (.var "List"))),
  ("List1", .opt (.var "List2")),
  ("List2", headTail (.var "List1")),
  ("EmptyVariant", .variantOf #[nfield 0 (.var "EmptyVariant")]),
  ("VariantList", .variantOf #[field "nil" .null, field "cons" (headTail (.var "VariantList"))]),
  ("A1", .recordOf #[field "foo" .int32, field "bar" .bool]),
  ("A2", .recordOf #[field "foo" .int32, field "bar" .bool, field "bat" (.var "VariantList"),
    field "baz" (.var "A1"), field "bbb" (.var "List"),
    field "bib" (.variantOf #[field "foo" .null, field "bar" .null]), field "bab" (.var "A1")])
]}

/-- The `List` of the numbers `xs`: `opt record { head = 1; tail = opt record { … } }`.
`List.foldr f init` combines the elements from the last to the first: `f x₀ (f x₁ … init)`. -/
def list (xs : List Int) : Value :=
  xs.foldr (fun x tail => some' (rec #[(.name "head", .int x), (.name "tail", tail)])) none'

/-- The `VariantList` of the numbers `xs`: `variant { cons = record { head = 1; tail = … } }`,
ending with `variant { nil }`. -/
def variantList (xs : List Int) : Value :=
  xs.foldr
    (fun x tail => .variant (.name "cons") (rec #[(.name "head", .int x), (.name "tail", tail)]))
    (.variant (.name "nil") .null)

/-- A value of `A1`, `record { foo : int32; bar : bool }`. -/
def a1 (foo : Int32) (bar : Bool) : Value :=
  rec #[(.name "foo", .int32 foo), (.name "bar", .bool bar)]

/-- The message of construct.test.did's "skip fields" assertions: an `A2`, whose fields have the
types of `A1`, `VariantList`, `List` and a variant. -/
def skipFields : ByteArray := blob (
  r"DIDL\07\6c\07\c3\e3\aa\02\01\d3\e3\aa\02\7e\d5\e3\aa\02\02\db\e3\aa\02\01\a2\e5\aa\02\04\bb" ++
  r"\f1\aa\02\06\86\8e\b7\02\75\6c\02\d3\e3\aa\02\7e\86\8e\b7\02\75\6b\02\d1\a7\cf\02\7f\f1\f3" ++
  r"\92\8e\04\03\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\02\6e\05\6c\02\a0\d2\ac\a8\04\7c\90\ed" ++
  r"\da\e7\04\04\6b\02\d3\e3\aa\02\7f\86\8e\b7\02\7f\01\00\01\0b\00\00\00\01\00\00\0a\00\00\00" ++
  r"\01\14\00\00\2a\00\00\00")

/-- The message of the `List` of 1 and 2. -/
def listBlob : ByteArray :=
  blob r"DIDL\02\6e\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00\01\01\01\02\00"
/-- The type table and argument types of a message of one `VariantList`, as a blob literal, which
the value's bytes follow. -/
def variantListType : String :=
  r"DIDL\02\6b\02\d1\a7\cf\02\7f\f1\f3\92\8e\04\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00"

/-- The assertions of construct.test.did: the type table, options, vectors, records, variants,
recursive types, skipped fields, `reserved` and future types. `let e := constructEnv` names the
definitions once, for the cases that refer to them. -/
def construct : Array Case :=
  let e := constructEnv
  #[
  -- type table
  { name := "empty table", tys := #[], bytes := blob r"DIDL\00\00", expect := .values #[] },
  { name := "unused type", tys := #[], bytes := blob r"DIDL\01\6e\6f\00", expect := .values #[] },
  { name := "repeated types", tys := #[], bytes := blob r"DIDL\02\6e\6f\6e\6f\00",
    expect := .values #[] },
  { name := "recursive type", tys := #[], bytes := blob r"DIDL\01\6e\00\00",
    expect := .values #[] },
  { name := "type too short", tys := #[], bytes := blob r"DIDL\01\6e\00", expect := .fails },
  { name := "vacuous type", tys := #[], bytes := blob r"DIDL\01\00\00",
    expect := .failsAt "0 is not a valid future type" 5 },
  { name := "vacuous type 2", tys := #[], bytes := blob r"DIDL\02\6e\01\00\00", expect := .fails },
  { name := "table entry out of range", tys := #[], bytes := blob r"DIDL\01\6e\01\00",
    expect := .failsAt "type index 1 out of range" 6 },
  { name := "arg entry out of range", tys := #[], bytes := blob r"DIDL\00\01\00",
    expect := .failsWith "type index 0 out of range" },
  { name := "arg too short", tys := #[], bytes := blob r"DIDL\00\03\7f\7f",
    expect := .failsWith "not enough bytes for 3 arguments" },
  { name := "arg too long", tys := #[], bytes := blob r"DIDL\00\02\7f\7f\7f",
    expect := .failsWith "Trailing value" },
  { name := "non-primitive in arg list", tys := #[], bytes := blob r"DIDL\00\01\6e\7f\00",
    expect := .fails },
  { name := "primitive type in the table", tys := #[], bytes := blob r"DIDL\01\7f\00",
    expect := .failsWith "-1 is not a valid future type" },
  { name := "principal in the table", tys := #[], bytes := blob r"DIDL\01\68\00",
    expect := .failsWith "-24 is not a valid future type" },
  { name := "table entry in the table", tys := #[], bytes := blob r"DIDL\02\6d\7f\00\00",
    expect := .fails },
  { name := "table entry in the table (self-reference)", tys := #[], bytes := blob r"DIDL\01\00\00",
    expect := .fails },
  { name := "table too long", tys := #[], bytes := blob r"DIDL\01\6e\6f\6e\6f\00",
    expect := .fails },
  -- option
  { name := "opt: null", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\7c\01\00\00",
    expect := ok1 none' },
  { name := "opt: type out of range", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\02\01\00\00",
    expect := .fails },
  { name := "opt: 42", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\7c\01\00\01\2a",
    expect := ok1 (some' (.int 42)) },
  { name := "opt: out of range", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\7c\01\00\02\2a",
    expect := .failsAt "Expect 00 or 01" 9 },
  { name := "opt: out of range ff", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\7c\01\00\ff",
    expect := .fails },
  { name := "opt: too short", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\7c\01\00\01",
    expect := .fails },
  { name := "opt: too long", tys := #[.opt .int], bytes := blob r"DIDL\01\6e\7c\01\00\00\2a",
    expect := .fails },
  { name := "opt: nested", tys := #[.opt (.opt .int)],
    bytes := blob r"DIDL\02\6e\01\6e\7c\01\00\01\01\2a", expect := ok1 (some' (some' (.int 42))) },
  { name := "opt: recursion", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\01\6e\00\01\00\01\01\00", expect := ok1 (some' (some' none')) },
  { name := "opt: non-recursive type", tys := #[.opt (.opt (.opt .empty))],
    bytes := blob r"DIDL\01\6e\00\01\00\01\01\00", expect := ok1 (some' (some' none')) },
  { name := "opt: mutual recursion", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\02\6e\01\6e\00\01\00\01\01\00", expect := ok1 (some' (some' none')) },
  { name := "opt: extra arg", env := e, tys := #[.var "Opt"], bytes := blob r"DIDL\00\00",
    expect := ok1 none' },
  -- vector
  { name := "vec: empty", tys := #[.vec .int], bytes := blob r"DIDL\01\6d\7c\01\00\00",
    expect := ok1 (.vec #[]) },
  { name := "vec: non subtype empty", tys := #[.vec .int8], bytes := blob r"DIDL\01\6d\7c\01\00\00",
    expect := ok1 (.vec #[]) },
  { name := "vec", tys := #[.vec .int], bytes := blob r"DIDL\01\6d\7c\01\00\02\01\02",
    expect := ok1 (.vec #[.int 1, .int 2]) },
  { name := "vec: blob", tys := #[.vec .nat8], bytes := blob r"DIDL\01\6d\7b\01\00\02\01\02",
    expect := ok1 (.blob (bytes [1, 2])) },
  { name := "vec: empty blob from vec int", tys := #[.vec .nat8],
    bytes := blob r"DIDL\01\6d\7c\01\00\00", expect := ok1 (.blob .empty) },
  { name := "vec: nonempty blob from vec int", tys := #[.vec .nat8],
    bytes := blob r"DIDL\01\6d\7c\01\00\01\01", expect := .fails },
  { name := "vec: recursive vector", env := e, tys := #[.var "Vec"],
    bytes := blob r"DIDL\01\6d\00\01\00\00", expect := ok1 (.vec #[]) },
  { name := "vec: tree", env := e, tys := #[.var "Vec"],
    bytes := blob r"DIDL\01\6d\00\01\00\02\00\00", expect := ok1 (.vec #[.vec #[], .vec #[]]) },
  { name := "vec: non-recursive tree", tys := #[.vec (.vec (.opt .empty))],
    bytes := blob r"DIDL\01\6d\00\01\00\02\00\00", expect := ok1 (.vec #[.vec #[], .vec #[]]) },
  { name := "vec null", tys := #[.vec .null], bytes := blob r"DIDL\01\6d\7f\01\00\e8\07",
    expect := ok1 (.vec (Array.replicate 1000 .null)) },
  { name := "vec null <: vec opt nat", tys := #[.vec (.opt .nat)],
    bytes := blob r"DIDL\01\6d\7f\01\00\e8\07", expect := ok1 (.vec (Array.replicate 1000 none')) },
  { name := "vec: too short", tys := #[.vec .int], bytes := blob r"DIDL\01\6d\7c\01\00",
    expect := .fails },
  { name := "vec: too short 2", tys := #[.vec .int], bytes := blob r"DIDL\01\6d\7c\01\00\02\01",
    expect := .failsWith "not enough bytes for 2 vector elements" },
  { name := "vec: too long", tys := #[.vec .int], bytes := blob r"DIDL\01\6d\7c\01\00\01\01\02",
    expect := .fails },
  { name := "vec of records", tys := #[.vec (.record #[])],
    bytes := blob r"DIDL\02\6d\01\6c\00\01\00\05",
    expect := ok1 (.vec (Array.replicate 5 (.record #[]))) },
  -- record
  { name := "record: empty", tys := #[.record #[]], bytes := blob r"DIDL\01\6c\00\01\00",
    expect := ok1 (.record #[]) },
  { name := "record: multiple records", tys := #[.record #[], .record #[], .record #[]],
    bytes := blob r"DIDL\01\6c\00\03\00\00\00",
    expect := .values #[.record #[], .record #[], .record #[]] },
  { name := "record", tys := #[.record #[nfield 1 .int]],
    bytes := blob r"DIDL\01\6c\01\01\7c\01\00\2a", expect := ok1 (.record #[(.num 1, .int 42)]) },
  { name := "record: opt", tys := #[.record #[nfield 1 (.opt .int)]],
    bytes := blob r"DIDL\01\6c\01\01\7c\01\00\2a",
    expect := ok1 (.record #[(.num 1, some' (.int 42))]) },
  { name := "record: reserved", tys := #[.record #[nfield 1 .reserved]],
    bytes := blob r"DIDL\01\6c\01\01\7c\01\00\2a", expect := ok1 (.record #[(.num 1, .reserved)]) },
  { name := "record: ignore fields", tys := #[.record #[]],
    bytes := blob r"DIDL\01\6c\01\01\7c\01\00\2a", expect := ok1 (.record #[]) },
  { name := "record: missing field", tys := #[.record #[nfield 2 .int]],
    bytes := blob r"DIDL\01\6c\01\01\7c\01\00\2a",
    expect := .failsWith "field 2 is not optional field" },
  { name := "record: missing opt field", tys := #[.record #[nfield 2 (.opt .int)]],
    bytes := blob r"DIDL\01\6c\01\01\7c\01\00\2a", expect := ok1 (.record #[(.num 2, none')]) },
  { name := "record: missing null field", tys := #[.record #[nfield 2 .null]],
    bytes := blob r"DIDL\01\6c\00\01\00", expect := ok1 (.record #[(.num 2, .null)]) },
  { name := "record: tuple", tys := #[.tuple #[.int, .bool]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\7e\01\00\2a\01",
    expect := ok1 (.record #[(.num 0, .int 42), (.num 1, .bool true)]) },
  { name := "record: ignore fields 2", tys := #[.record #[nfield 1 .bool]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\7e\01\00\2a\01",
    expect := ok1 (.record #[(.num 1, .bool true)]) },
  { name := "record: type mismatch", tys := #[.tuple #[.bool, .int]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\7e\01\00\2a\01", expect := .fails },
  { name := "record: duplicate fields", tys := #[.tuple #[.int, .bool]],
    bytes := blob r"DIDL\01\6c\02\00\7c\00\7e\01\00\2a\01",
    expect := .failsAt "field id 0 collision or not sorted" 9 },
  { name := "record: unsorted", tys := #[.record #[nfield 0 .bool, nfield 1 .int]],
    bytes := blob r"DIDL\01\6c\02\01\7c\00\7e\01\00\2a\01",
    expect := .failsWith "collision or not sorted" },
  { name := "record: named fields", tys := #[.recordOf #[field "foo" .int, field "bar" .bool]],
    bytes := blob r"DIDL\01\6c\02\d3\e3\aa\02\7e\86\8e\b7\02\7c\01\00\01\2a",
    expect := ok1 (rec #[(.name "foo", .int 42), (.name "bar", .bool true)]) },
  { name := "record: unicode field", tys := #[.recordOf #[field "☃" .null]],
    bytes := blob r"DIDL\01\6c\01\cd\84\b0\05\7f\01\00",
    expect := ok1 (rec #[(.name "☃", .null)]) },
  { name := "record: field hash larger than u32", tys := #[.record #[]],
    bytes := blob r"DIDL\01\6c\01\80\e4\97\d0\12\7c\01\00\2a",
    expect := .failsWith "field id out of 32-bit range" },
  { name := "record: nested", tys := #[.tuple #[.tuple #[.tuple #[.record #[]]]]],
    bytes := blob r"DIDL\04\6c\01\00\01\6c\01\00\02\6c\01\00\03\6c\00\01\00",
    expect := ok1 (.record #[(.num 0, .record #[(.num 0, .record #[(.num 0, .record #[])])])]) },
  { name := "record: empty recursion", env := e, tys := #[.var "EmptyRecord"],
    bytes := blob r"DIDL\01\6c\01\00\00\01\00", expect := .failsWith "Recursion limit exceeded" },
  { name := "vec of empty records", env := e, tys := #[.vec (.var "EmptyRecord")],
    bytes := blob r"DIDL\02\6d\01\6c\01\00\01\01\00\01", expect := .fails },
  { name := "record: value too short", tys := #[.tuple #[.int]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\7e\01\00\2a", expect := .fails },
  { name := "record: value too long", tys := #[.tuple #[.int]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\7e\01\00\2a\01\00", expect := .fails },
  { name := "record: type too short", tys := #[.record #[]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\01\00\2a\01", expect := .fails },
  { name := "record: type too short 2", tys := #[.record #[]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\00\2a\01", expect := .fails },
  { name := "record: type too long", tys := #[.record #[]],
    bytes := blob r"DIDL\01\6c\02\00\7c\01\7e\02\7e\01\00\2a\01\00", expect := .fails },
  { name := "record: type out of range", tys := #[.record #[]],
    bytes := blob r"DIDL\01\6c\02\00\01\01\7e\01\00\00\00", expect := .fails },
  { name := "record: type out of range at reserved", tys := #[.reserved],
    bytes := blob r"DIDL\01\6c\02\00\01\01\7e\01\7c\2a", expect := .fails },
  -- opt
  { name := "opt: parsing null : null", tys := #[.opt .empty], bytes := blob r"DIDL\00\01\7f",
    expect := ok1 none' },
  { name := "opt: parsing null : opt empty", tys := #[.opt .empty],
    bytes := blob r"DIDL\01\6e\6f\01\00\00", expect := ok1 none' },
  { name := "opt: parsing null : opt bool", tys := #[.opt .bool],
    bytes := blob r"DIDL\01\6e\7e\01\00\00", expect := ok1 none' },
  { name := "opt: parsing opt false : opt bool", tys := #[.opt .bool],
    bytes := blob r"DIDL\01\6e\7e\01\00\01\00", expect := ok1 (some' (.bool false)) },
  { name := "opt: parsing opt true : opt bool", tys := #[.opt .bool],
    bytes := blob r"DIDL\01\6e\7e\01\00\01\01", expect := ok1 (some' (.bool true)) },
  { name := "opt: parsing invalid bool at opt bool", tys := #[.opt .bool],
    bytes := blob r"DIDL\01\6e\7e\01\00\01\02", expect := .failsWith "Expect 00 or 01" },
  { name := "opt: extra value", tys := #[.opt .bool], bytes := blob r"DIDL\00\00",
    expect := ok1 none' },
  -- nested opt
  { name := "opt: parsing null : opt opt bool", tys := #[.opt (.opt .bool)],
    bytes := blob r"DIDL\02\6e\01\6e\7e\01\00\00", expect := ok1 none' },
  { name := "opt: parsing opt null : opt opt bool", tys := #[.opt (.opt .bool)],
    bytes := blob r"DIDL\02\6e\01\6e\7e\01\00\01\00", expect := ok1 (some' none') },
  { name := "opt: parsing opt opt false : opt opt bool", tys := #[.opt (.opt .bool)],
    bytes := blob r"DIDL\02\6e\01\6e\7e\01\00\01\01\00",
    expect := ok1 (some' (some' (.bool false))) },
  -- opt subtype to constituent
  { name := "opt: parsing false : opt bool", tys := #[.opt .bool],
    bytes := blob r"DIDL\00\01\7e\00", expect := ok1 (some' (.bool false)) },
  { name := "opt: parsing true : opt bool", tys := #[.opt .bool], bytes := blob r"DIDL\00\01\7e\01",
    expect := ok1 (some' (.bool true)) },
  { name := "opt: parsing invalid bool at opt bool 2", tys := #[.opt .bool],
    bytes := blob r"DIDL\00\01\7e\02", expect := .fails },
  { name := "opt: (null : opt null) at opt opt null", tys := #[.opt (.opt .null)],
    bytes := blob r"DIDL\01\6e\7f\01\00\00", expect := ok1 none' },
  { name := "opt: parsing true : opt opt bool", tys := #[.opt (.opt .bool)],
    bytes := blob r"DIDL\00\01\7e\01", expect := ok1 (some' (some' (.bool true))) },
  { name := "opt: parsing (true : bool) at fix opt fails", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\00\01\7e\01",
    expect := .failsWith "Recursion limit exceeded at depth 512" },
  { name := "opt: parsing null : Opt", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\01\6e\00\01\00\00", expect := ok1 none' },
  { name := "opt: parsing opt null : Opt", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\01\6e\00\01\00\01\00", expect := ok1 (some' none') },
  { name := "opt: parsing opt opt null : Opt", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\01\6e\00\01\00\01\01\00", expect := ok1 (some' (some' none')) },
  { name := "opt: parsing opt opt opt null : Opt", env := e, tys := #[.var "Opt"],
    bytes := blob r"DIDL\01\6e\00\01\00\01\01\01\00", expect := ok1 (some' (some' (some' none'))) },
  { name := "opt: parsing fix record at fix record opt fails", env := e, tys := #[.var "OptRec"],
    bytes := blob r"DIDL\01\6c\01\00\00\01\00", expect := .failsWith "Recursion limit exceeded" },
  -- special opt subtyping
  { name := "reserved <: opt nat", tys := #[.opt .nat], bytes := blob r"DIDL\00\01\70",
    expect := ok1 none' },
  { name := "null : opt bool <: opt nat", tys := #[.opt .nat],
    bytes := blob r"DIDL\01\6e\7e\01\00\00", expect := ok1 none' },
  { name := "opt true : opt bool <: opt nat", tys := #[.opt .nat],
    bytes := blob r"DIDL\01\6e\7e\01\00\01\01", expect := ok1 none' },
  { name := "opt bool <: opt nat with invalid boolean value", tys := #[.opt .nat],
    bytes := blob r"DIDL\01\6e\7e\01\00\01\02", expect := .failsWith "Expect 00 or 01" },
  { name := "opt opt true : opt opt bool <: opt nat", tys := #[.opt .nat],
    bytes := blob r"DIDL\02\6e\01\6e\7e\01\00\01\01\01", expect := ok1 none' },
  { name := "opt opt true : opt opt bool <: opt opt nat", tys := #[.opt (.opt .nat)],
    bytes := blob r"DIDL\02\6e\01\6e\7e\01\00\01\01\01", expect := ok1 (some' none') },
  { name := "opt: recovered coercion error under variant",
    tys := #[.opt (.variant #[nfield 0 .int])],
    bytes := blob r"DIDL\02\6e\01\6b\01\00\7e\01\00\01\00\01", expect := ok1 none' },
  -- special record field rules
  { name := "missing optional field", tys := #[.recordOf #[field "foo" (.opt .bool)]],
    bytes := blob r"DIDL\01\6c\00\01\00", expect := ok1 (rec #[(.name "foo", none')]) },
  { name := "missing reserved field", tys := #[.recordOf #[field "foo" .reserved]],
    bytes := blob r"DIDL\01\6c\00\01\00", expect := ok1 (rec #[(.name "foo", .reserved)]) },
  -- variant
  { name := "variant: no empty value", tys := #[.variant #[]], bytes := blob r"DIDL\01\6b\00\01\00",
    expect := .fails },
  { name := "variant: numbered field", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\00", expect := ok1 (.variant (.num 0) .null) },
  { name := "variant: type mismatch", tys := #[.variant #[nfield 0 .int]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\00\2a", expect := .fails },
  { name := "variant: type mismatch in unused tag",
    tys := #[.variant #[nfield 0 .int, nfield 1 .int]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7c\01\00\01\2a",
    expect := ok1 (.variant (.num 1) (.int 42)) },
  { name := "variant: ignore field", tys := #[.variant #[nfield 0 .null, nfield 1 .null]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\00", expect := ok1 (.variant (.num 0) .null) },
  { name := "variant {0;1} <: variant {0}", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7f\01\00\00", expect := ok1 (.variant (.num 0) .null) },
  { name := "variant {0;1} <: opt variant {0}", tys := #[.opt (.variant #[nfield 0 .null])],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7f\01\00\00",
    expect := ok1 (some' (.variant (.num 0) .null)) },
  { name := "variant: change index",
    tys := #[.variant #[nfield 0 .null, nfield 1 .null, nfield 2 .null]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7f\01\00\01", expect := ok1 (.variant (.num 1) .null) },
  { name := "variant: missing field", tys := #[.variant #[nfield 1 .null]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\00", expect := .failsWith "Unknown variant field 0" },
  { name := "variant: unknown field under opt", tys := #[.opt (.variant #[nfield 1 .null])],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\00", expect := ok1 none' },
  { name := "variant: index out of range", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\01",
    expect := .failsAt "Variant index 1 larger than length 1" 11 },
  { name := "variant: index out of range under opt", tys := #[.opt (.variant #[nfield 0 .null])],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\01",
    expect := .failsWith "Variant index 1 larger than length 1" },
  { name := "variant: duplicate fields", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\02\00\7f\00\7f\01\00\00", expect := .fails },
  { name := "variant: duplicate fields 3", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\03\00\7f\01\7f\01\7f\01\00\00", expect := .fails },
  { name := "variant: unsorted", tys := #[.variant #[nfield 0 .null, nfield 1 .null]],
    bytes := blob r"DIDL\01\6b\02\01\7f\00\7f\01\00\00", expect := .fails },
  { name := "variant: ok with maxInt",
    tys := #[.variant #[nfield 0 .null, nfield 1 .null, nfield 4294967295 .null]],
    bytes := blob r"DIDL\01\6b\03\00\7f\01\7f\ff\ff\ff\ff\0f\7f\01\00\00",
    expect := ok1 (.variant (.num 0) .null) },
  { name := "variant: unsorted with maxInt",
    tys := #[.variant #[nfield 0 .null, nfield 1 .null, nfield 4294967295 .null]],
    bytes := blob r"DIDL\01\6b\03\00\7f\ff\ff\ff\ff\0f\7f\01\7f\01\00\00", expect := .fails },
  { name := "variant: enum", tys := #[.variantOf #[field "Foo" .null, field "Bar" .null]],
    bytes := blob r"DIDL\01\6b\02\b3\d3\c9\01\7f\e6\fd\d5\01\7f\01\00\00",
    expect := ok1 (.variant (.name "Bar") .null) },
  { name := "variant: unicode field", tys := #[.variantOf #[field "☃" .null]],
    bytes := blob r"DIDL\01\6b\01\cd\84\b0\05\7f\01\00\00",
    expect := ok1 (.variant (.name "☃") .null) },
  { name := "variant: result", tys := #[.variantOf #[field "Ok" .text, field "Err" .text]],
    bytes := blob r"DIDL\01\6b\02\bc\8a\01\71\c5\fe\d2\01\71\01\00\00\04\67\6f\6f\64",
    expect := ok1 (.variant (.name "Ok") (.text "good")) },
  { name := "variant: with empty", tys := #[.variantOf #[field "ok" .text, field "err" .empty]],
    bytes := blob r"DIDL\01\6b\02\9c\c2\01\71\e5\8e\b4\02\6f\01\00\00\04\67\6f\6f\64",
    expect := ok1 (.variant (.name "ok") (.text "good")) },
  { name := "variant: with EmptyRecord", env := e,
    tys := #[.variantOf #[field "ok" .text, field "err" (.var "EmptyRecord")]],
    bytes := blob r"DIDL\02\6b\02\9c\c2\01\71\e5\8e\b4\02\01\6c\01\00\01\01\00\00\04\67\6f\6f\64",
    expect := ok1 (.variant (.name "ok") (.text "good")) },
  { name := "variant",
    tys := #[.variantOf #[field "Foo" .null, field "Bar" (.tuple #[.bool, .int]),
      field "Baz" (.recordOf #[field "a" .int, field "b" .nat])]],
    bytes := blob (r"DIDL\03\6b\03\b3\d3\c9\01\01\bb\d3\c9\01\02\e6\fd\d5\01\7f\6c\02\00\7e\01" ++
      r"\7c\6c\02\61\7c\62\7d\01\00\00\01\2a"),
    expect := ok1 (.variant (.name "Bar") (.record #[(.num 0, .bool true), (.num 1, .int 42)])) },
  { name := "variant: empty recursion", env := e, tys := #[.var "EmptyVariant"],
    bytes := blob r"DIDL\01\6b\01\00\00\01\00\00\00\00\00\00\00\00\00\00\00\00\00",
    expect := .fails },
  { name := "variant: field hash larger than u32", tys := #[.reserved],
    bytes := blob r"DIDL\01\6b\01\80\e4\97\d0\12\7c\01\00\00\2a", expect := .fails },
  { name := "variant 2", tys := #[.variant #[nfield 0 .null, nfield 1 .int]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7c\01\00\01\2a",
    expect := ok1 (.variant (.num 1) (.int 42)) },
  { name := "variant: value too short", tys := #[.variant #[nfield 0 .null, nfield 1 .int]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7c\01\00\01", expect := .fails },
  { name := "variant: value too long", tys := #[.variant #[nfield 0 .null, nfield 1 .int]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\7c\01\00\01\2a\00", expect := .fails },
  { name := "variant: type out of range", tys := #[.variant #[nfield 0 .reserved, nfield 1 .int]],
    bytes := blob r"DIDL\01\6b\02\00\01\01\7c\01\00\01\2a", expect := .fails },
  { name := "variant: type too short", tys := #[.variant #[nfield 0 .null, nfield 1 .null]],
    bytes := blob r"DIDL\01\6b\02\00\7f\01\00\00", expect := .fails },
  { name := "variant: type too long", tys := #[.variant #[nfield 0 .null, nfield 1 .null]],
    bytes := blob r"DIDL\01\6b\03\00\7f\01\7f\01\00\00", expect := .fails },
  -- list
  { name := "record: empty list", env := e, tys := #[.var "List"],
    bytes := blob r"DIDL\02\6e\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00\00",
    expect := ok1 (list []) },
  { name := "record: list", env := e, tys := #[.var "List"],
    bytes := blob (r"DIDL\02\6e\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00\01\01\01\02" ++
      r"\01\03\01\04\00"),
    expect := ok1 (list [1, 2, 3, 4]) },
  { name := "record: reorder type table", env := e, tys := #[.var "List"], bytes := listBlob,
    expect := .same (blob (r"DIDL\02\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\01\6e\00\01\01\01\01" ++
      r"\01\02\00")) },
  { name := "record: reorder type table (values)", env := e, tys := #[.var "List"],
    bytes := blob r"DIDL\02\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\01\6e\00\01\01\01\01\01\02\00",
    expect := ok1 (list [1, 2]) },
  { name := "record: mutual recursive list", env := e, tys := #[.var "List1"], bytes := listBlob,
    expect := ok1 (list [1, 2]) },
  { name := "variant: empty list", env := e, tys := #[.var "VariantList"],
    bytes := blob (variantListType ++ r"\00"), expect := ok1 (variantList []) },
  { name := "variant: list", env := e, tys := #[.var "VariantList"],
    bytes := blob (variantListType ++ r"\01\01\01\02\00"), expect := ok1 (variantList [1, 2]) },
  { name := "variant: extra args", env := e,
    tys := #[.var "VariantList", .opt (.var "VariantList"), .null, .reserved, .opt .int],
    bytes := blob (variantListType ++ r"\00"),
    expect := .values #[variantList [], none', .null, .reserved, none'] },
  { name := "non-null extra args", env := e, tys := #[.var "VariantList", .opt .int, .vec .int],
    bytes := blob (variantListType ++ r"\00"),
    expect := .failsWith "No more values on the wire, the expected type vec int" },
  -- skip fields
  { name := "skip fields: A2", env := e, tys := #[.var "A2"], bytes := skipFields,
    expect := ok1 (rec #[(.name "foo", .int32 42), (.name "bar", .bool true),
      (.name "bat", variantList []), (.name "baz", a1 10 false), (.name "bbb", list [20]),
      (.name "bib", .variant (.name "bar") .null), (.name "bab", a1 11 true)]) },
  { name := "skip fields: A1", env := e, tys := #[.var "A1"], bytes := skipFields,
    expect := ok1 (a1 42 true) },
  { name := "skip fields: some", env := e,
    tys := #[.recordOf #[field "bar" .bool, field "baz" (.recordOf #[field "bar" .bool]),
      field "bbb" (.opt (.recordOf #[field "head" .int]))]],
    bytes := skipFields,
    expect := ok1 (rec #[(.name "bar", .bool true),
      (.name "baz", rec #[(.name "bar", .bool false)]),
      (.name "bbb", some' (rec #[(.name "head", .int 20)]))]) },
  { name := "new variant field", env := e,
    tys := #[.recordOf #[field "bat" (.variantOf #[field "nil" .null,
      field "cons" (headTail (.var "VariantList")), field "new_field" .empty])]],
    bytes := skipFields, expect := ok1 (rec #[(.name "bat", variantList [])]) },
  { name := "new record field", env := e,
    tys := #[.recordOf #[field "foo" .int, field "new_field" .bool]], bytes := skipFields,
    expect := .fails },
  -- parsing reserved as null
  { name := "reserved", tys := #[.reserved], bytes := blob r"DIDL\00\01\70",
    expect := ok1 .reserved },
  { name := "parsing reserved as null", tys := #[.null], bytes := blob r"DIDL\00\01\70",
    expect := .fails },
  { name := "parsing (reserved, reserved) as (null, null)", tys := #[.null, .null],
    bytes := blob r"DIDL\00\02\70\70", expect := .fails },
  { name := "parsing (reserved, 5) as (null, nat)", tys := #[.null, .nat],
    bytes := blob r"DIDL\00\02\70\7D\05", expect := .fails },
  { name := "record with reserved field", tys := #[.record #[nfield 0 .reserved]],
    bytes := blob r"DIDL\01\6c\01\00\70\01\00", expect := ok1 (.record #[(.num 0, .reserved)]) },
  { name := "record with reserved field as null field", tys := #[.record #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6c\01\00\70\01\00", expect := .fails },
  { name := "variant with reserved field", tys := #[.variant #[nfield 0 .reserved]],
    bytes := blob r"DIDL\01\6b\01\00\70\01\00\00", expect := ok1 (.variant (.num 0) .reserved) },
  { name := "variant with reserved field as null field", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\01\00\70\01\00\00", expect := .fails },
  { name := "vector with reserved elements", tys := #[.vec .reserved],
    bytes := blob r"DIDL\01\6d\70\01\00\01", expect := ok1 (.vec #[.reserved]) },
  { name := "vector with reserved elements as null elements", tys := #[.vec .null],
    bytes := blob r"DIDL\01\6d\70\01\00\01", expect := .fails },
  { name := "optional reserved element", tys := #[.opt .reserved],
    bytes := blob r"DIDL\01\6e\70\01\00\01", expect := ok1 (some' .reserved) },
  { name := "optional reserved element as optional null", tys := #[.opt .null],
    bytes := blob r"DIDL\01\6e\70\01\00\01", expect := ok1 none' },
  { name := "parsing 5 as null", tys := #[.null], bytes := blob r"DIDL\00\01\7D\05",
    expect := .fails },
  -- missing data
  { name := "empty top-level tuple into a longer one", tys := #[.null], bytes := blob r"DIDL\00\00",
    expect := ok1 .null },
  { name := "top-level tuple into a longer one", tys := #[.nat, .nat, .null],
    bytes := blob r"DIDL\00\02\7d\7d\05\06", expect := .values #[.nat 5, .nat 6, .null] },
  { name := "expected field greater than extra wire field", tys := #[.record #[nfield 1 .null]],
    bytes := blob r"DIDL\01\6c\01\00\7d\01\00\05", expect := ok1 (.record #[(.num 1, .null)]) },
  { name := "expected field less than extra wire field", tys := #[.record #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6c\01\01\7d\01\00\05", expect := ok1 (.record #[(.num 0, .null)]) },
  -- future types
  { name := "skipping minimal future type", tys := #[.opt .empty, .bool],
    bytes := blob r"DIDL\01\67\00\02\00\7e\00\00\01", expect := .values #[none', .bool true] },
  { name := "skipping future type with data", tys := #[.opt .empty, .bool],
    bytes := blob r"DIDL\01\67\03ABC\02\00\7e\05\00hello\01",
    expect := .values #[none', .bool true] },
  { name := "future type at reserved", tys := #[.reserved, .bool],
    bytes := blob r"DIDL\01\67\03ABC\02\00\7e\05\00hello\01",
    expect := .values #[.reserved, .bool true] },
  { name := "future type as an extra argument", tys := #[],
    bytes := blob r"DIDL\01\67\03ABC\02\00\7e\05\00hello\01", expect := .values #[] },
  { name := "future type at nat", tys := #[.nat, .bool],
    bytes := blob r"DIDL\01\67\03ABC\02\00\7e\05\00hello\01",
    expect := .failsWith "future cannot be deserialized to nat" }
]

/-! ## reference.test.did -/

/-- A method of a service type. -/
def method (name : String) (t : Ty) : Method := ⟨name, t⟩

/-- `service { foo : (text) -> (nat) }`. -/
def fooService : Ty := .serviceOf #[method "foo" (func0 #[.text] #[.nat])]

/-- `service { foo : (text) -> (nat); foo2 : (text) -> (nat) }`. -/
def foo2Service : Ty :=
  .serviceOf #[method "foo" (func0 #[.text] #[.nat]), method "foo2" (func0 #[.text] #[.nat])]

/-- The assertions of reference.test.did: principals, services and functions, whose types must
be subtypes of the expected ones. -/
def reference : Array Case := #[
  -- principal
  { name := "principal: ic0", tys := #[.principal], bytes := blob r"DIDL\00\01\68\01\00",
    expect := ok1 (.principal ⟨.empty⟩) },
  { name := "principal", tys := #[.principal], bytes := blob r"DIDL\00\01\68\01\03\ca\ff\ee",
    expect := ok1 (.principal caffee) },
  { name := "principal 9 bytes", tys := #[.principal],
    bytes := blob r"DIDL\00\01\68\01\09\ef\cd\ab\00\00\00\00\00\01",
    expect := ok1 (.principal (principal [0xef, 0xcd, 0xab, 0, 0, 0, 0, 0, 1])) },
  { name := "principal: different", tys := #[.principal],
    bytes := blob r"DIDL\00\01\68\01\02\ca\ff",
    expect := .differs (blob r"DIDL\00\01\68\01\03\ca\ff\ee") },
  { name := "principal: no tag", tys := #[.principal], bytes := blob r"DIDL\00\01\68\03\ca\ff\ee",
    expect := .fails },
  { name := "principal: opaque", tys := #[.principal], bytes := blob r"DIDL\00\01\68\00",
    expect := .failsWith "Opaque reference not supported" },
  { name := "principal: too short", tys := #[.principal],
    bytes := blob r"DIDL\00\01\68\01\03\ca\ff", expect := .fails },
  { name := "principal: too long", tys := #[.principal],
    bytes := blob r"DIDL\00\01\68\01\03\ca\ff\ee\ee", expect := .fails },
  { name := "principal: not construct", tys := #[.principal],
    bytes := blob r"DIDL\01\68\01\00\01\03\ca\ff\ee", expect := .fails },
  { name := "principal: 30 bytes", tys := #[.principal],
    bytes := blob (r"DIDL\00\01\68\01\1e" ++ String.join (List.replicate 30 r"\00")),
    expect := .failsWith "Principal is longer than 29 bytes" },
  -- service
  { name := "service: not principal", tys := #[.service #[]],
    bytes := blob r"DIDL\00\01\68\01\03\ca\ff\ee", expect := .fails },
  { name := "service: not primitive type", tys := #[.service #[]],
    bytes := blob r"DIDL\00\01\69\01\03\ca\ff\ee", expect := .fails },
  { name := "service", tys := #[.service #[]], bytes := blob r"DIDL\01\69\00\01\00\01\03\ca\ff\ee",
    expect := ok1 (.service caffee) },
  { name := "service foo", tys := #[fooService],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    expect := ok1 (.service caffee) },
  { name := "service foo foo2", tys := #[foo2Service],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\02\03foo\00\04foo\32\00\01\01\01\03\ca\ff\ee",
    expect := ok1 (.service caffee) },
  { name := "service {} value decodes at principal", tys := #[.principal],
    bytes := blob r"DIDL\01\69\00\01\00\01\03\ca\ff\ee", expect := ok1 (.principal caffee) },
  { name := "service {foo} value decodes at principal", tys := #[.principal],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    expect := ok1 (.principal caffee) },
  { name := "principal: reject empty (bottom) wire type", tys := #[.principal],
    bytes := blob r"DIDL\00\01\6f\01\03\ca\ff\ee",
    expect := .failsWith "empty cannot be deserialized to principal" },
  { name := "recursive service value decodes at principal", tys := #[.principal],
    bytes := blob r"DIDL\02\69\01\01m\01\6a\00\01\01\00\01\00\01\03\ca\ff\ee",
    expect := ok1 (.principal caffee) },
  { name := "principal: reject func wire type", tys := #[.principal],
    bytes := blob r"DIDL\01\6a\00\00\00\01\00\01\01\03\ca\ff\ee\01\61", expect := .fails },
  { name := "principal: reject record wire type", tys := #[.principal],
    bytes := blob r"DIDL\01\6c\00\01\00", expect := .fails },
  { name := "principal: reject opt wire type", tys := #[.principal],
    bytes := blob r"DIDL\01\6e\7d\01\00\00", expect := .fails },
  { name := "service: too long", tys := #[foo2Service],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\03\03foo\00\04foo\32\00\01\01\01\03\ca\ff\ee",
    expect := .fails },
  { name := "service: too short", tys := #[foo2Service],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\00\04foo\32\00\01\01\01\03\ca\ff\ee",
    expect := .fails },
  { name := "service: unsorted", tys := #[foo2Service],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\02\04foo\32\00\03foo\00\01\01\01\03\ca\ff\ee",
    expect := .failsWith "method name \"foo\" duplicate or not sorted" },
  { name := "service: unsorted (but sorted by hash)",
    tys := #[.serviceOf #[method "foobar" (func0 #[.text] #[.nat]),
      method "foobarbaz" (func0 #[.text] #[.nat])]],
    bytes := blob (r"DIDL\02\6a\01\71\01\7d\00\69\02\09foobarbaz\00\06foobar\00\01\01\01\03\ca" ++
      r"\ff\ee"),
    expect := .fails },
  { name := "service: invalid unicode", tys := #[.reserved],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03\e2\28\a1\00\01\01\01\03\ca\ff\ee",
    expect := .failsWith "invalid utf8" },
  { name := "service: duplicate", tys := #[fooService],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\02\03foo\00\03foo\00\01\01\01\03\ca\ff\ee",
    expect := .fails },
  { name := "service: unicode",
    tys := #[.serviceOf #[method "🐂" (func0 #[.opt .int] #[.record #[]] #[.query]),
      method "foo" (func0 #[] #[] #[.oneway])]],
    bytes := blob (r"DIDL\05i\02\03foo\01\04\f0\9f\90\82\02j\00\00\01\02j\01\03\01\04\01\01n|l" ++
      r"\00\01\00\01\00"),
    expect := ok1 (.service ⟨.empty⟩) },
  { name := "service { foo: principal }", tys := #[.serviceOf #[method "foo" (func0 #[] #[])]],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\68\01\01\01\03\ca\ff\ee",
    expect := .failsWith "Method foo has a non-function type principal" },
  { name := "service { foo: opt bool }", tys := #[.serviceOf #[method "foo" (func0 #[] #[])]],
    bytes := blob r"DIDL\02\6e\7e\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    expect := .failsWith "has a non-function type" },
  { name := "service { foo: opt bool } 2", tys := #[.serviceOf #[method "foo" (func0 #[] #[])]],
    bytes := blob r"DIDL\02\69\01\03foo\01\6e\7e\01\01\01\03\ca\ff\ee", expect := .fails },
  -- function
  { name := "func: quote name", tys := #[func0 #[] #[]],
    bytes := blob r"DIDL\01\6a\00\00\00\01\00\01\01\03\ca\ff\ee\01\61",
    expect := ok1 (.func caffee "a") },
  { name := "func: wrong tag", tys := #[func0 #[] #[]],
    bytes := blob r"DIDL\01\6a\00\00\00\01\00\01\00\03\ca\ff\ee\01\61", expect := .fails },
  { name := "func: opaque", tys := #[func0 #[] #[]], bytes := blob r"DIDL\01\6a\00\00\00\01\00\00",
    expect := .failsWith "Opaque reference not supported" },
  { name := "func: unicode", tys := #[func0 #[.int, .nat] #[.service #[]] #[.query]],
    bytes := blob r"DIDL\02j\02|}\01\01\01\01i\00\01\00\01\01\00\04\f0\9f\90\82",
    expect := ok1 (.func ⟨.empty⟩ "🐂") },
  { name := "func", tys := #[func0 #[.principal] #[.nat]],
    bytes := blob r"DIDL\01\6a\01\68\01\7d\00\01\00\01\01\03\ca\ff\ee\03foo",
    expect := ok1 (.func caffee "foo") },
  { name := "func: query", tys := #[func0 #[.text] #[.nat] #[.query]],
    bytes := blob r"DIDL\01\6a\01\71\01\7d\01\01\01\00\01\01\03\ca\ff\ee\03foo",
    expect := ok1 (.func caffee "foo") },
  { name := "func: composite query", tys := #[func0 #[.text] #[.nat] #[.compositeQuery]],
    bytes := blob r"DIDL\01\6a\01\71\01\7d\01\03\01\00\01\01\03\ca\ff\ee\03foo",
    expect := ok1 (.func caffee "foo") },
  { name := "func: unknown annotation", tys := #[func0 #[.text] #[.nat] #[.query]],
    bytes := blob r"DIDL\01\6a\01\71\01\7d\01\80\01\01\00\01\01\03\ca\ff\ee\03foo",
    expect := .failsWith "Unknown annotation" },
  { name := "func: two annotations", tys := #[func0 #[] #[] #[.query]],
    bytes := blob r"DIDL\01\6a\00\00\02\01\02\01\00\01\01\03\ca\ff\ee\03foo",
    expect := .failsAt "function annotation length should be at most 1" 8 },
  { name := "func: annotation 4", tys := #[func0 #[.text] #[.nat] #[.query]],
    bytes := blob r"DIDL\01\6a\01\71\01\7d\01\04\01\00\01\01\03\ca\ff\ee\03foo",
    expect := .failsWith "Unknown annotation" },
  { name := "func: not primitive", tys := #[func0 #[] #[]],
    bytes := blob r"DIDL\00\01\6a\01\01\03\ca\ff\ee\01\61", expect := .fails },
  { name := "func: no tag", tys := #[func0 #[] #[]],
    bytes := blob r"DIDL\00\01\6a\01\03\ca\ff\ee\01\61", expect := .fails },
  { name := "func: service not in type table", tys := #[func0 #[.service #[]] #[.nat]],
    bytes := blob r"DIDL\01\6a\01\69\01\7d\00\01\00\01\01\03\ca\ff\ee\03foo",
    expect := .failsWith "unknown opcode -23" },
  { name := "func: invalid annotation", tys := #[func0 #[.text] #[.nat]],
    bytes := blob r"DIDL\01\6a\01\71\01\7d\01\03\01\00\01\01\03\ca\ff\ee\03foo",
    expect := .failsWith "is not a subtype of" },
  { name := "func: invalid name", tys := #[func0 #[] #[]],
    bytes := blob r"DIDL\01\6a\00\00\00\01\00\01\01\03\ca\ff\ee\01\ff",
    expect := .failsWith "invalid utf8" },
  -- subtype
  { name := "service {} !<: service { foo }", tys := #[fooService],
    bytes := blob r"DIDL\01\69\00\01\00\01\03\ca\ff\ee", expect := .fails },
  { name := "service { foo query } !<: service { foo }", tys := #[fooService],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\01\01\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    expect := .fails },
  { name := "service { foo } !<: service { foo query }",
    tys := #[.serviceOf #[method "foo" (func0 #[.text] #[.nat] #[.query])]],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    expect := .fails },
  { name := "service { foo } decodes at service {}", tys := #[.service #[]],
    bytes := blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    expect := ok1 (.service caffee) },
  { name := "service { foo } !<: service {} under opt", tys := #[.opt fooService],
    bytes := blob r"DIDL\01\69\00\01\00\01\03\ca\ff\ee", expect := ok1 none' },
  { name := "func () -> () !<: func (text) -> (nat)", tys := #[func0 #[.text] #[.nat]],
    bytes := blob r"DIDL\01\6a\00\00\00\01\00\01\01\03\ca\ff\ee\03foo", expect := .fails },
  { name := "func (text) -> (nat) decodes at func (text, opt text) -> ()",
    tys := #[func0 #[.text, .opt .text] #[]],
    bytes := blob r"DIDL\01\6a\01\71\01\7d\00\01\00\01\01\03\ca\ff\ee\03foo",
    expect := ok1 (.func caffee "foo") },
  { name := "vec of funcs, checked once", tys := #[.vec (func0 #[.text, .opt .text] #[])],
    bytes := blob (r"DIDL\02\6a\01\71\01\7d\00\6d\00\01\01\03\01\01\03\ca\ff\ee\03foo\01\01\03" ++
      r"\ca\ff\ee\03bar\01\01\00\00"),
    expect := ok1 (.vec #[.func caffee "foo", .func caffee "bar", .func ⟨.empty⟩ ""]) },
  { name := "vec of opt funcs that are not subtypes", tys := #[.vec (.opt (func0 #[] #[.nat]))],
    bytes := blob (r"DIDL\02\6a\01\71\01\7d\00\6d\00\01\01\03\01\01\03\ca\ff\ee\03foo\01\01\03" ++
      r"\ca\ff\ee\03bar\01\01\00\00"),
    expect := ok1 (.vec #[none', none', none']) }
]

/-! ## subtypes.test.did -/

/-- The definitions of subtypes.test.did. -/
def subtypesEnv : TypeEnv := { defs := #[
  ("Vec", .vec (.var "Vec")),
  ("EmptyRecord", .record #[nfield 0 (.var "EmptyRecord")]),
  ("MuRecordOpt", .record #[nfield 0 (.opt (.var "MuRecordOpt"))]),
  ("EmptyVariant", .variant #[nfield 0 (.var "EmptyVariant")])
]}

/-- `t1 <: t2` as subtypes.test.did tests it: a reference of type `func () -> (t1)` decoded at
`opt func () -> (t2)` is the reference, or `null`. `t1` is a primitive type's opcode, or, with
`entries`, the rest of a type table whose second entry is `t1`. -/
def subtypeCase (name : String) (t1 : String) (t2 : Ty) (holds : Bool) (entries : Nat := 0) :
    Case :=
  let bytes :=
    if entries == 0 then blob (r"DIDL\01\6a\00\01" ++ t1 ++ r"\00\01\00\01\01\00\01m")
    else
      -- `"\\" ++ hexDigits entries` is the byte `entries` in a blob literal, such as `\02`.
      blob (r"DIDL" ++ "\\" ++ hexDigits entries ++ r"\6a\00\01\01\00" ++ t1 ++
        r"\01\00\01\01\00\01m")
  { name, env := subtypesEnv, tys := #[.opt (func0 #[] #[t2])], bytes,
    expect := ok1 (if holds then some' (.func ⟨.empty⟩ "m") else none') }

/-- The assertions of subtypes.test.did. -/
def subtypes : Array Case := #[
  subtypeCase "null <: null" r"\7f" .null true,
  subtypeCase "bool <: bool" r"\7e" .bool true,
  subtypeCase "nat <: nat" r"\7d" .nat true,
  subtypeCase "int <: int" r"\7c" .int true,
  subtypeCase "nat <: int" r"\7d" .int true,
  subtypeCase "null </: nat" r"\7f" .nat false,
  subtypeCase "nat </: nat8" r"\7d" .nat8 false,
  subtypeCase "nat8 </: nat" r"\7b" .nat false,
  subtypeCase "nat <: opt bool" r"\7d" (.opt .bool) true,
  subtypeCase "opt bool <: opt bool" r"\6e\7e" (.opt .bool) true (entries := 2),
  subtypeCase "bool <: opt bool" r"\7e" (.opt .bool) true,
  subtypeCase "µ opt <: opt opt nat" r"\6e\01" (.opt (.opt .nat)) true (entries := 2),
  subtypeCase "record {} <: record {}" r"\6c\00" (.record #[]) true (entries := 2),
  subtypeCase "record {} <: record { a : opt empty }" r"\6c\00"
    (.recordOf #[field "a" (.opt .empty)]) true (entries := 2),
  subtypeCase "record {} <: record { a : opt null }" r"\6c\00"
    (.recordOf #[field "a" (.opt .null)]) true (entries := 2),
  subtypeCase "record {} <: record { a : reserved }" r"\6c\00"
    (.recordOf #[field "a" .reserved]) true (entries := 2),
  subtypeCase "record {} </: record { a : empty }" r"\6c\00"
    (.recordOf #[field "a" .empty]) false (entries := 2),
  subtypeCase "record {} </: record { a : nat }" r"\6c\00"
    (.recordOf #[field "a" .nat]) false (entries := 2),
  subtypeCase "record {} <: record { a : null }" r"\6c\00"
    (.recordOf #[field "a" .null]) true (entries := 2),
  subtypeCase "func () -> () <: func () -> ()" r"\6a\00\00\00" (func0 #[] #[]) true (entries := 2),
  subtypeCase "func () -> () <: func () -> (opt empty)" r"\6a\00\00\00"
    (func0 #[] #[.opt .empty]) true (entries := 2),
  subtypeCase "func () -> () <: func () -> (opt null)" r"\6a\00\00\00"
    (func0 #[] #[.opt .null]) true (entries := 2),
  subtypeCase "func () -> () <: func () -> (reserved)" r"\6a\00\00\00"
    (func0 #[] #[.reserved]) true (entries := 2),
  subtypeCase "func () -> () </: func () -> (empty)" r"\6a\00\00\00"
    (func0 #[] #[.empty]) false (entries := 2),
  subtypeCase "func () -> () </: func () -> (nat)" r"\6a\00\00\00"
    (func0 #[] #[.nat]) false (entries := 2),
  subtypeCase "func () -> () <: func () -> (null)" r"\6a\00\00\00"
    (func0 #[] #[.null]) true (entries := 2),
  subtypeCase "func (opt empty) -> () <: func () -> ()" r"\6a\01\02\00\00\6e\6f"
    (func0 #[] #[]) true (entries := 3),
  subtypeCase "func (opt null) -> () <: func () -> ()" r"\6a\01\02\00\00\6e\7f"
    (func0 #[] #[]) true (entries := 3),
  subtypeCase "func (reserved) -> () <: func () -> ()" r"\6a\01\70\00\00"
    (func0 #[] #[]) true (entries := 2),
  subtypeCase "func (empty) -> () </: func () -> ()" r"\6a\01\6f\00\00"
    (func0 #[] #[]) false (entries := 2),
  subtypeCase "func (nat) -> () </: func () -> ()" r"\6a\01\7d\00\00"
    (func0 #[] #[]) false (entries := 2),
  subtypeCase "func (null) -> () <: func () -> ()" r"\6a\01\7f\00\00"
    (func0 #[] #[]) true (entries := 2),
  subtypeCase "variant {} <: variant {}" r"\6b\00" (.variant #[]) true (entries := 2),
  subtypeCase "variant {} <: variant {0 : nat}" r"\6b\00"
    (.variant #[nfield 0 .nat]) true (entries := 2),
  subtypeCase "variant {0 : nat} <: variant {0 : nat}" r"\6b\01\00\7d"
    (.variant #[nfield 0 .nat]) true (entries := 2),
  subtypeCase "variant {0 : bool} </: variant {0 : nat}" r"\6b\01\00\7e"
    (.variant #[nfield 0 .nat]) false (entries := 2),
  subtypeCase "variant {0 : bool} </: variant {1 : bool}" r"\6b\01\00\7e"
    (.variant #[nfield 1 .bool]) false (entries := 2),
  subtypeCase "(µ record) <: (µ record)" r"\6c\01\00\01" (.var "EmptyRecord") true (entries := 2),
  subtypeCase "(µ record) </: empty" r"\6c\01\00\01" .empty false (entries := 2),
  subtypeCase "empty <: (µ record)" r"\6f" (.var "EmptyRecord") true,
  subtypeCase "(µ record) <: record {µ record}" r"\6c\01\00\01"
    (.tuple #[.var "EmptyRecord"]) true (entries := 2),
  subtypeCase "record {µ record} <: (µ record)" r"\6c\01\00\02\6c\01\00\02"
    (.var "EmptyRecord") true (entries := 3),
  subtypeCase "(µ record) <: (μ (record opt))" r"\6c\01\00\01"
    (.var "MuRecordOpt") true (entries := 2),
  subtypeCase "(µ variant) <: (µ variant)" r"\6b\01\00\01"
    (.var "EmptyVariant") true (entries := 2),
  subtypeCase "(µ variant) </: empty" r"\6b\01\00\01" .empty false (entries := 2),
  subtypeCase "empty <: (µ variant)" r"\6f" (.var "EmptyVariant") true,
  subtypeCase "(µ variant) <: variant {µ variant}" r"\6b\01\00\01"
    (.variant #[nfield 0 (.var "EmptyVariant")]) true (entries := 2),
  subtypeCase "variant {µ variant} <: (µ variant)" r"\6b\01\00\02\6b\01\00\02"
    (.var "EmptyVariant") true (entries := 3),
  subtypeCase "(µ vec) <: (µ vec)" r"\6d\01" (.var "Vec") true (entries := 2),
  subtypeCase "(µ vec) </: empty" r"\6d\01" .empty false (entries := 2),
  subtypeCase "empty <: (µ vec)" r"\6f" (.var "Vec") true,
  subtypeCase "(µ vec) <: vec {µ vec}" r"\6d\01" (.vec (.var "Vec")) true (entries := 2),
  subtypeCase "vec {µ vec} <: (µ vec)" r"\6d\02\6d\02" (.var "Vec") true (entries := 3),
  subtypeCase "service {} <: principal" r"\69\00" .principal true (entries := 2),
  subtypeCase "service {m:()->()} <: principal" r"\69\01\01m\02\6a\00\00\00"
    .principal true (entries := 3),
  subtypeCase "principal </: service {}" r"\68" (.service #[]) false,
  subtypeCase "(µ service) <: principal" r"\69\01\01m\02\6a\00\01\01\00"
    .principal true (entries := 3),
  subtypeCase "(future type) <: (opt empty)" r"\67\00" (.opt .empty) true (entries := 2),
  subtypeCase "(future type) </: (nat)" r"\67\00" .nat false (entries := 2)
]

/-! ## spacebomb.test.did: all must fail, by running out of fuel -/

/-- A case that must run out of fuel: the message `s`, a blob literal, decoded at `tys`. -/
def bomb (name : String) (tys : Array Ty) (s : String) : Case :=
  { name, tys, bytes := blob s, expect := .failsWith "Decoding cost exceeds the limit" }

/-- The messages of spacebomb.test.did: a billion values in a few bytes, of types whose values
take no bytes. -/
def vecNull : String := r"DIDL\01\6d\7f\01\00\80\94\eb\dc\03"
def vecReserved : String := r"DIDL\01\6d\70\01\00\80\94\eb\dc\03"
def zeroSized : String :=
  r"DIDL\04\6c\03\00\7f\01\01\02\02\6c\01\00\70\6c\00\6d\00\01\03\80\94\eb\dc\03"
def vecVecNull : String :=
  r"DIDL\02\6d\01\6d\7f\01\00\05\ff\ff\3f\ff\ff\3f\ff\ff\3f\ff\ff\3f\ff\ff\3f"
def vecRecord : String := r"DIDL\02\6d\01\6c\00\01\00\80\ad\e2\04"
def tree : String :=
  r"DIDL\17\6c\02\01\7f\02\7f\6c\02\01\00\02\00\6c\02\00\01\01\01\6c\02\00\02\01\02\6c\02\00\03" ++
  r"\01\03\6c\02\00\04\01\04\6c\02\00\05\01\05\6c\02\00\06\01\06\6c\02\00\07\01\07\6c\02\00\08" ++
  r"\01\08\6c\02\00\09\01\09\6c\02\00\0a\01\0a\6c\02\00\0b\01\0b\6c\02\00\0c\01\0c\6c\02\00\0d" ++
  r"\02\0d\6c\02\00\0e\01\0e\6c\02\00\0f\01\0f\6c\02\00\10\01\10\6c\02\00\11\01\11\6c\02\00\12" ++
  r"\01\12\6c\02\00\13\01\13\6e\14\6d\15\01\16"

/-- The assertions of spacebomb.test.did. -/
def spacebomb : Array Case := #[
  bomb "vec null (extra argument)" #[] vecNull,
  bomb "vec reserved (extra argument)" #[] vecReserved,
  bomb "zero-sized record (extra argument)" #[] zeroSized,
  bomb "vec vec null (extra argument)" #[] vecVecNull,
  bomb "vec record {} (extra argument)" #[] vecRecord,
  bomb "vec opt record with 2^20 null (extra argument)" #[] (tree ++ r"\02\01\01"),
  bomb "vec null (not ignored)" #[.vec (.opt .nat)] vecNull,
  bomb "vec reserved (not ignored)" #[.vec .reserved] vecReserved,
  bomb "zero-sized record (not ignored)" #[.vec (.tuple #[.null, .tuple #[.reserved], .record #[]])]
    zeroSized,
  bomb "vec vec null (not ignored)" #[.vec (.vec .null)] vecVecNull,
  bomb "vec record {} (not ignored)" #[.vec (.record #[])] vecRecord,
  bomb "vec null (subtyping)" #[.opt .nat] vecNull,
  bomb "vec reserved (subtyping)" #[.opt .nat] vecReserved,
  bomb "zero-sized record (subtyping)" #[.opt .nat] zeroSized,
  bomb "vec vec null (subtyping)" #[.vec (.opt .nat)] vecVecNull,
  bomb "vec record {} (subtyping)" #[.opt .nat] vecRecord,
  bomb "vec opt record with 2^20 null (subtyping)" #[.vec (.opt (.record #[]))]
    (tree ++ r"\05\01\01\01\01\01")
]

/-! ## overshoot.test.did: all must fail early -/

/-- The assertions of overshoot.test.did: counts larger than the rest of the message. -/
def overshoot : Array Case := #[
  { name := "type table length", tys := #[], bytes := blob r"DIDL\80\94\eb\dc\03\00",
    expect := .failsAt "type table size exceeded" 4 },
  { name := "argument sequence length", tys := #[], bytes := blob r"DIDL\00\80\94\eb\dc\03",
    expect := .failsWith "not enough bytes for 1000000000 arguments" },
  { name := "text length", tys := #[.text], bytes := blob r"DIDL\00\01\71\80\94\eb\dc\03Motoko",
    expect := .failsWith "Cannot read 1000000000 bytes" },
  { name := "principal length", tys := #[.principal],
    bytes := blob r"DIDL\00\01\68\01\80\94\eb\dc\03Motoko",
    expect := .failsWith "Principal is longer than 29 bytes" },
  { name := "record field number", tys := #[],
    bytes := blob r"DIDL\01\6c\80\94\eb\dc\03\00\7f\00\7f",
    expect := .failsWith "not enough bytes for 1000000000 fields" },
  { name := "variant field number", tys := #[],
    bytes := blob r"DIDL\01\6b\80\94\eb\dc\03\00\7f\00\7f",
    expect := .failsWith "not enough bytes for 1000000000 fields" },
  { name := "vector length", tys := #[.vec .bool],
    bytes := blob r"DIDL\01\6d\7e\01\00\80\94\eb\dc\03\00\00\00",
    expect := .failsWith "not enough bytes for 1000000000 vector elements" },
  { name := "func arg length", tys := #[],
    bytes := blob (r"DIDL\01\6a\68\68\68\68\68\00\00\00\00\00\00\00\00\00\00\00\00\00\00\68\68" ++
      r"\68\68\68\68\00\68\68\7a\68\68\68\68\68\68\68\68\68\68\68\68\68\68\68\79\79\79\79\79\79" ++
      r"\79\79\79\79\79\79\79\79\79\7a\79\79\79\79\79\79\79\79\79\7b\79\79\79\79\79\7f\00\79\79" ++
      r"\79\79\79\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\04" ++
      r"\00\00\00\00\01\01\68\68\1d\00\00\00\00\00\00\00\68\1f\00\00\00\00\00\00\00\00\68\00\44" ++
      r"\44\44\44\44\44\49\44\4c\00\f7\01\7c\80\80\80\80\80\80\80\80\ff\ff\ff\ff\80\80\80\80\80" ++
      r"\80\80\80\ff\ff\ff\ff\80\80\80\80\80\80\80\80\80\80\80\80\49\44\4c\01\6c\01\ff\ff\ff\ff" ++
      r"\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff\ff" ++
      r"\ff\ff\ff\ff\01"),
    expect := .fails },
  { name := "future type length", tys := #[], bytes := blob r"DIDL\01\67\80\94\eb\dc\03\00\00",
    expect := .failsWith "Cannot read 1000000000 bytes" },
  { name := "future value length", tys := #[],
    bytes := blob r"DIDL\01\67\00\01\00\80\94\eb\dc\03\00\00",
    expect := .failsWith "Cannot read 1000000000 bytes" }
]

/-! ## Limits, numbers, and other cases of the coercion table -/

/-- A LEB128 number of `n` bytes `ff`, then `last`. -/
def longLeb (n : Nat) (last : String) : String := String.join (List.replicate n r"\ff") ++ last

/-- The limits of `DecodeConfig`, numbers at the edges of the `UInt64` fast path, and the rows of
the coercion table that the suite does not test. -/
def limits : Array Case := #[
  { name := "maxTypeTableLength", tys := #[], bytes := blob r"DIDL\02\6e\6f\6e\6f\00",
    config := { maxTypeTableLength := 1 }, expect := .failsWith "type table size exceeded" },
  { name := "maxTypeTableLength ok", tys := #[], bytes := blob r"DIDL\02\6e\6f\6e\6f\00",
    config := { maxTypeTableLength := 2 }, expect := .values #[] },
  { name := "maxHeaderLength", tys := #[], bytes := blob r"DIDL\02\6e\6f\6e\6f\00",
    config := { maxHeaderLength := 9 },
    expect := .failsWith "Type table header exceeds the limit of 9 bytes" },
  { name := "maxHeaderLength exact", tys := #[], bytes := blob r"DIDL\02\6e\6f\6e\6f\00",
    config := { maxHeaderLength := 10 }, expect := .values #[] },
  { name := "maxHeaderLength: values may be longer", tys := #[.text],
    bytes := blob r"DIDL\00\01\71\06Motoko", config := { maxHeaderLength := 7 },
    expect := ok1 (.text "Motoko") },
  { name := "maxHeaderLength: a malformed header within it", tys := #[],
    bytes := blob r"DIDL\01\00\00\00\00\00", config := { maxHeaderLength := 7 },
    expect := .failsWith "0 is not a valid future type" },
  { name := "maxDepth", tys := #[.opt (.opt (.opt .bool))], bytes := blob r"DIDL\00\01\7e\01",
    config := { maxDepth := 3 }, expect := .failsWith "Recursion limit exceeded at depth 3" },
  { name := "maxDepth ok", tys := #[.opt (.opt (.opt .bool))], bytes := blob r"DIDL\00\01\7e\01",
    config := { maxDepth := 4 }, expect := ok1 (some' (some' (some' (.bool true)))) },
  { name := "fuel", tys := #[.vec .null], bytes := blob r"DIDL\01\6d\7f\01\00\0a",
    config := { fuel := some 10 }, expect := .failsWith "Decoding cost exceeds the limit" },
  { name := "fuel ok", tys := #[.vec .null], bytes := blob r"DIDL\01\6d\7f\01\00\0a",
    config := { fuel := some 11 }, expect := ok1 (.vec (Array.replicate 10 .null)) },
  -- A failed attempt under `opt` keeps the fuel it spent: 1 for the option, 3 for the attempt,
  -- 3 to skip the record.
  { name := "fuel spent on a failed opt attempt", tys := #[.opt (.tuple #[.nat, .bool])],
    bytes := blob r"DIDL\01\6c\02\00\7d\01\7d\01\00\01\02", config := { fuel := some 6 },
    expect := .failsWith "Decoding cost" },
  { name := "fuel for a failed opt attempt and the skip", tys := #[.opt (.tuple #[.nat, .bool])],
    bytes := blob r"DIDL\01\6c\02\00\7d\01\7d\01\00\01\02", config := { fuel := some 7 },
    expect := ok1 none' },
  { name := "missing arguments cost fuel", tys := #[.null, .null], bytes := blob r"DIDL\00\00",
    config := { fuel := some 1 }, expect := .failsWith "Decoding cost" },
  -- numbers at the edges of the UInt64 path
  { name := "nat 2^63", tys := #[.nat],
    bytes := blob r"DIDL\00\01\7d\80\80\80\80\80\80\80\80\80\01", expect := ok1 (.nat (2 ^ 63)) },
  { name := "nat 2^64 - 1", tys := #[.nat],
    bytes := blob r"DIDL\00\01\7d\ff\ff\ff\ff\ff\ff\ff\ff\ff\01",
    expect := ok1 (.nat (2 ^ 64 - 1)) },
  { name := "nat 2^64", tys := #[.nat],
    bytes := blob r"DIDL\00\01\7d\80\80\80\80\80\80\80\80\80\02", expect := ok1 (.nat (2 ^ 64)) },
  { name := "nat 2^63 - 1 (nine bytes)", tys := #[.nat],
    bytes := blob r"DIDL\00\01\7d\ff\ff\ff\ff\ff\ff\ff\ff\7f", expect := ok1 (.nat (2 ^ 63 - 1)) },
  { name := "int -2^63", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\80\80\80\80\80\80\80\80\80\7f", expect := ok1 (.int (-2 ^ 63)) },
  { name := "int 2^63", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\80\80\80\80\80\80\80\80\80\01", expect := ok1 (.int (2 ^ 63)) },
  { name := "int -2^64", tys := #[.int],
    bytes := blob r"DIDL\00\01\7c\80\80\80\80\80\80\80\80\80\7e", expect := ok1 (.int (-2 ^ 64)) },
  { name := "nat of 20,001 bytes", tys := #[.nat],
    bytes := blob (r"DIDL\00\01\7d" ++ longLeb 20000 r"\01"),
    expect := ok1 (.nat (2 ^ 140001 - 1)) },
  { name := "int of 20,001 bytes, negative", tys := #[.int],
    bytes := blob (r"DIDL\00\01\7c" ++ longLeb 20000 r"\7f"), expect := ok1 (.int (-1)) },
  { name := "int of 20,001 bytes, -2^140000", tys := #[.int],
    bytes := blob (r"DIDL\00\01\7c" ++ String.join (List.replicate 20000 r"\80") ++ r"\7f"),
    expect := ok1 (.int (-2 ^ 140000)) },
  { name := "overlong nat of 30,000 bytes", tys := #[.nat],
    bytes := blob (r"DIDL\00\01\7d\81" ++ String.join (List.replicate 29999 r"\80") ++ r"\00"),
    expect := ok1 (.nat 1) },
  -- other rows of the coercion table
  { name := "null at bool", tys := #[.bool], bytes := blob r"DIDL\00\01\7f", expect := .fails },
  { name := "nat8 </: nat16", tys := #[.nat16], bytes := blob r"DIDL\00\01\7b\01",
    expect := .fails },
  { name := "int8 </: int", tys := #[.int], bytes := blob r"DIDL\00\01\77\01", expect := .fails },
  { name := "text </: blob", tys := #[.blob], bytes := blob r"DIDL\00\01\71\00", expect := .fails },
  { name := "blob </: text", tys := #[.text], bytes := blob r"DIDL\01\6d\7b\01\00\00",
    expect := .fails },
  { name := "empty at opt empty", tys := #[.opt .empty], bytes := blob r"DIDL\00\01\6f",
    expect := .failsWith "Cannot decode empty type" },
  { name := "empty at reserved", tys := #[.reserved], bytes := blob r"DIDL\00\01\6f",
    expect := .failsWith "Cannot decode empty type" },
  { name := "nat at empty", tys := #[.empty], bytes := blob r"DIDL\00\01\7d\01",
    expect := .failsWith "Cannot decode empty type" },
  { name := "nat at opt empty", tys := #[.opt .empty], bytes := blob r"DIDL\00\01\7d\01",
    expect := ok1 none' },
  { name := "opt empty with a value", tys := #[.opt .empty],
    bytes := blob r"DIDL\01\6e\6f\01\00\01", expect := .failsWith "Cannot decode empty type" },
  { name := "vec at record", tys := #[.record #[]], bytes := blob r"DIDL\01\6d\7f\01\00\00",
    expect := .fails },
  { name := "record at variant", tys := #[.variant #[]], bytes := blob r"DIDL\01\6c\00\01\00",
    expect := .fails },
  { name := "record at opt vec", tys := #[.opt (.vec .nat)], bytes := blob r"DIDL\01\6c\00\01\00",
    expect := ok1 none' },
  { name := "vec at opt vec", tys := #[.opt (.vec .int)],
    bytes := blob r"DIDL\01\6d\7d\01\00\02\01\02", expect := ok1 (some' (.vec #[.int 1, .int 2])) },
  { name := "vec nat8 at opt blob", tys := #[.opt .blob],
    bytes := blob r"DIDL\01\6d\7b\01\00\02\01\02", expect := ok1 (some' (.blob (bytes [1, 2]))) },
  { name := "blob through var", env := { defs := #[("B", .vec (.var "N")), ("N", .nat8)] },
    tys := #[.var "B"], bytes := blob r"DIDL\01\6d\7b\01\00\02\01\02",
    expect := ok1 (.blob (bytes [1, 2])) },
  { name := "vec nat8 element at nat8 vector of opt", tys := #[.vec (.opt .nat8)],
    bytes := blob r"DIDL\01\6d\7b\01\00\02\01\02",
    expect := ok1 (.vec #[some' (.nat8 1), some' (.nat8 2)]) },
  { name := "missing argument at var to opt", env := { defs := #[("O", .opt .nat)] },
    tys := #[.var "O"], bytes := blob r"DIDL\00\00", expect := ok1 none' },
  { name := "missing field through var", env := { defs := #[("R", .reserved)] },
    tys := #[.record #[nfield 3 (.var "R")]], bytes := blob r"DIDL\01\6c\00\01\00",
    expect := ok1 (.record #[(.num 3, .reserved)]) },
  { name := "record: a missing field between wire fields",
    tys := #[.record #[nfield 1 .nat, nfield 2 .bool, nfield 7 .text]],
    bytes := blob r"DIDL\01\6c\04\00\7f\02\7e\03\7d\07\71\01\00\01\09\05hello",
    expect := .failsWith "field 1 is not optional field" },
  { name := "record fields merged by id",
    tys := #[.record #[nfield 0 .reserved, nfield 2 .bool, nfield 5 (.opt .nat), nfield 7 .text]],
    bytes := blob r"DIDL\01\6c\04\00\7f\02\7e\03\7d\07\71\01\00\01\09\05hello",
    expect := ok1 (.record #[(.num 0, .reserved), (.num 2, .bool true), (.num 5, none'),
      (.num 7, .text "hello")]) },
  { name := "nat at bool", tys := #[.bool], bytes := blob r"DIDL\00\01\7d\01",
    expect := .failsWith "nat cannot be deserialized to bool" },
  { name := "null at nat", tys := #[.nat], bytes := blob r"DIDL\00\01\7f", expect := .fails },
  { name := "reserved at nat", tys := #[.nat], bytes := blob r"DIDL\00\01\70", expect := .fails },
  { name := "opt nat at nat", tys := #[.nat], bytes := blob r"DIDL\01\6e\7d\01\00\01\05",
    expect := .fails },
  { name := "null at vec", tys := #[.vec .nat], bytes := blob r"DIDL\00\01\7f", expect := .fails },
  { name := "null at record", tys := #[.record #[]], bytes := blob r"DIDL\00\01\7f",
    expect := .fails },
  { name := "null at variant", tys := #[.variant #[nfield 0 .null]], bytes := blob r"DIDL\00\01\7f",
    expect := .fails },
  { name := "null at principal", tys := #[.principal], bytes := blob r"DIDL\00\01\7f",
    expect := .fails },
  { name := "null at service", tys := #[.service #[]], bytes := blob r"DIDL\00\01\7f",
    expect := .fails },
  { name := "null at func", tys := #[func0 #[] #[]], bytes := blob r"DIDL\00\01\7f",
    expect := .fails },
  { name := "missing argument at record", tys := #[.record #[]], bytes := blob r"DIDL\00\00",
    expect := .failsWith "No more values" },
  { name := "field count of 2^32", tys := #[], bytes := blob r"DIDL\01\6c\80\80\80\80\10\00",
    expect := .failsAt "field length out of 32-bit range" 6 },
  { name := "opt rewinds to the start of the value", tys := #[.opt (.tuple #[.nat, .bool]), .bool],
    bytes := blob r"DIDL\01\6c\02\00\7d\01\7d\02\00\7e\05\06\01",
    expect := .values #[none', .bool true] },
  { name := "opt rewinds after the flag", tys := #[.opt (.tuple #[.nat, .bool]), .bool],
    bytes := blob r"DIDL\02\6e\01\6c\02\00\7d\01\7d\02\00\7e\01\05\06\01",
    expect := .values #[none', .bool true] },
  { name := "nested opt recovery", tys := #[.opt (.tuple #[.opt .bool, .nat])],
    bytes := blob r"DIDL\01\6c\02\00\7d\01\7d\01\00\05\06",
    expect := ok1 (some' (.record #[(.num 0, none'), (.num 1, .nat 6)])) },
  { name := "fatal error inside an opt attempt", tys := #[.opt (.tuple #[.text])],
    bytes := blob r"DIDL\01\6c\01\00\71\01\00\01\ff", expect := .failsWith "invalid utf8" },
  -- UTF-8 at its edges, as Rust's `str::from_utf8` takes it, also on wasm32: surrogates,
  -- overlong forms and code points above U+10FFFF are not UTF-8
  { name := "text: a surrogate", tys := #[.text], bytes := blob r"DIDL\00\01\71\03\ed\a0\80",
    expect := .failsAt "invalid utf8" 7 },
  { name := "text: an overlong NUL", tys := #[.text], bytes := blob r"DIDL\00\01\71\02\c0\80",
    expect := .failsWith "invalid utf8" },
  { name := "text: an overlong slash", tys := #[.text], bytes := blob r"DIDL\00\01\71\03\e0\80\af",
    expect := .failsWith "invalid utf8" },
  { name := "text: above U+10FFFF", tys := #[.text], bytes := blob r"DIDL\00\01\71\04\f4\90\80\80",
    expect := .failsWith "invalid utf8" },
  { name := "text: U+10FFFF", tys := #[.text], bytes := blob r"DIDL\00\01\71\04\f4\8f\bf\bf",
    expect := ok1 (.text (String.singleton (Char.ofNat 0x10FFFF))) },
  { name := "text: U+D7FF and U+E000", tys := #[.text],
    bytes := blob r"DIDL\00\01\71\06\ed\9f\bf\ee\80\80", expect := ok1 (.text "\uD7FF\uE000") },
  { name := "text: NUL", tys := #[.text], bytes := blob r"DIDL\00\01\71\01\00",
    expect := ok1 (.text "\x00") },
  -- the expected types are checked
  { name := "unsorted expected record", tys := #[.record #[nfield 2 .nat, nfield 1 .nat]],
    bytes := blob r"DIDL\00\00", expect := .failsWith "fields not sorted by id" },
  { name := "duplicate expected variant case", tys := #[.variant #[nfield 1 .nat, nfield 1 .nat]],
    bytes := blob r"DIDL\00\00", expect := .failsWith "fields not sorted by id" },
  { name := "unbound expected name", tys := #[.var "X"], bytes := blob r"DIDL\00\01\7f",
    expect := .failsWith "unbound type identifier X" },
  { name := "cyclic definitions", env := { defs := #[("A", .var "B"), ("B", .var "A")] },
    tys := #[], bytes := blob r"DIDL\00\00", expect := .failsWith "cyclic type definition" },
  { name := "table in an expected type", tys := #[.table 0],
    bytes := blob r"DIDL\01\6e\7f\01\00\00", expect := .fails },
  { name := "unsorted expected service",
    tys := #[.service #[method "b" (func0 #[] #[]), method "a" (func0 #[] #[])]],
    bytes := blob r"DIDL\00\00", expect := .failsWith "methods not sorted" }
]

/-! ## Hostile messages

Messages that a sender could make to burn a canister's instructions or stack, beyond those of the
suite: huge numbers, large types under `opt`, deep values and deep subtype checks at once, long
chains of table entries, wide records, many arguments. Each must be decoded, or rejected, quickly
and within the limits. -/

/-- `DIDL`, then these bytes. -/
def didl (bs : List UInt8) : ByteArray := "DIDL".toUTF8 ++ bytes bs

/-- The LEB128 bytes of `n`. -/
def leb (n : Nat) : ByteArray := Leb128.ofNat n

/-- The SLEB128 bytes of `i`. -/
def sleb (i : Int) : ByteArray := Leb128.ofInt i

/-- `n` times the byte `b`. -/
def times (n : Nat) (b : UInt8) : ByteArray := ⟨Array.replicate n b⟩

/-- A message of `n` values of a variant type with `cases` cases of type `null`, numbered from 0,
each value the case 0: three bytes per case in the type table, one per value. -/
def wideVariants (cases n : Nat) : ByteArray := Id.run do
  let mut b := didl [2, 0x6b] ++ leb cases
  for i in [0:cases] do
    b := b ++ leb i |>.push 0x7f
  return b ++ bytes [0x6d, 0, 1, 1] ++ leb n ++ times n 0

/-- A record type with `n` fields of type `text`, numbered from 0. -/
def wideRecord (n : Nat) : Ty := .record ((Array.range n).map fun i => nfield i.toUInt32 .text)

/-- A message of a value `d` levels deep, `variant { 1 = variant { 1 = … variant { 0 = f } } }`,
where `f` is a reference to a function `func () -> (table2)`, whose result type is a cycle of
`k` record types, `table2 = record { 0 : table3 }` to `record { 0 : table2 }`. Decoding it at
`T` of `deepEnv` nests `d + 2` values, and checking that the function's type is a subtype of
`F` recurses about `2k` levels: the two at once take the most stack that a message can make
the decoder take. -/
def deepRef (d k : Nat) : ByteArray := Id.run do
  -- table0 = variant { 0 : table1; 1 : table0 }; table1 = func () -> (table2)
  let mut b := didl [] ++ leb (k + 2) ++ bytes [0x6b, 2, 0, 1, 1, 0, 0x6a, 0, 1, 2, 0]
  for j in [2:k + 2] do
    b := b ++ bytes [0x6c, 1, 0] ++ sleb (if j == k + 1 then 2 else j + 1)
  -- One argument of type table0: the case 1, `d` times, the case 0, and the reference: the
  -- flag 1, the principal (flag 1, no bytes), and the method's name, "".
  return b ++ bytes [1, 0] ++ times d 1 ++ bytes [0, 1, 1, 0, 0]

/-- The expected types of `deepRef`'s messages: `T = variant { 0 : F; 1 : T }`, `F = func () ->
(R)`, `R = record { 0 : R }`. -/
def deepEnv : TypeEnv := { defs := #[
  ("T", .variant #[nfield 0 (.var "F"), nfield 1 (.var "T")]),
  ("F", func0 #[] #[.var "R"]),
  ("R", .record #[nfield 0 (.var "R")])
]}

/-- The value of `deepRef d k` at `T`. -/
def deepRefValue (d : Nat) : Value :=
  (List.replicate d ()).foldl (fun v _ => .variant (.num 1) v)
    (.variant (.num 0) (.func ⟨.empty⟩ ""))

/-- A message of a chain of `n` table entries, `table_i = opt table_(i+1)`, the last one back to
the first, and a value of `d` options with a value, then one without. -/
def optChain (n d : Nat) : ByteArray := Id.run do
  let mut b := didl [] ++ leb n
  for i in [0:n] do
    b := b ++ bytes [0x6e] ++ sleb (if i + 1 == n then 0 else i + 1)
  return b ++ bytes [1, 0] ++ times d 1 ++ bytes [0]

/-- `d` options with a value, around one without. -/
def someN (d : Nat) : Value := (List.replicate d ()).foldl (fun v _ => some' v) none'

/-- A message of a record type with `n` fields of type `null`, numbered from 0, and `k`
arguments of that type, which take no bytes. -/
def wideNulls (n k : Nat) : ByteArray := Id.run do
  let mut b := didl [1, 0x6c] ++ leb n
  for i in [0:n] do
    b := b ++ leb i |>.push 0x7f
  return b ++ leb k ++ times k 0

/-- A message of `W = opt record { 0 : W; 1 : nat }`, `d` levels deep, each `nat` 5. At `E = opt
record { 0 : E; 1 : text }`, each level fails at its `nat`, after its inner levels, and is then
skipped, inner levels and all: the work grows with the square of `d`, and the fuel bounds it. -/
def nestedAttempts (d : Nat) : ByteArray :=
  didl [2, 0x6e, 1, 0x6c, 2, 0, 0, 1, 0x7d, 1, 0] ++ times d 1 ++ bytes [0] ++ times d 5

/-- The definition of `E` for `nestedAttempts`. -/
def attemptsEnv : TypeEnv :=
  { defs := #[("E", .opt (.record #[nfield 0 (.var "E"), nfield 1 .text]))] }

/-- The hostile messages. -/
def hostile : Array Case := #[
  -- Numbers that the message gives are written out in error messages up to 2^64 only: writing
  -- out a number of n digits takes about n² steps.
  { name := "variant index 2^64 - 1", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\ff\ff\ff\ff\ff\ff\ff\ff\ff\01",
    expect := .failsAt "Variant index 18446744073709551615 larger than length 1" 11 },
  { name := "variant index 2^64", tys := #[.variant #[nfield 0 .null]],
    bytes := blob r"DIDL\01\6b\01\00\7f\01\00\80\80\80\80\80\80\80\80\80\02",
    expect := .failsAt "Variant index 2^64 or more larger than length 1" 11 },
  { name := "text length 2^64", tys := #[.text],
    bytes := blob r"DIDL\00\01\71\80\80\80\80\80\80\80\80\80\02",
    expect := .failsWith "Cannot read 2^64 or more bytes" },
  { name := "future value length 2^64", tys := #[],
    bytes := blob r"DIDL\01\67\00\01\00\80\80\80\80\80\80\80\80\80\02\00",
    expect := .failsWith "Cannot read 2^64 or more bytes" },
  { name := "vector length 2^64", tys := #[.vec .bool],
    bytes := blob r"DIDL\01\6d\7e\01\00\80\80\80\80\80\80\80\80\80\02",
    expect := .failsWith "not enough bytes for 2^64 or more vector elements" },
  { name := "argument count 2^64", tys := #[],
    bytes := blob r"DIDL\00\80\80\80\80\80\80\80\80\80\02",
    expect := .failsWith "not enough bytes for 2^64 or more arguments" },
  { name := "type index 2^64", tys := #[],
    bytes := blob r"DIDL\01\6e\80\80\80\80\80\80\80\80\80\02\00",
    expect := .failsAt "type index 2^64 or more out of range" 6 },
  { name := "opcode -2^64", tys := #[], bytes := blob r"DIDL\00\01\80\80\80\80\80\80\80\80\80\7e",
    expect := .failsAt "unknown opcode -2^64 or less" 6 },
  { name := "future opcode 2^64", tys := #[],
    bytes := blob r"DIDL\01\80\80\80\80\80\80\80\80\80\02\00\00",
    expect := .failsAt "2^64 or more is not a valid future type" 5 },
  -- Counts, lengths, indices and opcodes of more than 10 bytes are rejected before they are
  -- read, as the Rust crate does, and so cost no more than counting their bytes.
  { name := "variant index of 30,001 bytes", tys := #[.variant #[nfield 0 .null]],
    bytes := didl [1, 0x6b, 1, 0, 0x7f, 1, 0] ++ times 30000 0xff |>.push 0x7f,
    expect := .failsWith "LEB128 number of more than 10 bytes", maxMs := some 2000 },
  { name := "text length of 30,001 bytes", tys := #[.text],
    bytes := didl [0, 1, 0x71] ++ times 30000 0xff |>.push 0x7f,
    expect := .failsWith "LEB128 number of more than 10 bytes", maxMs := some 2000 },
  { name := "type index of 30,001 bytes", tys := #[],
    bytes := didl [1, 0x6e] ++ times 30000 0xff ++ bytes [0x3f, 0],
    expect := .failsWith "LEB128 number of more than 10 bytes", maxMs := some 2000 },
  { name := "opcode of 30,001 bytes", tys := #[],
    bytes := didl [0, 1] ++ times 30000 0x80 |>.push 0x40,
    expect := .failsWith "LEB128 number of more than 10 bytes", maxMs := some 2000 },
  -- A value that does not fit an `opt` type is `none`, and the error that says why is dropped:
  -- it is not written out, which takes time in proportion to the size of the types it names.
  { name := "6,000 coercions under opt from a variant of 4,000 cases", tys := #[.vec (.opt .nat)],
    bytes := wideVariants 4000 6000, expect := ok1 (.vec (Array.replicate 6000 none')),
    maxMs := some 2000 },
  { name := "6,000 coercions under opt to a record of 3,000 fields",
    tys := #[.vec (.opt (wideRecord 3000))],
    bytes := didl [1, 0x6d, 0x7d, 1, 0] ++ leb 6000 ++ times 6000 1,
    expect := ok1 (.vec (Array.replicate 6000 none')), maxMs := some 2000 },
  { name := "3,000 references under opt to a function of 3,000 arguments, not a subtype",
    tys := #[.vec (.opt (func0 #[] #[.nat]))],
    bytes := didl [2, 0x6a] ++ leb 3000 ++ times 3000 0x7d ++ bytes [0, 0, 0x6d, 0, 1, 1] ++
      leb 3000 ++ (List.replicate 3000 (bytes [1, 1, 0, 0])).foldl (· ++ ·) .empty,
    expect := ok1 (.vec (Array.replicate 3000 none')), maxMs := some 2000 },
  -- Vectors of values that take no bytes, of very many elements: the fuel ends them.
  { name := "vec null of 2^64 elements", tys := #[.vec .null],
    bytes := blob r"DIDL\01\6d\7f\01\00\80\80\80\80\80\80\80\80\80\02",
    expect := .failsWith "Decoding cost exceeds the limit" },
  { name := "vec null, its length of 2,001 bytes", tys := #[.vec .null],
    bytes := didl [1, 0x6d, 0x7f, 1, 0] ++ times 2000 0xff |>.push 0x7f,
    expect := .failsWith "LEB128 number of more than 10 bytes", maxMs := some 2000 },
  -- The deepest value and the deepest subtype check that the limits allow, together: the stack
  -- must hold both, also on wasm32.
  { name := "a value 512 deep, with a subtype check 511 deep", env := deepEnv, tys := #[.var "T"],
    bytes := deepRef 510 254, expect := ok1 (deepRefValue 510) },
  { name := "a value 513 deep", env := deepEnv, tys := #[.var "T"], bytes := deepRef 511 254,
    expect := .failsWith "Recursion limit exceeded at depth 512" },
  { name := "a subtype check 513 deep", env := deepEnv, tys := #[.var "T"],
    bytes := deepRef 510 255, expect := .failsWith "Recursion limit exceeded at depth 512" },
  -- A chain of 10,000 table entries, the most that the table may have.
  { name := "a chain of 10,000 entries, 500 deep", env := constructEnv, tys := #[.var "Opt"],
    bytes := optChain 10000 500, expect := ok1 (someN 500) },
  { name := "a chain of 10,000 entries, 600 deep", env := constructEnv, tys := #[.var "Opt"],
    bytes := optChain 10000 600, expect := .failsWith "Recursion limit exceeded" },
  { name := "a chain of 10,000 entries, 600 deep, skipped", tys := #[], bytes := optChain 10000 600,
    expect := .failsWith "Recursion limit exceeded" },
  { name := "a table of 10,001 entries", tys := #[], bytes := optChain 10001 0,
    expect := .failsWith "type table size exceeded" },
  -- Wide records and many arguments, of values that take no bytes: each field costs fuel.
  { name := "a record of 15,000 null fields", tys := #[.record #[]], bytes := wideNulls 15000 1,
    expect := ok1 (.record #[]) },
  { name := "100 records of 15,000 null fields", tys := #[], bytes := wideNulls 15000 100,
    expect := .failsWith "Decoding cost exceeds the limit" },
  { name := "30,000 arguments", tys := #[.null], bytes := didl [0] ++ leb 30000 ++ times 30000 0x7f,
    expect := ok1 .null },
  -- Recursive types through records under `opt`, where every level's attempt fails late.
  { name := "nested failed attempts, 50 deep", env := attemptsEnv, tys := #[.var "E"],
    bytes := nestedAttempts 50, expect := ok1 none' },
  { name := "nested failed attempts, 250 deep", env := attemptsEnv, tys := #[.var "E"],
    bytes := nestedAttempts 250, expect := .failsWith "Decoding cost exceeds the limit" }
]

/-! ## decodeAny -/

/-- The id of the field `head` of `List`. -/
def headId : UInt32 := idlHash "head"

/-- The id of the field `tail` of `List`. -/
def tailId : UInt32 := idlHash "tail"

/-- Messages that `decodeAny` decodes at their own types, with the type table and the arguments,
each a type and a value, that it should give, or `none` if it should fail. -/
def anyCases : Array (String × ByteArray × Option (Array Ty × Array (Ty × Value))) := #[
  ("bool", blob r"DIDL\00\01\7e\01", some (#[], #[(.bool, .bool true)])),
  ("list", listBlob, some (
    #[.opt (.table 1), .record #[nfield headId .int, nfield tailId (.table 0)]],
    #[(.table 0, list [1, 2])])),
  ("future value", blob r"DIDL\01\67\03ABC\02\00\7e\05\00hello\01",
    some (#[.future (-25)], #[(.table 0, .reserved), (.bool, .bool true)])),
  ("blob", blob r"DIDL\01\6d\7b\01\00\02\01\02",
    some (#[.vec .nat8], #[(.table 0, .blob (bytes [1, 2]))])),
  ("func", blob r"DIDL\01\6a\01\71\01\7d\01\01\01\00\01\01\03\ca\ff\ee\03foo",
    some (#[func0 #[.text] #[.nat] #[.query]], #[(.table 0, .func caffee "foo")])),
  ("service", blob r"DIDL\02\6a\01\71\01\7d\00\69\01\03foo\00\01\01\01\03\ca\ff\ee",
    some (#[func0 #[.text] #[.nat], .service #[method "foo" (.table 0)]],
      #[(.table 1, .service caffee)])),
  ("variant", blob r"DIDL\01\6b\02\00\7f\01\7c\01\00\01\2a",
    some (#[.variant #[nfield 0 .null, nfield 1 .int]],
      #[(.table 0, .variant (.num 1) (.int 42))])),
  ("trailing bytes", blob r"DIDL\00\01\7e\01\00", none),
  ("empty", blob r"DIDL\00\01\6f", none),
  ("spacebomb", blob vecNull, none),
  ("bad bool", blob r"DIDL\00\01\7e\02", none)
]

/-- Runs `anyCases`, as `runCases` runs a group. -/
def runAny : IO (Nat × Nat) := do
  let mut passed := 0
  let mut failed := 0
  for (name, bytes, expected) in anyCases do
    let r := decodeAny bytes
    let good := match r, expected with
      | .ok (table, args), some (table', args') => table == table' && args == args'
      | .error _, none => true
      | _, _ => false
    if good then passed := passed + 1
    else
      failed := failed + 1
      let shown := match r with
        | .ok (table, args) =>
          let args := args.toList.map fun ((t : Ty), (v : Value)) => (t.toDid, v.toText)
          s!"ok {table.toList.map Ty.toDid} {args}"
        | .error e => s!"error {e}"
      IO.println s!"FAIL decodeAny: {name}: {shown}"
  IO.println s!"decodeAny: {passed} passed, {failed} failed"
  return (passed, failed)

/-! ## isSubtype -/

/-- Recursive definitions: streams and lists of `nat` and of `int`, two definitions that unfold
to the same type, functions and services that refer to them, and a name for a name. -/
def recEnv : TypeEnv := { defs := #[
  ("NatStream", .recordOf #[field "head" .nat, field "tail" (.var "NatStream")]),
  ("IntStream", .recordOf #[field "head" .int, field "tail" (.var "IntStream")]),
  ("NatList", .variantOf #[field "nil" .null,
    field "cons" (.recordOf #[field "head" .nat, field "tail" (.var "NatList")])]),
  ("IntList", .variantOf #[field "nil" .null,
    field "cons" (.recordOf #[field "head" .int, field "tail" (.var "IntList")])]),
  ("A", .tuple #[.var "B"]),
  ("B", .tuple #[.var "A"]),
  ("C", .tuple #[.var "C"]),
  ("Vec", .vec (.var "Vec")),
  ("F", func0 #[.var "IntList"] #[.var "NatList"]),
  ("G", func0 #[.var "NatList"] #[.var "IntList"]),
  ("S", .serviceOf #[method "f" (.var "F"), method "s" (func0 #[] #[.var "S"])]),
  ("T", .serviceOf #[method "s" (func0 #[] #[.var "T"])]),
  ("Alias", .var "NatStream")
]}

/-- `checkSubtype` of `NatList` and `IntList` in `recEnv`, within the given limits. -/
def checkLists (limits : Option SubtypeLimits) (assumed : TyPairSet := {}) : SubtypeResult :=
  checkSubtype recEnv #[] limits assumed (.var "NatList") (.var "IntList")

/-- Checks of the subtype relation: a name, what the check gave, and what it should give. -/
def subtypeUnits : Array (String × Bool × Bool) := #[
  ("nat <: int", isSubtype {} .nat .int, true),
  ("int </: nat", isSubtype {} .int .nat, false),
  ("nat8 </: nat", isSubtype {} .nat8 .nat, false),
  ("nat8 </: nat16", isSubtype {} .nat8 .nat16, false),
  ("empty <: text", isSubtype {} .empty .text, true),
  ("text <: reserved", isSubtype {} .text .reserved, true),
  ("reserved </: null", isSubtype {} .reserved .null, false),
  ("null <: reserved", isSubtype {} .null .reserved, true),
  ("service {} <: principal", isSubtype {} (.service #[]) .principal, true),
  ("principal </: service {}", isSubtype {} .principal (.service #[]), false),
  ("text <: opt nat (special opt rule)", isSubtype {} .text (.opt .nat), true),
  ("opt text <: opt nat (special opt rule)", isSubtype {} (.opt .text) (.opt .nat), true),
  ("vec nat <: vec int", isSubtype {} (.vec .nat) (.vec .int), true),
  ("vec int </: vec nat", isSubtype {} (.vec .int) (.vec .nat), false),
  ("record: width",
    isSubtype {} (.recordOf #[field "a" .nat, field "b" .text]) (.recordOf #[field "a" .int]),
    true),
  ("record: missing field", isSubtype {} (.record #[]) (.recordOf #[field "a" .nat]), false),
  ("record: missing opt field",
    isSubtype {} (.record #[]) (.recordOf #[field "a" (.opt .nat)]), true),
  ("record: field type",
    isSubtype {} (.recordOf #[field "a" .text]) (.recordOf #[field "a" .nat]), false),
  ("record: a name and its id",
    isSubtype {} (.record #[nfield (idlHash "a") .nat]) (.recordOf #[field "a" .nat]), true),
  ("variant: more cases expected",
    isSubtype {} (.variantOf #[field "a" .nat]) (.variantOf #[field "a" .int, field "b" .text]),
    true),
  ("variant: unknown case",
    isSubtype {} (.variantOf #[field "a" .nat, field "b" .text]) (.variantOf #[field "a" .int]),
    false),
  ("func: contra- and covariance",
    isSubtype {} (func0 #[.int] #[.nat]) (func0 #[.nat] #[.int]), true),
  ("func: argument", isSubtype {} (func0 #[.nat] #[]) (func0 #[.int] #[]), false),
  ("func: modes", isSubtype {} (func0 #[] #[] #[.query]) (func0 #[] #[]), false),
  ("func: same modes", isSubtype {} (func0 #[] #[] #[.query]) (func0 #[] #[] #[.query]), true),
  ("func: dropped argument, added result",
    isSubtype {} (func0 #[.nat] #[.nat, .text]) (func0 #[.nat, .opt .text] #[.nat]), true),
  ("service: more methods",
    isSubtype {} (.serviceOf #[method "a" (func0 #[] #[]), method "b" (func0 #[] #[])])
      (.serviceOf #[method "a" (func0 #[] #[])]),
    true),
  ("service: fewer methods",
    isSubtype {} (.serviceOf #[method "a" (func0 #[] #[])])
      (.serviceOf #[method "a" (func0 #[] #[]), method "b" (func0 #[] #[])]),
    false),
  ("NatStream <: IntStream", isSubtype recEnv (.var "NatStream") (.var "IntStream"), true),
  ("IntStream </: NatStream", isSubtype recEnv (.var "IntStream") (.var "NatStream"), false),
  ("NatList <: IntList", isSubtype recEnv (.var "NatList") (.var "IntList"), true),
  ("IntList </: NatList", isSubtype recEnv (.var "IntList") (.var "NatList"), false),
  ("A <: C (different unrolling)", isSubtype recEnv (.var "A") (.var "C"), true),
  ("C <: A", isSubtype recEnv (.var "C") (.var "A"), true),
  ("F <: G (recursive arguments and results)", isSubtype recEnv (.var "F") (.var "G"), true),
  ("G </: F", isSubtype recEnv (.var "G") (.var "F"), false),
  ("S <: T (recursive services)", isSubtype recEnv (.var "S") (.var "T"), true),
  ("T </: S", isSubtype recEnv (.var "T") (.var "S"), false),
  ("alias", isSubtype recEnv (.var "Alias") (.var "IntStream"), true),
  ("table <: var", isSubtype recEnv (.table 0) (.var "Vec") #[.vec (.table 0)], true),
  ("table <: var, two entries",
    isSubtype recEnv (.table 0) (.var "Vec") #[.vec (.table 1), .vec (.table 0)], true),
  ("table </: var", isSubtype recEnv (.table 0) (.var "NatStream") #[.vec (.table 0)], false),
  ("unbound name", isSubtype {} (.var "X") .nat, false),
  ("unbound name, itself", isSubtype {} (.var "X") (.var "X"), true),
  ("index out of range", isSubtype {} (.table 3) .nat #[.vec .nat], false),
  ("future <: reserved", isSubtype {} (.future (-25)) .reserved, true),
  ("future </: nat", isSubtype {} (.future (-25)) .nat, false),
  -- The limits. `matches` tests a value against a pattern, here a constructor of `SubtypeResult`.
  ("depth limit", match checkLists (some { maxDepth := 3, fuel := 1000 }) with
    | .exceeded m => contains m "Recursion limit"
    | _ => false, true),
  ("fuel limit", match checkLists (some { maxDepth := 100, fuel := 3 }) with
    | .exceeded m => contains m "Decoding cost"
    | _ => false, true),
  ("within limits", match checkLists (some { maxDepth := 100, fuel := 1000 }) with
    | .holds _ steps => steps > 0
    | _ => false, true),
  ("assumptions carry over", match checkLists none with
    | .holds assumed _ => (checkLists none assumed matches .holds _ 1)
    | _ => false, true)
]

/-- Runs `subtypeUnits`, as `runCases` runs a group. -/
def runSubtypeUnits : IO (Nat × Nat) := do
  let mut passed := 0
  let mut failed := 0
  for (name, got, expected) in subtypeUnits do
    if got == expected then passed := passed + 1
    else
      failed := failed + 1
      IO.println s!"FAIL isSubtype: {name}: got {got}"
  IO.println s!"isSubtype: {passed} passed, {failed} failed"
  return (passed, failed)

/-! ## TyPairSet -/

/-- Puts 1000 pairs into a `TyPairSet`, which makes its buckets double several times, and checks
that it holds them, and not others. -/
def runPairSet : IO (Nat × Nat) := do
  let n := 1000
  let mut s : TyPairSet := {}
  for i in [0:n] do
    s := s.insert (.table i) (.var s!"x{i % 7}")
  let mut ok := s.size == n
  for i in [0:n] do
    ok := ok && s.contains (.table i) (.var s!"x{i % 7}") && !s.contains (.table i) (.var s!"y{i}")
  IO.println s!"TyPairSet: {if ok then "1 passed, 0 failed" else "0 passed, 1 failed"}"
  return if ok then (1, 0) else (0, 1)

/-- Runs the groups, prints a summary, and returns the exit code: 0 if all cases pass, else 1. The
program takes no arguments; the `_` at the start of `_args` tells Lean that it is unused on
purpose. -/
def main (_args : List String) : IO UInt32 := do
  let groups : Array (String × Array Case) := #[("prim", prim), ("construct", construct),
    ("reference", reference), ("subtypes", subtypes), ("spacebomb", spacebomb),
    ("overshoot", overshoot), ("limits", limits), ("hostile", hostile)]
  let mut passed := 0
  let mut failed := 0
  for (name, cases) in groups do
    let (p, f) ← runCases name cases
    passed := passed + p
    failed := failed + f
  for run in [runAny, runSubtypeUnits, runPairSet] do
    let (p, f) ← run
    passed := passed + p
    failed := failed + f
  IO.println s!"decode tests: {passed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
