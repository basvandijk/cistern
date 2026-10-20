import Candid

/-!
Tests of the encoder, `Candid.encodeValues` and `Candid.encode`: the message that each writes for
types and values, byte for byte, and the errors that it reports. The expected bytes come from:

- [rust] the Rust crate's tests, rust/candid/tests/serde.rs (`all_check`, which encodes with the
  Rust crate and compares) and rust/candid_parser/tests/value.rs (`check`);
- [suite] the conformance suite, test/*.test.did, where a message is given with the value that it
  decodes to, and its type table is in the order in which the Rust encoder writes it;
- [derived] bytes worked out by hand from the spec, for cases that the others do not cover.

This is a program, not a `module`. It runs with `lean --run Candid/Tests/Encode.lean`, with
`LEAN_PATH` on the library's `.olean` files, and the Nix checks also compile it to wasm32, whose
output must be the same. It prints a line per case and a summary, and returns 1 if a case fails.
-/

open Candid

/-! ## Helpers -/

/-- The value of a hexadecimal digit, `0`-`9`, `a`-`f` or `A`-`F`. -/
def hexDigit (c : Char) : UInt8 :=
  if c.isDigit then (c.toNat - '0'.toNat).toUInt8 else (c.toLower.toNat - 'a'.toNat + 10).toUInt8

/-- The bytes of a text of hexadecimal digits, two per byte, such as `"4449444c"`; spaces are
ignored. `go` is a helper, defined after `where`, which takes the characters two at a time: the
pattern `a :: b :: rest` matches a list of at least two elements. -/
def hex (s : String) : ByteArray :=
  go (s.toList.filter (· != ' ')) .empty
where
  go : List Char → ByteArray → ByteArray
    | a :: b :: rest, out => go rest (out.push (hexDigit a * 16 + hexDigit b))
    | _, out => out

/-- The bytes of a blob literal of the conformance suite, `DIDL\00\01\7e\01`: `\HH` is the byte
`HH` in hexadecimal, and any other character stands for its UTF-8. The literals below are Lean's
raw strings, `r"…"`, in which `\` is an ordinary character, so they read as in the suite. -/
def blob (s : String) : ByteArray :=
  go s.toList .empty
where
  go : List Char → ByteArray → ByteArray
    | '\\' :: a :: b :: rest, out => go rest (out.push (hexDigit a * 16 + hexDigit b))
    | c :: rest, out => go rest (out ++ c.toString.toUTF8)
    | [], out => out

/-- Bytes as hexadecimal digits, a byte at a time: `44 49 44 4c`. -/
def toHex (b : ByteArray) : String := " ".intercalate (b.toList.map fun x => hexDigits x.toNat)

/-- `n` copies of `b`, one after the other. -/
def repeatBytes (b : ByteArray) (n : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  for _ in [0:n] do
    out := out ++ b
  return out

/-- A field or case with a name. -/
def field (name : String) (t : Ty) : Field := ⟨.name name, t⟩

/-- A record type with named fields, which `Ty.recordOf` sorts by id. -/
def recordTy (fields : List (String × Ty)) : Ty :=
  .recordOf (fields.toArray.map fun (n, t) => field n t)

/-- A variant type with named cases, sorted by id. -/
def variantTy (cases : List (String × Ty)) : Ty :=
  .variantOf (cases.toArray.map fun (n, t) => field n t)

/-- A tuple type, `record { t₀; t₁; … }`. -/
def tupleTy (tys : List Ty) : Ty := .tuple tys.toArray

/-- A record value with named fields, in the order given, which need not be the type's. -/
def recordV (fields : List (String × Value)) : Value :=
  .record (fields.toArray.map fun (n, v) => (.name n, v))

/-- A tuple value, `record { v₀; v₁; … }`. -/
def tupleV (vs : List Value) : Value := .record (vs.toArray.mapIdx fun i v => (.num i.toUInt32, v))

/-- A variant value: the case `name`, with `null` as its value unless another is given. -/
def caseV (name : String) (v : Value := .null) : Value := .variant (.name name) v

/-- `opt v`. -/
def some' (v : Value) : Value := .opt (some v)

/-- `null` at an `opt` type, the option without a value. -/
def none' : Value := .opt none

/-- The principal `w7x7r-cok77-xa`, of the bytes `ca ff ee`. `⟨⟨#[…]⟩⟩` builds the structure
`Principal` around a `ByteArray` around an `Array UInt8`: the anonymous constructor `⟨…⟩` stands
for the one constructor of the expected type. -/
def caffee : Principal := ⟨⟨#[0xca, 0xff, 0xee]⟩⟩

/-- The principal `aaaaa-aa`, of no bytes, the management canister's. -/
def management : Principal := ⟨.empty⟩

/-- The principal `2chl6-4hpzw-vqaaa-aaaaa-c`, of nine bytes. -/
def principal2chl6 : Principal := ⟨⟨#[0xef, 0xcd, 0xab, 0, 0, 0, 0, 0, 1]⟩⟩

/-- A function type, `func (args) -> (rets) modes`. -/
def func (args rets : List Ty) (modes : List FuncMode := []) : Ty :=
  .func args.toArray rets.toArray modes.toArray

/-! ## The type definitions of construct.test.did -/

/-- `opt record { head : int; tail : List }`. -/
def listTy : Ty := .opt (recordTy [("head", .int), ("tail", .var "List")])

/-- The type definitions of construct.test.did, which some cases refer to with `.var`. -/
def constructEnv : TypeEnv := { defs := #[
  ("Opt", .opt (.var "Opt")),
  ("Vec", .vec (.var "Vec")),
  ("EmptyRecord", tupleTy [.var "EmptyRecord"]),
  ("List", listTy),
  ("List1", .opt (.var "List2")),
  ("List2", recordTy [("head", .int), ("tail", .var "List1")]),
  ("VariantList", variantTy [("nil", .null),
    ("cons", recordTy [("head", .int), ("tail", .var "VariantList")])]),
  ("A1", recordTy [("foo", .int32), ("bar", .bool)]),
  ("A2", recordTy [("foo", .int32), ("bar", .bool), ("bat", .var "VariantList"),
    ("baz", .var "A1"), ("bbb", .var "List"), ("bib", variantTy [("foo", .null), ("bar", .null)]),
    ("bab", .var "A1")])
] }

/-- `opt record { head = 1; tail = opt record { head = 2; … } }` of the numbers `ns`, a value of
`List`. -/
def listV : List Int → Value
  | [] => none'
  | n :: ns => some' (recordV [("head", .int n), ("tail", listV ns)])

/-- `variant { cons = record { head = 1; tail = variant { … } } }` of the numbers `ns`, a value
of `VariantList`. -/
def variantListV : List Int → Value
  | [] => caseV "nil"
  | n :: ns => caseV "cons" (recordV [("head", .int n), ("tail", variantListV ns)])

/-! ## Cases -/

/-- A case: a name, the encoding to check, and what it should give. -/
structure Case where
  name : String
  /-- The encoding, a function of `()`, so that it is computed when the case is checked rather
  than when the list of cases is built. -/
  run : Unit → Except Error ByteArray
  /-- The message, or a part of the error message. -/
  expected : Except String ByteArray

/-- A case of `encodeValues` that should give the message `bytes`. -/
def ok (name : String) (args : Array (Ty × Value)) (bytes : ByteArray) (env : TypeEnv := {}) :
    Case :=
  { name, run := fun _ => encodeValues env args, expected := .ok bytes }

/-- A case of `encodeValues` that should fail with an error whose text contains `part`. -/
def err (name : String) (args : Array (Ty × Value)) (part : String) (env : TypeEnv := {}) : Case :=
  { name, run := fun _ => encodeValues env args, expected := .error part }

/-- A case of the typed layer, `Candid.encode`, which calls `encodeValues {}`. -/
def typed (name : String) (run : Unit → Except Error ByteArray) (bytes : ByteArray) : Case :=
  { name, run, expected := .ok bytes }

/-- A message of one argument of a primitive type: `DIDL 00 01 <opcode> <value>`. -/
def prim (name : String) (t : Ty) (v : Value) (bytes : ByteArray) : Case := ok name #[(t, v)] bytes

/-- Messages of primitive types: the opcodes, LEB128 and SLEB128 numbers at their edges,
little-endian fixed-width numbers, float bits, UTF-8 text and principals. -/
def primitiveCases : Array Case := #[
  prim "[suite] (true) : (bool)" .bool (.bool true) (blob r"DIDL\00\01\7e\01"),
  prim "[suite] (false) : (bool)" .bool (.bool false) (blob r"DIDL\00\01\7e\00"),
  prim "[suite] (null) : (null)" .null .null (blob r"DIDL\00\01\7f"),
  ok "[suite] () : ()" #[] (blob r"DIDL\00\00"),
  prim "[suite] nat 0" .nat (.nat 0) (blob r"DIDL\00\01\7d\00"),
  prim "[suite] nat 127" .nat (.nat 127) (blob r"DIDL\00\01\7d\7f"),
  prim "[suite] nat 128" .nat (.nat 128) (blob r"DIDL\00\01\7d\80\01"),
  prim "[suite] nat 16383" .nat (.nat 16383) (blob r"DIDL\00\01\7d\ff\7f"),
  prim "[suite] nat 60000000000000000" .nat (.nat 60000000000000000)
    (blob r"DIDL\00\01\7d\80\80\98\f4\e9\b5\ca\6a"),
  prim "[rust] nat 5_000_000_000" .nat (.nat 5000000000) (hex "4449444c00017d80e497d012"),
  prim "[derived] nat 2^64 - 1" .nat (.nat (2 ^ 64 - 1))
    (hex "4449444c00017d" ++ repeatBytes (hex "ff") 9 ++ hex "01"),
  prim "[derived] nat 2^64" .nat (.nat (2 ^ 64))
    (hex "4449444c00017d" ++ repeatBytes (hex "80") 9 ++ hex "02"),
  prim "[derived] nat 2^100" .nat (.nat (2 ^ 100))
    (hex "4449444c00017d" ++ repeatBytes (hex "80") 14 ++ hex "04"),
  -- Numbers of more than 64 bits are written in halves, and halves of halves: these have bits
  -- that are set at both ends and in the middle. The bytes were computed with Python.
  prim "[derived] nat 2^700" .nat (.nat (2 ^ 700))
    (hex "4449444c00017d" ++ repeatBytes (hex "80") 100 ++ hex "01"),
  prim "[derived] nat 2^1000 - 1" .nat (.nat (2 ^ 1000 - 1))
    (hex "4449444c00017d" ++ repeatBytes (hex "ff") 142 ++ hex "3f"),
  prim "[derived] nat 2^1000 + 2^500 + 3" .nat (.nat (2 ^ 1000 + 2 ^ 500 + 3))
    (hex "4449444c00017d83" ++ repeatBytes (hex "80") 70 ++ hex "88" ++ repeatBytes (hex "80") 70 ++
      hex "40"),
  prim "[suite] int 0" .int (.int 0) (blob r"DIDL\00\01\7c\00"),
  prim "[suite] int -1" .int (.int (-1)) (blob r"DIDL\00\01\7c\7f"),
  prim "[suite] int -64" .int (.int (-64)) (blob r"DIDL\00\01\7c\40"),
  prim "[suite] int 127" .int (.int 127) (blob r"DIDL\00\01\7c\ff\00"),
  prim "[suite] int 128" .int (.int 128) (blob r"DIDL\00\01\7c\80\01"),
  prim "[suite] int -128" .int (.int (-128)) (blob r"DIDL\00\01\7c\80\7f"),
  prim "[derived] int 64" .int (.int 64) (blob r"DIDL\00\01\7c\c0\00"),
  prim "[derived] int -65" .int (.int (-65)) (blob r"DIDL\00\01\7c\bf\7f"),
  prim "[rust] int 1_234_567_890" .int (.int 1234567890) (hex "4449444c00017cd285d8cc04"),
  prim "[rust] int -1_234_567_890" .int (.int (-1234567890)) (hex "4449444c00017caefaa7b37b"),
  prim "[suite] int 60000000000000000" .int (.int 60000000000000000)
    (blob r"DIDL\00\01\7c\80\80\98\f4\e9\b5\ca\ea\00"),
  prim "[suite] int -60000000000000000" .int (.int (-60000000000000000))
    (blob r"DIDL\00\01\7c\80\80\e8\8b\96\ca\b5\95\7f"),
  prim "[derived] int 2^63" .int (.int (2 ^ 63))
    (hex "4449444c00017c" ++ repeatBytes (hex "80") 9 ++ hex "01"),
  prim "[derived] int -2^63" .int (.int (-2 ^ 63))
    (hex "4449444c00017c" ++ repeatBytes (hex "80") 9 ++ hex "7f"),
  prim "[derived] int 2^100" .int (.int (2 ^ 100))
    (hex "4449444c00017c" ++ repeatBytes (hex "80") 14 ++ hex "04"),
  prim "[derived] int -2^100" .int (.int (-2 ^ 100))
    (hex "4449444c00017c" ++ repeatBytes (hex "80") 14 ++ hex "7c"),
  prim "[derived] int 2^700" .int (.int (2 ^ 700))
    (hex "4449444c00017c" ++ repeatBytes (hex "80") 100 ++ hex "01"),
  prim "[derived] int -2^700" .int (.int (-2 ^ 700))
    (hex "4449444c00017c" ++ repeatBytes (hex "80") 100 ++ hex "7f"),
  prim "[derived] int 2^1000 - 1" .int (.int (2 ^ 1000 - 1))
    (hex "4449444c00017c" ++ repeatBytes (hex "ff") 142 ++ hex "3f"),
  prim "[derived] int -(2^1000 - 1)" .int (.int (-(2 ^ 1000 - 1)))
    (hex "4449444c00017c81" ++ repeatBytes (hex "80") 141 ++ hex "40"),
  prim "[derived] int -2^1000 - 2^500 - 3" .int (.int (-2 ^ 1000 - 2 ^ 500 - 3))
    (hex "4449444c00017cfd" ++ repeatBytes (hex "ff") 70 ++ hex "f7" ++ repeatBytes (hex "ff") 70 ++
      hex "bf7f"),
  prim "[suite] nat8 255" .nat8 (.nat8 255) (blob r"DIDL\00\01\7b\ff"),
  prim "[suite] nat16 256" .nat16 (.nat16 256) (blob r"DIDL\00\01\7a\00\01"),
  prim "[suite] nat16 65535" .nat16 (.nat16 65535) (blob r"DIDL\00\01\7a\ff\ff"),
  prim "[suite] nat32 256" .nat32 (.nat32 256) (blob r"DIDL\00\01\79\00\01\00\00"),
  prim "[suite] nat32 4294967295" .nat32 (.nat32 4294967295)
    (blob r"DIDL\00\01\79\ff\ff\ff\ff"),
  prim "[suite] nat64 4294967295" .nat64 (.nat64 4294967295)
    (blob r"DIDL\00\01\78\ff\ff\ff\ff\00\00\00\00"),
  prim "[suite] nat64 2^64 - 1" .nat64 (.nat64 18446744073709551615)
    (blob r"DIDL\00\01\78\ff\ff\ff\ff\ff\ff\ff\ff"),
  prim "[rust] nat64 42" .nat64 (.nat64 42) (hex "4449444c0001782a00000000000000"),
  prim "[suite] int8 -1" .int8 (.int8 (-1)) (blob r"DIDL\00\01\77\ff"),
  prim "[rust] int8 42" .int8 (.int8 42) (hex "4449444c0001772a"),
  prim "[suite] int16 256" .int16 (.int16 256) (blob r"DIDL\00\01\76\00\01"),
  prim "[suite] int16 -1" .int16 (.int16 (-1)) (blob r"DIDL\00\01\76\ff\ff"),
  prim "[suite] int32 65535" .int32 (.int32 65535) (blob r"DIDL\00\01\75\ff\ff\00\00"),
  prim "[suite] int32 -1" .int32 (.int32 (-1)) (blob r"DIDL\00\01\75\ff\ff\ff\ff"),
  prim "[suite] int64 4294967295" .int64 (.int64 4294967295)
    (blob r"DIDL\00\01\74\ff\ff\ff\ff\00\00\00\00"),
  prim "[suite] int64 -1" .int64 (.int64 (-1)) (blob r"DIDL\00\01\74\ff\ff\ff\ff\ff\ff\ff\ff"),
  prim "[rust] int64 -42" .int64 (.int64 (-42)) (hex "4449444c000174d6ffffffffffffff"),
  prim "[suite] float32 0" .float32 (.float32 0) (blob r"DIDL\00\01\73\00\00\00\00"),
  prim "[suite] float32 3" .float32 (.float32 3) (blob r"DIDL\00\01\73\00\00\40\40"),
  prim "[suite] float32 0.5" .float32 (.float32 0.5) (blob r"DIDL\00\01\73\00\00\00\3f"),
  prim "[suite] float32 -0.5" .float32 (.float32 (-0.5)) (blob r"DIDL\00\01\73\00\00\00\bf"),
  -- Lean's `Float32.ofBits` and `toBits` turn every NaN into the canonical one, 0x7fc00000, so a
  -- NaN's payload and sign cannot be written.
  prim "[derived] float32 NaN with a payload is the canonical NaN" .float32
    (.float32 (Float32.ofBits 0x7fc00001)) (blob r"DIDL\00\01\73\00\00\c0\7f"),
  prim "[derived] float32 -0" .float32 (.float32 (Float32.ofBits 0x80000000))
    (blob r"DIDL\00\01\73\00\00\00\80"),
  prim "[suite] float64 3" .float64 (.float64 3) (blob r"DIDL\00\01\72\00\00\00\00\00\00\08\40"),
  prim "[suite] float64 0.5" .float64 (.float64 0.5)
    (blob r"DIDL\00\01\72\00\00\00\00\00\00\e0\3f"),
  prim "[suite] float64 -0.5" .float64 (.float64 (-0.5))
    (blob r"DIDL\00\01\72\00\00\00\00\00\00\e0\bf"),
  prim "[rust] float64 6" .float64 (.float64 6) (hex "4449444c0001720000000000001840"),
  -- The suite's NaN, 0x7ff0000000000001, decodes to a NaN, which is written as the canonical NaN
  -- 0x7ff8000000000000 (Rust's `f64::NAN`): Lean's `Float.ofBits` and `toBits` keep no payload.
  prim "[derived] float64 NaN with a payload is the canonical NaN" .float64
    (.float64 (Float.ofBits 0x7ff0000000000001)) (blob r"DIDL\00\01\72\00\00\00\00\00\00\f8\7f"),
  prim "[derived] float64 negative NaN is the canonical NaN" .float64
    (.float64 (Float.ofBits 0xfff8000000000000)) (blob r"DIDL\00\01\72\00\00\00\00\00\00\f8\7f"),
  prim "[derived] float64 -0" .float64 (.float64 (-0.0))
    (blob r"DIDL\00\01\72\00\00\00\00\00\00\00\80"),
  prim "[derived] float64 infinity" .float64 (.float64 (1 / 0))
    (blob r"DIDL\00\01\72\00\00\00\00\00\00\f0\7f"),
  prim "[suite] float64 max value" .float64 (.float64 (Float.ofBits 0x7fefffffffffffff))
    (blob r"DIDL\00\01\72\ff\ff\ff\ff\ff\ff\ef\7f"),
  prim "[suite] text empty" .text (.text "") (blob r"DIDL\00\01\71\00"),
  prim "[suite] text Motoko" .text (.text "Motoko") (blob r"DIDL\00\01\71\06Motoko"),
  prim "[suite] text ☃" .text (.text "☃") (blob r"DIDL\00\01\71\03\e2\98\83"),
  prim "[rust] text Hi ☃\\n" .text (.text "Hi ☃\n") (hex "4449444c00017107486920e298830a"),
  prim "[suite] text escapes" .text (.text "\t\n\r\"'\\")
    (blob r"DIDL\00\01\71\06\09\0A\0D\22\27\5C"),
  prim "[rust] reserved" .reserved .reserved (hex "4449444c000170"),
  prim "[suite] principal aaaaa-aa" .principal (.principal management)
    (blob r"DIDL\00\01\68\01\00"),
  prim "[suite] principal w7x7r-cok77-xa" .principal (.principal caffee)
    (blob r"DIDL\00\01\68\01\03\ca\ff\ee"),
  prim "[suite] principal 2chl6-4hpzw-vqaaa-aaaaa-c" .principal (.principal principal2chl6)
    (blob r"DIDL\00\01\68\01\09\ef\cd\ab\00\00\00\00\00\01"),
  ok "[suite] multiple arguments"
    #[(.null, .null), (.bool, .bool true), (.nat, .nat 42), (.int, .int 42), (.null, .null),
      (.reserved, .reserved), (.null, .null), (.nat8, .nat8 42), (.nat16, .nat16 42),
      (.nat32, .nat32 42)]
    (blob r"DIDL\00\0a\7f\7e\7d\7c\7f\70\7f\7b\7a\79\01\2a\2a\2a\2a\00\2a\00\00\00")
]

/-- Messages of composite types: options, vectors and blobs, records and tuples, variants, and
the sharing of type table entries between equal types. -/
def constructCases : Array Case := #[
  ok "[suite] opt int: null" #[(.opt .int, none')] (blob r"DIDL\01\6e\7c\01\00\00"),
  ok "[suite] opt int: 42" #[(.opt .int, some' (.int 42))] (blob r"DIDL\01\6e\7c\01\00\01\2a"),
  ok "[suite] opt opt int: 42" #[(.opt (.opt .int), some' (some' (.int 42)))]
    (blob r"DIDL\02\6e\01\6e\7c\01\00\01\01\2a"),
  ok "[rust] opt int32: none" #[(.opt .int32, none')] (hex "4449444c016e75010000"),
  ok "[suite] Opt (opt Opt): opt opt null" #[(.var "Opt", some' (some' none'))]
    (blob r"DIDL\01\6e\00\01\00\01\01\00") (env := constructEnv),
  ok "[suite] vec int: empty" #[(.vec .int, .vec #[])] (blob r"DIDL\01\6d\7c\01\00\00"),
  ok "[suite] vec int: 1, 2" #[(.vec .int, .vec #[.int 1, .int 2])]
    (blob r"DIDL\01\6d\7c\01\00\02\01\02"),
  ok "[rust] vec int: 0 to 3" #[(.vec .int, .vec #[.int 0, .int 1, .int 2, .int 3])]
    (hex "4449444c016d7c01000400010203"),
  ok "[suite] vec nat8 as a blob" #[(.blob, .blob ⟨#[1, 2]⟩)]
    (blob r"DIDL\01\6d\7b\01\00\02\01\02"),
  ok "[suite] vec nat8 as a vec of nat8" #[(.vec .nat8, .vec #[.nat8 1, .nat8 2])]
    (blob r"DIDL\01\6d\7b\01\00\02\01\02"),
  ok "[rust] blob 01 02 03 04" #[(.blob, .blob ⟨#[1, 2, 3, 4]⟩)]
    (hex "4449444c016d7b01000401020304"),
  ok "[suite] Vec (vec Vec): vec { vec {}; vec {} }" #[(.var "Vec", .vec #[.vec #[], .vec #[]])]
    (blob r"DIDL\01\6d\00\01\00\02\00\00") (env := constructEnv),
  ok "[rust] vec null of 1000" #[(.vec .null, .vec (Array.replicate 1000 .null))]
    (hex "4449444c016d7f0100e807"),
  ok "[rust] vec vec vec vec null"
    #[(.vec (.vec (.vec (.vec .null))), .vec #[.vec #[.vec #[.vec #[.null]]]])]
    (hex "4449444c046d016d026d036d7f010001010101"),
  ok "[rust] vec int32 (a set)" #[(.vec .int32, .vec #[.int32 1, .int32 2, .int32 3])]
    (hex "4449444c016d75010003010000000200000003000000"),
  ok "[rust] vec record { text; int32 } (a map)"
    #[(.vec (tupleTy [.text, .int32]), .vec #[tupleV [.text "a", .int32 1]])]
    (hex "4449444c026d016c0200710175010001016101000000"),
  ok "[suite] record {}" #[(.record #[], .record #[])] (blob r"DIDL\01\6c\00\01\00"),
  ok "[suite] three record {} share an entry"
    #[(.record #[], .record #[]), (.record #[], .record #[]), (.record #[], .record #[])]
    (blob r"DIDL\01\6c\00\03\00\00\00"),
  ok "[suite] record { 1 = 42 }" #[(.record #[⟨.num 1, .int⟩], .record #[(.num 1, .int 42)])]
    (blob r"DIDL\01\6c\01\01\7c\01\00\2a"),
  ok "[suite] record { 42; true } (a tuple)"
    #[(tupleTy [.int, .bool], tupleV [.int 42, .bool true])]
    (blob r"DIDL\01\6c\02\00\7c\01\7e\01\00\2a\01"),
  ok "[suite] record { foo = 42; bar = true }, fields matched by id"
    #[(recordTy [("foo", .int), ("bar", .bool)], recordV [("foo", .int 42), ("bar", .bool true)])]
    (blob r"DIDL\01\6c\02\d3\e3\aa\02\7e\86\8e\b7\02\7c\01\00\01\2a"),
  ok "[rust] record { bar = true; foo = 42 }, ids as numbers"
    #[(.record #[⟨.num 4895187, .bool⟩, ⟨.num 5097222, .int⟩],
      .record #[(.num 4895187, .bool true), (.num 5097222, .int 42)])]
    (hex "4449444c016c02d3e3aa027e868eb7027c0100012a"),
  ok "[derived] an unsorted record type is sorted"
    #[(.record #[field "foo" .int, field "bar" .bool],
      recordV [("bar", .bool true), ("foo", .int 42)])]
    (blob r"DIDL\01\6c\02\d3\e3\aa\02\7e\86\8e\b7\02\7c\01\00\01\2a"),
  ok "[suite] record { ☃ = null }" #[(recordTy [("☃", .null)], recordV [("☃", .null)])]
    (blob r"DIDL\01\6c\01\cd\84\b0\05\7f\01\00"),
  ok "[suite] record { record { record { record {} } } }"
    #[(tupleTy [tupleTy [tupleTy [.record #[]]]], tupleV [tupleV [tupleV [.record #[]]]])]
    (blob r"DIDL\04\6c\01\00\01\6c\01\00\02\6c\01\00\03\6c\00\01\00"),
  ok "[rust] record { foo : int; bar : bool; baz : A1 } (A11)"
    #[(recordTy [("foo", .int), ("bar", .bool),
        ("baz", recordTy [("foo", .int), ("bar", .bool)])],
      recordV [("foo", .int 42), ("bar", .bool true),
        ("baz", recordV [("foo", .int 10), ("bar", .bool false)])])]
    (hex "4449444c026c03d3e3aa027edbe3aa0201868eb7027c6c02d3e3aa027e868eb7027c010001000a2a"),
  ok "[rust] record { int; text } (a tuple)" #[(tupleTy [.int, .text], tupleV [.int 42, .text "💩"])]
    (hex "4449444c016c02007c017101002a04f09f92a9"),
  ok "[rust] record { a : int8; b : nat8 }"
    #[(recordTy [("a", .int8), ("b", .nat8)], recordV [("a", .int8 42), ("b", .nat8 42)])]
    (hex "4449444c016c026177627b01002a2a"),
  ok "[rust] record { \"1-2 + 3\" : int8; \"a-b\" : nat8 }"
    #[(recordTy [("1-2 + 3", .int8), ("a-b", .nat8)],
      recordV [("1-2 + 3", .int8 42), ("a-b", .nat8 42)])]
    (hex "4449444c016c02b684a7027bb493ee970d7701002a2a"),
  ok "[rust] record { g1 : int; g2 : bool }"
    #[(recordTy [("g1", .int), ("g2", .bool)], recordV [("g1", .int 42), ("g2", .bool true)])]
    (hex "4449444c016c02eab3017cebb3017e01002a01"),
  ok "[rust] two blob fields share an entry"
    #[(recordTy [("b", .blob), ("c", .blob)],
      recordV [("b", .blob ⟨#[1, 2, 3]⟩), ("c", .vec #[.nat8 1, .nat8 2, .nat8 3])])]
    (hex "4449444c026c02620163016d7b01000301020303010203"),
  ok "[rust] record { return : blob }"
    #[(recordTy [("return", .blob)], recordV [("return", .blob ⟨#[1, 2, 3]⟩)])]
    (hex "4449444c026c01b0c9b649016d7b010003010203"),
  ok "[suite] variant { 0 }" #[(.variant #[⟨.num 0, .null⟩], .variant (.num 0) .null)]
    (blob r"DIDL\01\6b\01\00\7f\01\00\00"),
  ok "[suite] variant { 1 } at variant { 0; 1 }"
    #[(.variant #[⟨.num 0, .null⟩, ⟨.num 1, .null⟩], .variant (.num 1) .null)]
    (blob r"DIDL\01\6b\02\00\7f\01\7f\01\00\01"),
  ok "[suite] variant { Bar } at variant { Foo; Bar }"
    #[(variantTy [("Foo", .null), ("Bar", .null)], caseV "Bar")]
    (blob r"DIDL\01\6b\02\b3\d3\c9\01\7f\e6\fd\d5\01\7f\01\00\00"),
  ok "[suite] variant { ☃ }" #[(variantTy [("☃", .null)], caseV "☃")]
    (blob r"DIDL\01\6b\01\cd\84\b0\05\7f\01\00\00"),
  ok "[suite] variant { Ok = \"good\" }"
    #[(variantTy [("Ok", .text), ("Err", .text)], caseV "Ok" (.text "good"))]
    (blob r"DIDL\01\6b\02\bc\8a\01\71\c5\fe\d2\01\71\01\00\00\04\67\6f\6f\64"),
  ok "[suite] variant { ok = \"good\" } with err : empty"
    #[(variantTy [("ok", .text), ("err", .empty)], caseV "ok" (.text "good"))]
    (blob r"DIDL\01\6b\02\9c\c2\01\71\e5\8e\b4\02\6f\01\00\00\04\67\6f\6f\64"),
  ok "[suite] variant { ok = \"good\" } with err : EmptyRecord"
    #[(variantTy [("ok", .text), ("err", .var "EmptyRecord")], caseV "ok" (.text "good"))]
    (blob r"DIDL\02\6b\02\9c\c2\01\71\e5\8e\b4\02\01\6c\01\00\01\01\00\00\04\67\6f\6f\64")
    (env := constructEnv),
  ok "[suite] variant { Bar = record { true; 42 } }"
    #[(variantTy [("Foo", .null), ("Bar", tupleTy [.bool, .int]),
        ("Baz", recordTy [("a", .int), ("b", .nat)])],
      caseV "Bar" (tupleV [.bool true, .int 42]))]
    (blob (r"DIDL\03\6b\03\b3\d3\c9\01\01\bb\d3\c9\01\02\e6\fd\d5\01\7f\6c\02\00\7e\01\7c\6c\02" ++
      r"\61\7c\62\7d\01\00\00\01\2a")),
  ok "[suite] variant { 0 } at variant { 0; 1; 4294967295 }"
    #[(.variant #[⟨.num 0, .null⟩, ⟨.num 1, .null⟩, ⟨.num 4294967295, .null⟩],
      .variant (.num 0) .null)]
    (blob r"DIDL\01\6b\03\00\7f\01\7f\ff\ff\ff\ff\0f\7f\01\00\00"),
  ok "[suite] variant { 1 = 42 } at variant { 0; 1 : int }"
    #[(.variant #[⟨.num 0, .null⟩, ⟨.num 1, .int⟩], .variant (.num 1) (.int 42))]
    (blob r"DIDL\01\6b\02\00\7f\01\7c\01\00\01\2a"),
  ok "[rust] variant { Ok : nat8; Err : empty }"
    #[(variantTy [("Ok", .nat8), ("Err", .empty)], caseV "Ok" (.nat8 1))]
    (hex "4449444c016b02bc8a017bc5fed2016f01000001"),
  ok "[rust] variant { A : record {}; B : record {}; C } shares record {}"
    #[(variantTy [("A", .record #[]), ("B", .record #[]), ("C", .null)], caseV "A" (.record #[]))]
    (hex "4449444c026b0341014201437f6c00010000"),
  ok "[rust] variant { \"1-2 + 3\" : int8; \"a-b\" : nat8 }"
    #[(variantTy [("1-2 + 3", .int8), ("a-b", .nat8)], caseV "1-2 + 3" (.int8 42))]
    (hex "4449444c016b02b684a7027bb493ee970d770100012a"),
  ok "[rust] variant { a; b }: b" #[(variantTy [("a", .null), ("b", .null)], caseV "b")]
    (hex "4449444c016b02617f627f010001"),
  ok "[rust] variant { return }" #[(variantTy [("return", .null)], caseV "return")]
    (hex "4449444c016b01b0c9b6497f010000"),
  ok "[rust] (42, opt 42, opt 1, opt 2) share opt int"
    #[(.int, .int 42), (.opt .int, some' (.int 42)), (.opt .int, some' (.int 1)),
      (.opt .int, some' (.int 2))]
    (hex "4449444c016e7c047c0000002a012a01010102"),
  ok "[rust] (vec record { int; text }, record { int; text }) share the record"
    #[(.vec (tupleTy [.int, .text]), .vec #[tupleV [.int 42, .text "text"]]),
      (tupleTy [.int, .text], tupleV [.int 42, .text "text"])]
    (hex "4449444c026d016c02007c0171020001012a04746578742a0474657874"),
  ok "[rust] vec record { int; text }"
    #[(.vec (tupleTy [.int, .text]), .vec #[tupleV [.int 42, .text "text"]])]
    (hex "4449444c026d016c02007c01710100012a0474657874")
]

/-- `record { 0 : record { 0 : nat }; 1 : record { 1 : nat }; … }` with `n` fields: `n + 1`
entries, so references to entries 64 and up take two bytes in SLEB128 (64 is `c0 00`). -/
def wideRecord (n : Nat) : Ty × Value :=
  (.tuple ((Array.range n).map fun i => .record #[⟨.num i.toUInt32, .nat⟩]),
   .record ((Array.range n).map fun i => (.num i.toUInt32, .record #[(.num i.toUInt32, .nat 0)])))

/-- The message of `wideRecord n`, for `n < 128`, worked out by hand. -/
def wideRecordBytes (n : Nat) : ByteArray := Id.run do
  let sleb (k : Nat) : ByteArray := if k < 64 then ⟨#[k.toUInt8]⟩ else ⟨#[(k ||| 0x80).toUInt8, 0]⟩
  let mut out := blob r"DIDL" ++ ⟨#[(n + 1).toUInt8, 0x6c, n.toUInt8]⟩
  for i in [0:n] do
    out := out ++ ⟨#[i.toUInt8]⟩ ++ sleb (i + 1)
  for i in [0:n] do
    out := out ++ ⟨#[0x6c, 1, i.toUInt8, 0x7d]⟩
  out := out ++ ⟨#[1, 0]⟩ ++ repeatBytes ⟨#[0]⟩ n
  return out

/-- `variant { 0; 1; …; n - 1 }`, for `128 ≤ n < 256`, and its case `k`. -/
def wideVariant (n k : Nat) : Ty × Value :=
  (.variant ((Array.range n).map fun i => ⟨.num i.toUInt32, .null⟩),
   .variant (.num k.toUInt32) .null)

/-- The message of `wideVariant n k`, worked out by hand. -/
def wideVariantBytes (n k : Nat) : ByteArray := Id.run do
  let leb (k : Nat) : ByteArray :=
    if k < 128 then ⟨#[k.toUInt8]⟩ else ⟨#[(k % 128 + 128).toUInt8, 1]⟩
  let mut out := blob r"DIDL\01\6b" ++ leb n
  for i in [0:n] do
    out := out ++ leb i ++ ⟨#[0x7f]⟩
  return out ++ ⟨#[1, 0]⟩ ++ leb k

/-- The header of a message of one `List` (construct.test.did), which the value's bytes follow. -/
def listHeader : ByteArray :=
  blob r"DIDL\02\6e\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00"

/-- The type table of a message of one `VariantList`, and its argument types. -/
def variantListHeader : String :=
  r"DIDL\02\6b\02\d1\a7\cf\02\7f\f1\f3\92\8e\04\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00"

/-- `List = record { head : int; tail : opt List }`, with the `opt` inside, as the Rust tests have
it. -/
def rustListEnv : TypeEnv :=
  { defs := #[("List", recordTy [("head", .int), ("tail", .opt (.var "List"))])] }

/-- Two types that refer to each other, as in the Rust tests. -/
def mutualEnv : TypeEnv :=
  { defs := #[("A", recordTy [("typeb", .opt (.var "B"))]),
      ("B", recordTy [("typea", .opt (.var "A"))])] }

/-- Messages of types defined in a `TypeEnv`: recursive and mutually recursive types, names for
primitive types and for names, and type tables of more than 64 entries. -/
def recursiveCases : Array Case := #[
  ok "[suite] List: null" #[(.var "List", listV [])] (listHeader ++ blob r"\00")
    (env := constructEnv),
  ok "[suite] List: 1, 2, 3, 4" #[(.var "List", listV [1, 2, 3, 4])]
    (listHeader ++ blob r"\01\01\01\02\01\03\01\04\00") (env := constructEnv),
  ok "[derived] List of 1000 elements" #[(.var "List", listV (List.replicate 1000 1))]
    (listHeader ++ repeatBytes (blob r"\01\01") 1000 ++ blob r"\00") (env := constructEnv),
  ok "[suite] List1 (opt List2), List2 (record with tail : List1)" #[(.var "List1", listV [1, 2])]
    (blob r"DIDL\02\6e\01\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\00\01\00\01\01\01\02\00")
    (env := constructEnv),
  ok "[suite] VariantList: nil" #[(.var "VariantList", variantListV [])]
    (blob (variantListHeader ++ r"\00")) (env := constructEnv),
  ok "[suite] VariantList: cons 1 (cons 2 nil)" #[(.var "VariantList", variantListV [1, 2])]
    (blob (variantListHeader ++ r"\01\01\01\02\00")) (env := constructEnv),
  ok "[suite] A2: nested records and variants, A1 twice, fields out of order"
    #[(.var "A2", recordV [("foo", .int32 42), ("bar", .bool true), ("bat", caseV "nil"),
      ("baz", recordV [("foo", .int32 10), ("bar", .bool false)]),
      ("bbb", some' (recordV [("head", .int 20), ("tail", none')])),
      ("bib", caseV "bar"), ("bab", recordV [("foo", .int32 11), ("bar", .bool true)])])]
    (blob (r"DIDL\07\6c\07\c3\e3\aa\02\01\d3\e3\aa\02\7e\d5\e3\aa\02\02\db\e3\aa\02\01\a2\e5" ++
      r"\aa\02\04\bb\f1\aa\02\06\86\8e\b7\02\75\6c\02\d3\e3\aa\02\7e\86\8e\b7\02\75\6b\02\d1" ++
      r"\a7\cf\02\7f\f1\f3\92\8e\04\03\6c\02\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\02\6e\05\6c\02" ++
      r"\a0\d2\ac\a8\04\7c\90\ed\da\e7\04\04\6b\02\d3\e3\aa\02\7f\86\8e\b7\02\7f\01\00\01\0b" ++
      r"\00\00\00\01\00\00\0a\00\00\00\01\14\00\00\2a\00\00\00"))
    (env := constructEnv),
  ok "[rust] List = record { head : int; tail : opt List }"
    #[(.var "List", recordV [("head", .int 42),
      ("tail", some' (recordV [("head", .int 43), ("tail", none')]))])]
    (hex "4449444c026c02a0d2aca8047c90eddae704016e0001002a012b00") (env := rustListEnv),
  -- The Rust derive's type for `Option<List>` is `opt record { head : int; tail : opt List }`
  -- with the inner `List` a "knot", not a name, so the two `opt`s differ and take three entries
  -- (4449444c036e016c02…026e0101 0000). Here both are `opt (var "List")`, one type, one entry,
  -- as in ser.rs for a `Var`.
  ok "[derived from ser.rs] opt List, with List = record { head : int; tail : opt List }"
    #[(.opt (.var "List"), none')] (hex "4449444c026e016c02a0d2aca8047c90eddae70400010000")
    (env := rustListEnv),
  ok "[rust] record { typeas : vec A }, A and B mutually recursive"
    #[(recordTy [("typeas", .vec (.var "A"))], recordV [("typeas", .vec #[])])]
    (hex "4449444c066c01acd4dbb905016d026c01e8e0add601036e046c01e7e0add601056e02010000")
    (env := mutualEnv),
  ok "[rust] B, A and B mutually recursive" #[(.var "B", recordV [("typea", none')])]
    (hex "4449444c046c01e7e0add601016e026c01e8e0add601036e00010000") (env := mutualEnv),
  ok "[derived] a name for a primitive type is its opcode"
    #[(.var "N", .nat 5), (.vec (.var "N"), .vec #[.nat 1])]
    (blob r"DIDL\01\6d\7d\02\7d\00\05\01\01") (env := { defs := #[("N", .nat)] }),
  ok "[derived] opt of a name for a primitive type" #[(.opt (.var "N"), some' (.nat 7))]
    (blob r"DIDL\01\6e\7d\01\00\01\07") (env := { defs := #[("N", .nat)] }),
  ok "[derived] one entry for a name used by two arguments"
    #[(.var "A1", recordV [("foo", .int32 1), ("bar", .bool true)]),
      (.var "A1", recordV [("bar", .bool false), ("foo", .int32 2)])]
    (blob r"DIDL\01\6c\02\d3\e3\aa\02\7e\86\8e\b7\02\75\02\00\00\01\01\00\00\00\00\02\00\00\00")
    (env := constructEnv),
  ok "[derived] a name for a name: A = B, B = opt A; an entry per name"
    #[(.var "A", none'), (.var "B", some' none')]
    (blob r"DIDL\02\6e\00\6e\00\02\00\01\00\01\00")
    (env := { defs := #[("A", .var "B"), ("B", .opt (.var "A"))] }),
  ok "[derived] 71 entries: references from 64 up take two bytes" #[wideRecord 70]
    (wideRecordBytes 70),
  ok "[derived] a variant of 200 cases: positions from 128 up take two bytes"
    #[wideVariant 200 150] (wideVariantBytes 200 150)
]

/-- Messages of service and function references. -/
def referenceCases : Array Case := #[
  ok "[suite] service {}" #[(.service #[], .service caffee)]
    (blob r"DIDL\01\69\00\01\00\01\03\ca\ff\ee"),
  ok "[rust] service { f : () -> (nat); g : () -> () query }"
    #[(.serviceOf #[⟨"g", func [] [] [.query]⟩, ⟨"f", func [] [.nat]⟩], .service caffee)]
    (hex "4449444c0369020166010167026a00017d006a0000010101000103caffee"),
  ok "[suite] service { \"🐂\" : (opt int) -> (record {}) query; foo : () -> () oneway }"
    #[(.serviceOf #[⟨"🐂", func [.opt .int] [.record #[]] [.query]⟩,
        ⟨"foo", func [] [] [.oneway]⟩],
      .service management)]
    (blob (r"DIDL\05i\02\03foo\01\04\f0\9f\90\82\02j\00\00\01\02j\01\03\01\04\01\01n|l\00" ++
      r"\01\00\01\00")),
  ok "[suite] func () -> ()" #[(func [] [], .func caffee "a")]
    (blob r"DIDL\01\6a\00\00\00\01\00\01\01\03\ca\ff\ee\01\61"),
  ok "[suite] func (int, nat) -> (service {}) query"
    #[(func [.int, .nat] [.service #[]] [.query], .func management "🐂")]
    (blob r"DIDL\02j\02|}\01\01\01\01i\00\01\00\01\01\00\04\f0\9f\90\82"),
  ok "[suite] func (principal) -> (nat)" #[(func [.principal] [.nat], .func caffee "foo")]
    (blob r"DIDL\01\6a\01\68\01\7d\00\01\00\01\01\03\ca\ff\ee\03foo"),
  ok "[suite] func (text) -> (nat) query" #[(func [.text] [.nat] [.query], .func caffee "foo")]
    (blob r"DIDL\01\6a\01\71\01\7d\01\01\01\00\01\01\03\ca\ff\ee\03foo"),
  ok "[suite] func (text) -> (nat) composite_query"
    #[(func [.text] [.nat] [.compositeQuery], .func caffee "foo")]
    (blob r"DIDL\01\6a\01\71\01\7d\01\03\01\00\01\01\03\ca\ff\ee\03foo"),
  ok "[rust] func () -> (nat)" #[(func [] [.nat], .func caffee "method")]
    (hex "4449444c016a00017d000100010103caffee066d6574686f64"),
  ok "[suite] func () -> (opt bool), as in subtypes.test.did"
    #[(func [] [.opt .bool], .func management "m")]
    (blob r"DIDL\02\6a\00\01\01\00\6e\7e\01\00\01\01\00\01m"),
  ok "[derived] a method type given by name" #[(.service #[⟨"m", .var "F"⟩], .service caffee)]
    (blob r"DIDL\02\69\01\01m\01\6a\00\00\00\01\00\01\03\ca\ff\ee")
    (env := { defs := #[("F", func [] [])] })
]

/-- Arguments that the encoder rejects, and a part of the error message of each. -/
def errorCases : Array Case := #[
  err "a value of type empty" #[(.empty, .null)] "type empty",
  err "a value of type empty in a record" #[(recordTy [("a", .empty)], recordV [("a", .null)])]
    "type empty",
  err "nat at int" #[(.int, .nat 5)] "expected a value of type int, got 5",
  err "int at nat" #[(.nat, .int 5)] "expected a value of type nat",
  err "nat8 at nat16" #[(.nat16, .nat8 5)] "expected a value of type nat16",
  err "null at opt" #[(.opt .nat, .null)] "expected a value of type opt nat",
  err "service at principal" #[(.principal, .service caffee)] "expected a value of type principal",
  err "blob at vec nat16" #[(.vec .nat16, .blob ⟨#[1]⟩)] "expected a value of type vec nat16",
  err "an element of the wrong type" #[(.vec .nat, .vec #[.nat 1, .int 2])]
    "expected a value of type nat",
  err "duplicate field ids" #[(.record #[⟨.num 1, .nat⟩, ⟨.num 1, .int⟩], .record #[])]
    "duplicate field id 1",
  err "duplicate field ids by name and number"
    #[(.record #[⟨.name "a", .nat⟩, ⟨.num 97, .int⟩], .record #[])] "duplicate field id 97",
  err "duplicate case ids"
    #[(.variant #[⟨.num 2, .null⟩, ⟨.num 2, .null⟩], .variant (.num 2) .null)]
    "duplicate field id 2",
  err "two function modes" #[(func [] [] [.query, .oneway], .func caffee "m")] "at most one mode",
  err "unbound name" #[(.var "Foo", .null)] "unbound type identifier Foo",
  err "unbound name inside a type" #[(.opt (.var "Foo"), none')] "unbound type identifier Foo",
  err "unbound name in a definition" #[(.var "A", none')] "unbound type identifier Bar"
    (env := { defs := #[("A", .opt (.var "Bar"))] }),
  err "cyclic names" #[(.var "A", .null)] "cyclic type definition"
    (env := { defs := #[("A", .var "B"), ("B", .var "A")] }),
  err "Ty.table in a type" #[(.opt (.table 3), none')] "table3",
  err "Ty.table as an argument type" #[(.table 0, .null)] "table0",
  err "Ty.table in a definition" #[(.var "X", .null)] "table0"
    (env := { defs := #[("X", .table 0)] }),
  err "a future type" #[(.vec (.future (-25)), .vec #[])] "future type",
  err "a name for a future type" #[(.var "F", .null)] "future type"
    (env := { defs := #[("F", .future (-30))] }),
  err "a name for empty" #[(.var "E", .null)] "type empty" (env := { defs := #[("E", .empty)] }),
  err "a record field missing" #[(recordTy [("a", .nat), ("b", .nat)], recordV [("a", .nat 1)])]
    "field b is missing",
  err "an extra record field"
    #[(recordTy [("a", .nat)], recordV [("a", .nat 1), ("c", .nat 2)])]
    "field c is not in the type",
  err "a record field twice"
    #[(recordTy [("a", .nat), ("b", .nat)],
      recordV [("a", .nat 1), ("a", .nat 1), ("b", .nat 2)])]
    "twice",
  err "a variant case not in the type" #[(variantTy [("a", .null)], caseV "b")]
    "variant case b is not in the type",
  err "a case of an empty variant" #[(.variant #[], caseV "a")]
    "variant case a is not in the type",
  err "a principal of 30 bytes" #[(.principal, .principal ⟨⟨Array.replicate 30 1⟩⟩)]
    "at most 29 bytes",
  err "a method that is not a function" #[(.service #[⟨"m", .nat⟩], .service caffee)]
    "not a function type",
  err "a method named by a non-function" #[(.service #[⟨"m", .var "N"⟩], .service caffee)]
    "not a function type" (env := { defs := #[("N", .opt .nat)] }),
  err "two methods of the same name"
    #[(.service #[⟨"m", func [] []⟩, ⟨"m", func [.nat] []⟩], .service caffee)]
    "duplicate method name"
]

/-- Cases of `Candid.encode`, which finds the types of the arguments through `CandidArgs`, from
the Lean types of the values: `(3 : Nat)` says which type the number `3` has. -/
def typedCases : Array Case := #[
  typed "[suite] encode ()" (fun _ => Candid.encode ()) (blob r"DIDL\00\00"),
  typed "[suite] encode true" (fun _ => Candid.encode true) (blob r"DIDL\00\01\7e\01"),
  -- A `()` in a product is the value `null`, first or last: only `()` alone is no arguments.
  typed "[derived] encode ((), 5)" (fun _ => Candid.encode ((), (5 : Nat)))
    (blob r"DIDL\00\02\7f\7d\05"),
  typed "[derived] encode (5, ())" (fun _ => Candid.encode ((5 : Nat), ()))
    (blob r"DIDL\00\02\7d\7f\05"),
  typed "[derived] encode ((), ())" (fun _ => Candid.encode ((), ())) (blob r"DIDL\00\02\7f\7f"),
  typed "[derived] encode (\"world\", 3, none)"
    (fun _ => Candid.encode ("world", (3 : Nat), (none : Option Nat)))
    (blob r"DIDL\01\6e\7d\03\71\7d\00\05world\03\00"),
  typed "[rust] encode (.ok 1 : Except Empty UInt8)"
    (fun _ => Candid.encode (Except.ok 1 : Except Empty UInt8))
    (hex "4449444c016b02bc8a017bc5fed2016f01000001"),
  typed "[rust] encode (#[1, 2, 3] : Array UInt8)"
    (fun _ => Candid.encode (#[1, 2, 3] : Array UInt8))
    (hex "4449444c016d7b010003010203"),
  typed "[rust] encode (a ByteArray)" (fun _ => Candid.encode (ByteArray.mk #[1, 2, 3]))
    (hex "4449444c016d7b010003010203"),
  typed "[rust] encode (-42 : Int64)" (fun _ => Candid.encode (-42 : Int64))
    (hex "4449444c000174d6ffffffffffffff"),
  typed "[rust] encode (some (some (42 : Int)))" (fun _ => Candid.encode (some (some (42 : Int))))
    (hex "4449444c026e016e7c010001012a")
]

/-- All the cases, in the order in which they are checked. -/
def cases : Array Case :=
  primitiveCases ++ constructCases ++ recursiveCases ++ referenceCases ++ errorCases ++ typedCases

/-! ## Running the cases -/

/-- Checks a case and prints a line about it: `ok` or `FAIL`, with what went wrong. Returns whether
it passed. `IO Bool` is the type of a computation that can do input and output, here print, and
then returns a `Bool`. `s!"… {x} …"` is an interpolated string, with `x` turned into text. -/
def check (c : Case) : IO Bool := do
  match c.run (), c.expected with
  | .ok bytes, .ok expected =>
    if bytes == expected then
      IO.println s!"ok   {c.name}"
      return true
    IO.println s!"FAIL {c.name}\n  expected {toHex expected}\n  got      {toHex bytes}"
    return false
  | .error e, .error part =>
    if (toString e).contains part then
      IO.println s!"ok   error: {c.name}: {e}"
      return true
    IO.println s!"FAIL error: {c.name}: expected an error with \"{part}\", got: {e}"
    return false
  | .ok bytes, .error part =>
    IO.println s!"FAIL error: {c.name}: expected an error with \"{part}\", got bytes {toHex bytes}"
    return false
  | .error e, .ok _ =>
    IO.println s!"FAIL {c.name}: {e}"
    return false

/-- Checks every case, prints a summary, and returns the exit code: 0 if all pass, else 1. The
program takes no arguments; the `_` at the start of `_args` tells Lean that it is unused on
purpose. -/
def main (_args : List String) : IO UInt32 := do
  let mut passed := 0
  let mut failed := 0
  for c in cases do
    if ← check c then passed := passed + 1 else failed := failed + 1
    -- Writes out what was printed, should the program fail after it.
    (← IO.getStdout).flush
  IO.println s!"encode tests: {passed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
