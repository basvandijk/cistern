import Candid

/-!
Tests of the text format (Candid/Parse.lean, and the printers `Ty.toDid`, `Ty.toDidCapped`,
`Interface.toDid` and `Value.toText`): the lexer, types, `.did` files, values and `annotate`, with
the results and the errors that they should give, the inputs of the Rust crate's own parser
tests, round trips of generated types, interfaces and values through their text, the quoting of
names, and hostile text, which must not take long.

With the arguments `--assets DIR`, where `DIR` is the Rust parser's test assets
(rust/candid_parser/tests/assets in dfinity/candid), it also parses each `.did` file there and
checks that it gives the interface of the Rust printer's output for it, `DIR/ok/X.did`, or fails if
there is an error for it, `DIR/ok/X.fail`. Without them it prints a line that says that these checks
were skipped. The Nix checks run them natively, but not on wasm32, whose program has no files to
read; they compare its output with that of a native run without them.

The conformance suite's values in the text format (test/*.test.did) are tested by
Candid/Conformance.lean, which parses and annotates them as part of each assertion.

This is a program, not a `module`. It runs with `lean --run Candid/Tests/Parse.lean`, with
`LEAN_PATH` on the library's `.olean` files. It prints a line per group of checks and one per check
that fails, then a summary, and returns 1 if a check fails.
-/

open Candid Candid.Parse

/-! ## Checks

Each group of checks below is a function of `()`, the value of type `Unit`, so that its checks are
computed when `main` runs the group, after the groups before it have printed their lines, rather
than all at once when the program starts, as a definition without arguments would be. -/

/-- A check: its name, and `none` if it passed, or `some` what went wrong. -/
structure Check where
  name : String
  failure : Option String

/-- A check that `ok` holds; `detail` says what went wrong if it does not. -/
def check (name : String) (ok : Bool) (detail : String := "") : Check :=
  { name, failure := if ok then none else some detail }

/-- A result as text, for the line of a check that fails. `{α}` makes the type `α` an implicit
argument, which Lean infers from `r`, and `[ToString α]` asks for a way to turn an `α` into text. -/
def showE {α} [ToString α] : Except Error α → String
  | .ok a => s!"ok {a}"
  | .error e => s!"error {e}"

/-- An interface as text, for `showE`. An `instance` gives a type class an implementation for a
type, as an `impl` of a trait does in Rust: here `ToString Interface`, so that `s!"{i}"` works. -/
instance : ToString Interface := ⟨Interface.toDid⟩

/-- Values as text, in the text format's parentheses: `(1, "a")`. -/
instance : ToString (Array Value) :=
  ⟨fun vs => "(" ++ ", ".intercalate (vs.toList.map Value.toText) ++ ")"⟩

/-- A `ByteArray` of these bytes. -/
def bytesOf (l : List Nat) : ByteArray := ⟨(l.map (·.toUInt8)).toArray⟩

/-- The tokens of a text, without their positions. -/
def tokens (s : String) : Except Error (Array Token) := do
  return (← lex s.toUTF8).map (·.token)

/-- Whether `r` succeeded with `want`. -/
def okIs {α} [BEq α] (r : Except Error α) (want : α) : Bool :=
  match r with
  | .ok a => a == want
  | .error _ => false

/-- Whether `r` failed. -/
def isErr {α} : Except Error α → Bool
  | .error _ => true
  | .ok _ => false

/-- The message of the error of `r`, or `""` if it succeeded. -/
def errMsg {α} : Except Error α → String
  | .error e => e.message
  | .ok _ => ""

/-- The byte offset of the error of `r`, if it failed and has one. -/
def errOffset {α} : Except Error α → Option Nat
  | .error e => e.offset
  | .ok _ => none

/-- Whether `sub` occurs in `s`: splitting `s` at it gives more than one piece. -/
def contains (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- That `r` failed with an error whose message contains `want`. -/
def checkError {α} [ToString α] (name : String) (r : Except Error α) (want : String) : Check :=
  check name (isErr r && contains (errMsg r) want) s!"got {showE r}"

/-- Values compared as `==` does, but floats by their bits, so that `-0.0` is not `0.0`. `partial`
lets the function call itself on the parts of a value without a proof that the recursion ends. -/
partial def bitsEq : Value → Value → Bool
  | .float32 a, .float32 b => a.toBits == b.toBits
  | .float64 a, .float64 b => a.toBits == b.toBits
  | .opt (some a), .opt (some b) => bitsEq a b
  | .vec as, .vec bs => as.size == bs.size && (as.zip bs).all fun (a, b) => bitsEq a b
  | .record as, .record bs =>
    as.size == bs.size && (as.zip bs).all fun ((l, a), (m, b)) => l == m && bitsEq a b
  | .variant l a, .variant m b => l == m && bitsEq a b
  | a, b => a == b

/-- Arrays of values compared with `bitsEq`. -/
def valuesEq (as bs : Array Value) : Bool :=
  as.size == bs.size && (as.zip bs).all fun (a, b) => bitsEq a b

/-! ## Generated types and values

A small pseudo-random generator, xorshift64, with a fixed seed, so that every run generates the
same types and values. `G` is the type of computations that use and update its state:
`StateM UInt64 α` takes the state, a `UInt64`, and returns an `α` and the next state. `UInt64`
arithmetic wraps around, as the generator needs. -/

/-- The next state of the generator: xorshift64. -/
def nextRand (s : UInt64) : UInt64 :=
  let s := s ^^^ (s <<< 13)
  let s := s ^^^ (s >>> 7)
  s ^^^ (s <<< 17)

/-- Computations that draw pseudo-random numbers. -/
abbrev G := StateM UInt64

/-- A number below `n` (0 if `n` is 0). `set s` replaces the state with `s`. -/
def rand (n : Nat) : G Nat := do
  let s := nextRand (← get)
  set s
  return if n == 0 then 0 else s.toNat % n

/-- An element of a non-empty array. `[Inhabited α]` gives `xs[i]!` a default value, should the
index be out of bounds. -/
def pick {α} [Inhabited α] (xs : Array α) : G α := do
  return xs[← rand xs.size]!

/-- Names, among them some that must be quoted: keywords, empty, with spaces, quotes, escapes,
control characters, emoji, and the starts of comments. -/
def names : Array String :=
  #["a", "b", "foo", "bar_baz", "_x", "A1", "☃", "a b", "", "nat", "record", "true", "false",
    "assert", "\"", "\\", "\n", "tab\t", "\x01", "🐂", "e2", "0", "12", "blob", "type", "x'y",
    "\x7f", "\ufe0f", "/*", "//"]

/-- Field ids for numeric labels: 0, the largest, 2^31, and the id of `"a"`. -/
def numbers : Array Nat := #[0, 1, 2, 3, 42, 4294967295, 2147483648, 97]

/-- The primitive types. -/
def prims : Array Ty :=
  #[.null, .bool, .nat, .int, .nat8, .nat16, .nat32, .nat64, .int8, .int16, .int32, .int64,
    .float32, .float64, .text, .reserved, .empty, .principal]

/-- A field label: a number a third of the time, else a name. -/
def genLabel : G Label := do
  if (← rand 3) == 0 then return .num (← pick numbers).toUInt32
  return .name (← pick names)

/-- The fields, without those whose id an earlier one has. -/
def dedupFields (fs : Array Field) : Array Field := Id.run do
  let mut out := #[]
  for f in fs do
    unless out.any (·.label.id == f.label.id) do out := out.push f
  return out

/-- The methods, without those whose name an earlier one has. -/
def dedupMethods (ms : Array Method) : Array Method := Id.run do
  let mut out := #[]
  for m in ms do
    unless out.any (·.name == m.name) do out := out.push m
  return out

mutual

/-- A type of at most `depth` levels, whose names, if any, are among `vars`. -/
partial def genTy (vars : Array String) (depth : Nat) : G Ty := do
  let k ← rand (if depth == 0 then 2 else 11)
  match k with
  | 0 => pick prims
  | 1 => if vars.isEmpty then pick prims else return .var (← pick vars)
  | 2 => return .opt (← genTy vars (depth - 1))
  | 3 => return .vec (← genTy vars (depth - 1))
  | 4 => return .blob
  | 5 | 6 =>
    let n ← rand 5
    let mut fs := #[]
    for _ in [0:n] do
      fs := fs.push { label := ← genLabel, ty := ← genTy vars (depth - 1) }
    if k == 5 then
      -- A third of the records are tuples.
      if (← rand 3) == 0 then return Ty.tuple (fs.map (·.ty))
      return Ty.recordOf (dedupFields fs)
    else
      let cases ← fs.mapM fun f => do
        if (← rand 3) == 0 then return { f with ty := .null } else return f
      return Ty.variantOf (dedupFields cases)
  | 7 => genFunc vars depth
  | 8 =>
    let n ← rand 4
    let mut ms := #[]
    for _ in [0:n] do
      let ty ← if (← rand 4) == 0 && !vars.isEmpty then pure (Ty.var (← pick vars))
        else genFunc vars (depth - 1)
      ms := ms.push { name := ← pick names, ty }
    return Ty.serviceOf (dedupMethods ms)
  | _ => pick prims

/-- A function type whose arguments and results have at most `depth - 1` levels. -/
partial def genFunc (vars : Array String) (depth : Nat) : G Ty := do
  let na ← rand 4
  let nr ← rand 3
  let mut args := #[]
  for _ in [0:na] do args := args.push (← genTy vars (depth - 1))
  let mut rets := #[]
  for _ in [0:nr] do rets := rets.push (← genTy vars (depth - 1))
  let m ← rand 5
  let modes : Array FuncMode := match m with
    | 0 => #[.query]
    | 1 => #[.compositeQuery]
    | 2 => if rets.isEmpty then #[.oneway] else #[]
    | _ => #[]
  return .func args rets modes

end

/-- Principals for generated values: no bytes, one, three, and the most, 29. -/
def principals : Array Principal :=
  #[Principal.managementCanister, Principal.anonymous, ⟨⟨#[0xca, 0xff, 0xee]⟩⟩,
    ⟨⟨(List.range 29).toArray.map (·.toUInt8)⟩⟩]

/-- Floats that the text format writes exactly. -/
def exactFloats : Array Float := #[0.0, 1.5, -2.25, 3.0, 1e10, 0.5, -7.0, 123456.75]

/-- Whether a type has values that `genValue` can make: no `empty`, no `var`, no empty variant. -/
partial def valueType : Ty → Bool
  | .empty => false
  | .var _ => false
  | .opt _ => true
  | .vec _ => true
  | .record fs => fs.all (valueType ·.ty)
  | .variant cs => !cs.isEmpty && cs.all (valueType ·.ty)
  | _ => true

/-- A value of a type for which `valueType` holds, as the decoder would make it (a `blob` for a
`vec nat8`), nested at most `depth` levels in options and vectors. -/
partial def genValue (t : Ty) (depth : Nat) : G Value := do
  match t with
  | .null => return .null
  | .bool => return .bool ((← rand 2) == 0)
  | .nat => return .nat (← pick #[0, 1, 127, 128, 2 ^ 64, 2 ^ 70 + 3, 60000000000000000])
  | .int => return .int (← pick #[0, 1, -1, -64, 127, -(2 ^ 70), 2 ^ 65])
  | .nat8 => return .nat8 (← pick #[0, 1, 255])
  | .nat16 => return .nat16 (← pick #[0, 1, 65535])
  | .nat32 => return .nat32 (← pick #[0, 1, 4294967295])
  | .nat64 => return .nat64 (← pick #[0, 1, 18446744073709551615])
  | .int8 => return .int8 (← pick #[0, -1, -128, 127])
  | .int16 => return .int16 (← pick #[0, -1, -32768, 32767])
  | .int32 => return .int32 (← pick #[0, -1, -2147483648, 2147483647])
  | .int64 => return .int64 (← pick #[0, -1, -9223372036854775808, 9223372036854775807])
  | .float32 => return .float32 (← pick exactFloats).toFloat32
  | .float64 => return .float64 (← pick exactFloats)
  | .text => return .text (← pick names)
  | .reserved => return .reserved
  | .principal => return .principal (← pick principals)
  | .opt t =>
    if depth == 0 || !valueType t || (← rand 3) == 0 then return .opt none
    return .opt (some (← genValue t (depth - 1)))
  | .vec .nat8 => return .blob (bytesOf (← pick #[[], [0, 255, 34, 92], [68, 73, 68, 76]]))
  | .vec t =>
    let n ← if depth == 0 || !valueType t then pure 0 else rand 3
    let mut vs := #[]
    for _ in [0:n] do vs := vs.push (← genValue t (depth - 1))
    return .vec vs
  | .record fs =>
    return .record (← fs.mapM fun f => do return (f.label, ← genValue f.ty (depth - 1)))
  | .variant cs =>
    let c := cs[← rand cs.size]!
    return .variant c.label (← genValue c.ty (depth - 1))
  | .func .. => return .func (← pick principals) (← pick names)
  | .service _ => return .service (← pick principals)
  | _ => return .null

/-- A service of zero to three methods, or none, with initialization arguments a third of the
time: the parts of a `.did` file other than its definitions, which are `defNames`. -/
def genService (defNames : Array String) : G (Option Ty × Option (Array Ty)) := do
  if (← rand 4) == 0 then return (none, none)
  let mut ms := #[]
  for _ in [0:(← rand 4)] do
    ms := ms.push { name := ← pick names, ty := ← genFunc defNames 2 }
  let svc := Ty.serviceOf (dedupMethods ms)
  if (← rand 3) == 0 then
    let mut as := #[]
    for _ in [0:(← rand 3)] do as := as.push (← genTy defNames 2)
    return (some svc, some as)
  return (some svc, none)

/-! ## The lexer -/

/-- Texts and their tokens. -/
def lexCases : List (String × Array Token) := [
  ("opt Opt nullable null true _x x_1 record_ _", #[.keyword "opt", .ident "Opt", .ident "nullable",
    .keyword "null", .ident "true", .ident "_x", .ident "x_1", .ident "record_", .ident "_", .eof]),
  ("service func type import blob principal vec record variant oneway query composite_query",
    #[.keyword "service", .keyword "func", .keyword "type", .keyword "import", .keyword "blob",
      .keyword "principal", .keyword "vec", .keyword "record", .keyword "variant",
      .keyword "oneway", .keyword "query", .keyword "composite_query", .eof]),
  ("nat Nat int8 text assert",
    #[.ident "nat", .ident "Nat", .ident "int8", .ident "text", .ident "assert", .eof]),
  ("1_000 0x1F 0x1f 0x1_f 0x 007",
    #[.number 1000, .number 31, .number 31, .number 31, .number 0, .ident "x", .number 7, .eof]),
  -- The spec writes hexadecimal numbers with `0x` only (the Rust lexer reads `0X1f`, but then
  -- fails on it): `0X1f` is the number 0 and the name `X1f`.
  ("0X1f", #[.number 0, .ident "X1f", .eof]),
  ("0. .5 1e3 1.5e-3 1E+2 3.25 1.e5 0.0",
    #[.float 0 0, .float 5 (-1), .float 1 3, .float 15 (-4), .float 1 2, .float 325 (-2),
      .float 1 5, .float 0 (-1), .eof]),
  ("1_0.5", #[.number 10, .float 5 (-1), .eof]),
  ("1e x", #[.number 1, .ident "e", .ident "x", .eof]),
  ("1e+ 5", #[.number 1, .ident "e", .sign false, .number 5, .eof]),
  ("12abc", #[.number 12, .ident "abc", .eof]),
  ("a.b . ..5", #[.ident "a", .punct ".", .ident "b", .punct ".", .punct ".", .float 5 (-1), .eof]),
  ("-> == != !: = ( ) { } ; , . : + -",
    #[.punct "->", .punct "==", .punct "!=", .punct "!:", .punct "=", .punct "(", .punct ")",
      .punct "{", .punct "}", .punct ";", .punct ",", .punct ".", .punct ":", .sign false,
      .sign true, .eof]),
  ("-5 ->5 -", #[.sign true, .number 5, .punct "->", .number 5, .sign true, .eof]),
  ("record{record{}}foo:()->()",
    #[.keyword "record", .punct "{", .keyword "record", .punct "{", .punct "}", .punct "}",
      .ident "foo", .punct ":", .punct "(", .punct ")", .punct "->", .punct "(", .punct ")", .eof]),
  ("/* a /* b */ c */ x", #[.ident "x", .eof]),
  ("/* \" */ x", #[.ident "x", .eof]),
  ("/**/x/*/ y */z", #[.ident "x", .ident "z", .eof]),
  ("x // c\ny // end", #[.ident "x", .ident "y", .eof]),
  ("x\t\r\n y", #[.ident "x", .ident "y", .eof]),
  ("", #[.eof]),
  ("\"a\\n\\r\\t\\\\\\\"\\'b\"", #[.text (bytesOf [97, 10, 13, 9, 92, 34, 39, 98]), .eof]),
  ("\"\\u{2603}\\u{26_03}\\u{1F600}\\u{0}\"",
    #[.text (bytesOf [0xe2, 0x98, 0x83, 0xe2, 0x98, 0x83, 0xf0, 0x9f, 0x98, 0x80, 0]), .eof]),
  ("\"\\e2\\98\\83\\ff\\00\\AB\\aB\"",
    #[.text (bytesOf [0xe2, 0x98, 0x83, 0xff, 0, 0xab, 0xab]), .eof]),
  ("\"\\n0\\t0\"", #[.text (bytesOf [10, 48, 9, 48]), .eof]),
  ("\"a\nb\"", #[.text (bytesOf [97, 10, 98]), .eof]),
  ("\"☃\"", #[.text (bytesOf [0xe2, 0x98, 0x83]), .eof]),
  ("\"\"", #[.text .empty, .eof]),
  ("\"/* x */\"", #[.text "/* x */".toUTF8, .eof])
]

/-- Texts that the lexer rejects, and the start of the error message. `>` alone is not a token. -/
def lexErrors : List (String × String) := [
  ("!", "unexpected character"), ("#", "unexpected character"),
  ("é", "unexpected character \"é\""), ("- >", "unexpected character"),
  ("\"\\u{D800}\"", "Unicode escape out of range"),
  ("\"\\u{110000}\"", "Unicode escape out of range"),
  ("\"\\u{2603\"", "unknown escape character"), ("\"\\u2603\"", "unknown escape character"),
  ("\"\\q\"", "unknown escape character"), ("\"abc", "unclosed string"),
  ("\"\\", "unclosed string"),
  ("/* /* */ x", "unclosed comment"), ("/*", "unclosed comment"),
  ("\"\\0\"", "unknown escape character"), ("\"\\x41\"", "unknown escape character"),
  ("x \u00a0 y", "unexpected character")]

/-- The checks of the lexer. `repr src` writes the text as a Lean string literal, with escapes, so
that the names of the checks show control characters. -/
def lexerChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (src, want) in lexCases do
    out := out.push <| match tokens src with
      | .ok got => check s!"lex {repr src}" (got == want) s!"got {got.toList.map (·.describe)}"
      | .error e => check s!"lex {repr src}" false s!"error {e}"
  for (src, want) in lexErrors do
    let r := tokens src
    out := out.push <| check s!"lex error {repr src}" (isErr r && (errMsg r).startsWith want)
      s!"got {showE (r.map (·.toList.map (·.describe)))}"
  out := out.push <| match lex "  ab  12\n\"x\"".toUTF8 with
    | .ok ls => check "lex positions" (ls.map (·.start) == #[2, 6, 9, 12]) s!"{ls.map (·.start)}"
    | .error e => check "lex positions" false s!"{e}"
  out := out.push <| check "lex error offset" (errOffset (tokens "ab  \"x\\q\"") == some 6)
    s!"{errOffset (tokens "ab  \"x\\q\"")}"
  out := out.push <| check "lex comment error offset" (errOffset (tokens "x /* /* */") == some 2)
  return out

/-! ## Types -/

/-- Texts and the types that they stand for. -/
def typeCases : List (String × Ty) := [
  ("nat", .nat), ("bool", .bool), ("null", .null), ("principal", .principal),
  ("reserved", .reserved), ("empty", .empty), ("float32", .float32), ("int64", .int64),
  ("text", .text), ("blob", .vec .nat8), ("vec nat8", .vec .nat8), ("Opt", .var "Opt"),
  ("opt Opt", .opt (.var "Opt")), ("opt vec opt nat", .opt (.vec (.opt .nat))),
  ("record {}", .record #[]), ("record { }", .record #[]), ("record{}", .record #[]),
  ("record { int; bool }", .tuple #[.int, .bool]),
  ("record { 1 : int; text }", .record #[⟨.num 1, .int⟩, ⟨.num 2, .text⟩]),
  ("record { a : nat; nat }", .record #[⟨.name "a", .nat⟩, ⟨.num 98, .nat⟩]),
  ("record { 0x10 : nat; }", .record #[⟨.num 16, .nat⟩]),
  ("record { 4294967295 : nat }", .record #[⟨.num 4294967295, .nat⟩]),
  ("record { 2_ : nat }", .record #[⟨.num 2, .nat⟩]),
  ("record { b : nat; a : text }", .record #[⟨.name "a", .text⟩, ⟨.name "b", .nat⟩]),
  ("record { \"☃\" : null }", .record #[⟨.num 11272781, .null⟩]),
  ("record { nat : nat; true : bool }", .record #[⟨.name "nat", .nat⟩, ⟨.name "true", .bool⟩]),
  ("variant { a; b : nat; 3; 4 : text }",
    .variantOf #[⟨.name "a", .null⟩, ⟨.name "b", .nat⟩, ⟨.num 3, .null⟩, ⟨.num 4, .text⟩]),
  ("variant { Foo; Bar; }", .variantOf #[⟨.name "Foo", .null⟩, ⟨.name "Bar", .null⟩]),
  ("variant {}", .variant #[]),
  ("variant { 0; 1; 4294967295 }",
    .variant #[⟨.num 0, .null⟩, ⟨.num 1, .null⟩, ⟨.num 4294967295, .null⟩]),
  ("func () -> ()", .func #[] #[] #[]),
  ("func (nat) -> (text) query", .func #[.nat] #[.text] #[.query]),
  ("func (a : nat, \"b\" : text, bool) -> ()", .func #[.nat, .text, .bool] #[] #[]),
  ("func (nat,) -> (nat,) composite_query", .func #[.nat] #[.nat] #[.compositeQuery]),
  ("func () -> () oneway", .func #[] #[] #[.oneway]),
  ("func (opt empty) -> (func () -> (opt empty))",
    .func #[.opt .empty] #[.func #[] #[.opt .empty] #[]] #[]),
  ("service {}", .service #[]),
  ("service { foo : (text) -> (nat); bar : f }",
    .service #[⟨"bar", .var "f"⟩, ⟨"foo", .func #[.text] #[.nat] #[]⟩]),
  ("service {\"🐂\":(opt int)->(record{}) query; foo:()->() oneway}",
    .service #[⟨"foo", .func #[] #[] #[.oneway]⟩,
      ⟨"🐂", .func #[.opt .int] #[.record #[]] #[.query]⟩]),
  ("service { foobarbaz : () -> (); foobar : () -> () }",
    .service #[⟨"foobar", .func #[] #[] #[]⟩, ⟨"foobarbaz", .func #[] #[] #[]⟩]),
  ("/* c */ nat // d", .nat)
]

/-- Texts that are not types, and a part of the error message. -/
def typeErrors : List (String × String) := [
  ("record { a : nat; a : int }", "duplicate field a"),
  ("record { nat; 0 : nat }", "duplicate field 0"),
  ("variant { a; a }", "duplicate field a"),
  ("record { \"📦🍦\" : nat; 1832283146 : nat }", "have the same id 1832283146"),
  ("record { 4294967296 : nat }", "field id out of u32 range"),
  ("record { 4294967295 : nat; nat }", "field id out of u32 range"),
  ("variant { 4294967296 }", "field id out of u32 range"),
  ("func (a : nat, a : text) -> ()", "duplicate argument name a"),
  ("func () -> (nat) oneway", "oneway function has non-unit return type"),
  ("func () -> () query query", "cannot have more than one mode"),
  ("func () -> () query oneway", "cannot have more than one mode"),
  ("service { a : () -> (); a : () -> () }", "duplicate method a"),
  ("record { a : }", "expected a type, found '}'"),
  ("vec", "expected a type, found the end of the text"),
  ("nat nat", "expected the end of the text"),
  ("5", "expected a type, found the number 5"),
  ("\"x\"", "expected a type, found a string"),
  ("record { a : nat", "expected '}'"),
  ("record { a : nat, b : nat }", "expected '}', found ','"),
  ("func ()", "expected '->'"),
  ("func () -> () query nat", "expected the end of the text"),
  ("service { a : 5 }", "expected '('"),
  ("service { a }", "expected ':'"),
  ("variant { 1 : }", "expected a type"),
  ("record { ; }", "expected a type, found ';'"),
  ("record { \"\\ff\" : nat }", "not valid UTF-8"),
  ("variant { \"a\" : nat; \"\\ff\" }", "not valid UTF-8"),
  ("record { 0X1f : nat }", "expected a type, found the number 0")]

/-- `opt opt … nat`, with `n` times `opt`, as text. -/
def deepText (n : Nat) : String := String.join (List.replicate n "opt ") ++ "nat"

/-- `opt opt … nat`, with `n` times `opt`. -/
def deepTy (n : Nat) : Ty := (List.range n).foldl (fun t _ => .opt t) .nat

/-- The checks of `parseType`, including its depth limit, `Parse.maxDepth`: a type nested deeper
fails, before the parser recurses further. -/
def typeChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (src, want) in typeCases do
    let r := parseType src
    out := out.push <| check s!"type {src}" (okIs r want) s!"got {showE r}"
  for (src, want) in typeErrors do
    out := out.push <| checkError s!"type error {src}" (parseType src) want
  -- A method's type may be a name, which the checker resolves: `nat` is a name there, as in Rust.
  out := out.push <| check "service method name"
    (okIs (parseType "service { a : nat }") (.service #[⟨"a", .var "nat"⟩]))
  out := out.push <| check "service method name checked" (match parseType "service { a : nat }" with
    | .ok ty => errMsg (checkType {} ty) == "unbound type identifier nat"
    | _ => false)
  out := out.push <| check "type error offset"
    (errOffset (parseType "record { a : nat; b : }") == some 22)
    s!"{errOffset (parseType "record { a : nat; b : }")}"
  out := out.push <| check "type error offset dup"
    (errOffset (parseType "vec record { a : nat; a : int }") == some 11)
  out := out.push <| check "deep type 511" (okIs (parseType (deepText 511)) (deepTy 511))
    (showE (parseType (deepText 511) |>.map fun _ => ""))
  out := out.push <| check "deep type 512 fails" (isErr (parseType (deepText 512)))
    (errMsg (parseType (deepText 512)))
  out := out.push <| check "deep type 100000 fails" (isErr (parseType (deepText 100000)))
  out := out.push <| check "deep record" (isErr (parseType
    (String.join (List.replicate 1000 "record { ") ++ String.join (List.replicate 1000 " }"))))
  return out

/-- Round trips of 3000 generated types through their text: `parseType (Ty.toDid t)` is `t`. -/
def typeRoundTrips (_ : Unit) : Array Check := Id.run do
  let vars := #["A", "List", "my_type", "if", "Opt"]
  let mut out := #[]
  let mut seed : UInt64 := 0x9E3779B97F4A7C15
  for i in [0:3000] do
    -- `(genTy vars d).run seed` runs the generator from the state `seed`: a type, and the state
    -- after it, which the next type starts from.
    let (ty, s) := (genTy vars (1 + i % 5)).run seed
    seed := s
    let text := ty.toDid
    out := out.push <| match parseType text with
      | .ok back => check s!"type round trip {i}" (back == ty) s!"{text} ↦ {back.toDid}"
      | .error e => check s!"type round trip {i}" false s!"{text}: {e}"
    -- `Ty.toDidCapped` writes what `Ty.toDid` writes on one line, up to its limit.
    let oneLine := ty.toDid (width := 1000000000)
    let capped := if oneLine.length ≤ 40 then oneLine else (oneLine.take 40).toString ++ "…"
    out := out.push <| check s!"capped type text {i}"
      (ty.toDidCapped (max := 1000000000) == oneLine && ty.toDidCapped (max := 40) == capped)
      s!"{ty.toDidCapped (max := 1000000000)} and {ty.toDidCapped (max := 40)}, not {oneLine}"
  return out

/-! ## Interfaces -/

/-- `.did` files, and whether they are valid. -/
def interfaceCases : List (String × Bool) := [
  ("", true), ("type A = nat;", true), ("type A = nat", true), ("type A = nat; type B = A;", true),
  ("service : {}", true), ("service : {};", true), ("service S : { f : () -> () }", true),
  ("service : (nat) -> { f : () -> () }", true), ("type S = service {}; service : S", true),
  ("type S = service {}; service : (nat, S) -> S", true),
  ("type A = nat type B = nat;", false), ("type A = nat; type A = int;", false),
  ("type A = B; type B = C; type C = A;", false), ("type A = opt A;", true),
  ("type A = vec B;", false), ("service : { f : (B) -> () }", false),
  ("service : (B) -> {}", false), ("type f = func () -> (); service : f", false),
  ("type o = opt nat; service : { o : o }", false),
  ("type g = func () -> (); type h = g; service : { h : h }", true),
  ("type s = service { m : t }; type t = nat;", false),
  ("type s = service { m : t }; type t = func () -> ();", true),
  ("import \"a.did\";", false), ("import service \"a.did\";", false),
  ("service : {} type A = nat;", false), ("service : {}; service : {}", false),
  ("type nat = text; service : { f : (nat) -> () }", true), ("type \"A\" = nat;", false),
  ("type A = nat;;", false), ("service : { f : () -> (); }", true)]

/-- Whether two interfaces are the same: definitions, initialization arguments and service. -/
def sameInterface (a b : Interface) : Bool :=
  a.env.defs == b.env.defs && a.initArgs == b.initArgs && a.service == b.service

/-- The checks of `parseInterface`: valid and invalid files, what it returns, and error offsets. -/
def interfaceChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (src, ok) in interfaceCases do
    let r := parseInterface src
    out := out.push <| check s!"interface {repr src}" (isErr r != ok) (showE r)
  let list := "type List = opt record { head : nat; tail : List }; " ++
    "service S : (nat) -> { len : (List) -> (nat) query }"
  match parseInterface list with
  | .ok i =>
    out := out.push <| check "interface env" (i.env.defs ==
      #[("List", .opt (.recordOf #[⟨.name "head", .nat⟩, ⟨.name "tail", .var "List"⟩]))])
    out := out.push <| check "interface initArgs" (i.initArgs == some #[.nat])
    out := out.push <| check "interface service"
      (i.service == some (.service #[⟨"len", .func #[.var "List"] #[.nat] #[.query]⟩]))
  | .error e => out := out.push <| check "interface" false s!"{e}"
  match parseInterface "type s = service { next : () -> (s) };\nservice : (s) -> s" with
  | .ok i =>
    out := out.push <| check "interface class with name"
      (i.initArgs == some #[.var "s"] && i.service == some (.var "s"))
  | .error e => out := out.push <| check "interface class with name" false s!"{e}"
  out := out.push <| check "interface error offset"
    (errOffset (parseInterface "type A = nat;\ntype B = C;") == some 14)
    s!"{showE (parseInterface "type A = nat;\ntype B = C;")}"
  out := out.push <| check "interface duplicate offset"
    (errOffset (parseInterface "type A = nat; type A = int;") == some 14)
  out := out.push <| check "interface import offset"
    (errOffset (parseInterface "type A = nat; import \"x\";") == some 14)
  return out

/-- Round trips of 1000 generated `.did` files through `Interface.toDid`. Generated definitions
that do not check (cycles of names, methods that are not functions) are skipped, but at least half
must check. -/
def interfaceRoundTrips (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  let mut skipped := 0
  let mut seed : UInt64 := 0x2545F4914F6CDD1D
  for i in [0:1000] do
    let n := 1 + i % 4
    let defNames := (List.range n).toArray.map (s!"D{·}")
    let (defs, s) := (defNames.mapM fun d => do return (d, ← genTy defNames 3)).run seed
    seed := s
    let ((service, initArgs), s) := (genService defNames).run seed
    seed := s
    let iface : Interface := { env := { defs }, initArgs, service }
    let checked : Except Error Unit := do
      checkDefinitions iface.env
      for a in iface.initArgs.getD #[] do checkType iface.env a
      if let some svc := iface.service then checkType iface.env svc
    if checked matches .error _ then
      skipped := skipped + 1
      continue
    out := out.push <| match parseInterface iface.toDid with
      | .ok back => check s!"interface round trip {i}" (sameInterface back iface)
          s!"{iface.toDid}\n↦\n{back.toDid}"
      | .error e => check s!"interface round trip {i}" false s!"{iface.toDid}: {e}"
  out := out.push <| check s!"interface round trips: {skipped} of 1000 skipped" (skipped < 500)
  return out

/-- The Rust parser's test assets, in `dir`: each `X.did` gives the interface of `ok/X.did`, the
Rust printer's output for it, or fails if there is an `ok/X.fail`, or is rejected for its imports,
which this parser does not support. Every `ok/*.did` also survives a round trip through
`Interface.toDid`. The files are read in the order of their names, so that the output does not
depend on the order in which the system lists them. -/
def assetChecks (dir : System.FilePath) : IO (Array Check) := do
  let mut out := #[]
  let entries := (← dir.readDir).qsort (·.fileName < ·.fileName)
  let mut count := 0
  for entry in entries do
    unless entry.fileName.endsWith ".did" do continue
    let name := String.ofList (entry.fileName.toList.take (entry.fileName.length - 4))
    let src ← IO.FS.readFile entry.path
    let r := parseInterface src
    count := count + 1
    if ← (dir / "ok" / s!"{name}.fail").pathExists then
      out := out.push <| check s!"asset {name} fails" (isErr r) (showE r)
    else if contains src "\nimport " || src.startsWith "import " then
      out := out.push <| check s!"asset {name} has imports"
        (isErr r && errMsg r == "imports are not supported") (showE r)
    else
      let printed ← IO.FS.readFile (dir / "ok" / s!"{name}.did")
      out := out.push <| match r, parseInterface printed with
        | .ok a, .ok b =>
          check s!"asset {name} = ok/{name}" (sameInterface a b) s!"\n{a.toDid}\nvs\n{b.toDid}"
        | .error e, _ => check s!"asset {name}" false s!"{e}"
        | _, .error e => check s!"asset ok/{name}" false s!"{e}"
  out := out.push <| check s!"asset count {count}" (count == 32)
  let okEntries := (← (dir / "ok").readDir).qsort (·.fileName < ·.fileName)
  for entry in okEntries do
    unless entry.fileName.endsWith ".did" do continue
    let src ← IO.FS.readFile entry.path
    out := out.push <| match parseInterface src with
      | .ok i => match parseInterface i.toDid with
        | .ok j => check s!"ok/{entry.fileName} round trip" (sameInterface i j) i.toDid
        | .error e => check s!"ok/{entry.fileName} round trip" false s!"{e}\n{i.toDid}"
      | .error e => check s!"ok/{entry.fileName}" false s!"{e}"
  return out

/-! ## Values -/

/-- The management canister's principal, `aaaaa-aa`. -/
def mgmt : Principal := Principal.managementCanister

/-- The principal `w7x7r-cok77-xa`. -/
def p3 : Principal := ⟨⟨#[0xca, 0xff, 0xee]⟩⟩

/-- Texts and the values that they stand for, before `annotate` gives them types: whole numbers are
`int`s, decimal fractions `float64`s. -/
def valueCases : List (String × Array Value) := [
  ("()", #[]), ("( )", #[]), ("(true, false, null)", #[.bool true, .bool false, .null]),
  ("(42, -5, +7, 0x1f, -0x10, 1_000, - 3)",
    #[.int 42, .int (-5), .int 7, .int 31, .int (-16), .int 1000, .int (-3)]),
  ("(60000000000000000, -18446744073709551616)",
    #[.int 60000000000000000, .int (-18446744073709551616)]),
  ("(0.5, -0.5, 3., 0., 1e3, 2.5e-1, .5, 1.5E+2)",
    #[.float64 0.5, .float64 (-0.5), .float64 3.0, .float64 0.0, .float64 1000.0, .float64 0.25,
      .float64 0.5, .float64 150.0]),
  ("(\"a\\nb\", \"\\u{2603}\", \"☃\", \"\")", #[.text "a\nb", .text "☃", .text "☃", .text ""]),
  ("(blob \"\\00\\ff\", blob \"abc\", blob \"\")",
    #[.blob (bytesOf [0, 255]), .blob "abc".toUTF8, .blob .empty]),
  ("(opt 5, opt opt null, opt (5))",
    #[.opt (some (.int 5)), .opt (some (.opt (some .null))), .opt (some (.int 5))]),
  ("(vec {}, vec { 1; 2; }, vec { 1 }, vec { vec {} })",
    #[.vec #[], .vec #[.int 1, .int 2], .vec #[.int 1], .vec #[.vec #[]]]),
  ("(record {}, record { b = \"x\"; a = 1 })",
    #[.record #[], .record #[(.name "a", .int 1), (.name "b", .text "x")]]),
  ("(record { 1; 2 }, record { 5 = true; false }, record { a = 1; 2 })",
    #[.record #[(.num 0, .int 1), (.num 1, .int 2)],
      .record #[(.num 5, .bool true), (.num 6, .bool false)],
      .record #[(.name "a", .int 1), (.num 98, .int 2)]]),
  ("(record { \"☃\" = null; 0x2a = 1 })", #[.record #[(.num 42, .int 1), (.name "☃", .null)]]),
  ("(record { true = 1; false })",
    #[.record #[(.name "true", .int 1), (.num (idlHash "true" + 1), .bool false)]]),
  ("(variant { a }, variant { a = 5 }, variant { 3 }, variant { 3 = 4 }, variant { \"☃\" })",
    #[.variant (.name "a") .null, .variant (.name "a") (.int 5), .variant (.num 3) .null,
      .variant (.num 3) (.int 4), .variant (.name "☃") .null]),
  ("(principal \"aaaaa-aa\", service \"w7x7r-cok77-xa\", func \"aaaaa-aa\".m, " ++
      "func \"w7x7r-cok77-xa\".\"🐂\")",
    #[.principal mgmt, .service p3, .func mgmt "m", .func p3 "🐂"]),
  ("((5))", #[.int 5]), ("(1,)", #[.int 1]),
  ("(\n  1 , // one\n  2 /* two */\n)", #[.int 1, .int 2]),
  ("(5 : nat8, 5 : int, -1 : int8, vec { 1; 2 } : blob, null : opt nat, (300 : nat16))",
    #[.nat8 5, .int 5, .int8 (-1), .blob (bytesOf [1, 2]), .opt none, .nat16 300]),
  ("(1.5 : float32, record { 1 = 2 } : record { 1 : nat; 2 : opt nat })",
    #[.float32 (1.5 : Float).toFloat32, .record #[(.num 1, .nat 2), (.num 2, .opt none)]]),
  ("(vec { 1 : nat8; 2 })", #[.vec #[.nat8 1, .int 2]])
]

/-- Texts that are not values, and a part of the error message; `""` for a text that is fine. -/
def valueErrors : List (String × String) := [
  ("(variant {})", "expected a field label"), ("(variant { a; b })", "expected '}'"),
  ("(variant { a; })", "expected '}'"),
  ("(record { a = 1; a = 2 })", "duplicate field a"), ("(record { 0 = 1; 2 })", ""),
  ("(record { 1; 0 = 2 })", "duplicate field 0"),
  ("(principal \"abc\")", "invalid principal"),
  ("(principal \"w7x7r-cok77-xb\")", "invalid principal"),
  ("(1 2)", "expected ')'"), ("(1", "expected ')'"), ("5", "expected '('"),
  ("(opt)", "expected a value"), ("(vec { 1, 2 })", "expected '}'"),
  ("(func \"aaaaa-aa\")", "expected '.'"), ("(func \"aaaaa-aa\".5)", "expected '.'"),
  ("(func \"aaaaa-aa\". 5)", "expected a name"),
  ("(\"\\ff\")", "not valid UTF-8"), ("(nat)", "expected a value, found the name nat"),
  ("(- \"x\")", "expected a number"), ("(--5)", "expected a number"),
  ("(1) (2)", "expected the end"), ("(5 : List)", "unbound type identifier List"),
  ("(-1 : nat)", "out of the range"), ("(5 : float64)", "type mismatch"),
  ("(opt 5 : nat8)", "type mismatch"), ("(\"\\u{2603\")", "unknown escape character"),
  ("(1_0.5)", "expected ')'"), ("(record { 4294967295 = 1; 2 })", "field id out of u32 range"),
  ("(0X1f)", "expected ')', found the name X1f")]

/-- The checks of `parseValues`, including its depth limit. -/
def valueChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (src, want) in valueCases do
    let r := parseValues src
    out := out.push <| check s!"values {src}"
      (match r with | .ok got => valuesEq got want | _ => false) s!"got {showE r}"
  out := out.push <| check "negative zero" (match parseValues "(-0.)" with
    | .ok #[.float64 x] => x.toBits == 0x8000000000000000
    | _ => false)
  out := out.push <| check "float rounding"
    (match parseValues "(0.1, 1e400, 1e-400, 17976931348623157e292)" with
    | .ok #[.float64 a, .float64 b, .float64 c, .float64 d] =>
      a.toBits == (0.1 : Float).toBits && b.isInf && c == 0.0 && d.toBits == 0x7fefffffffffffff
    | _ => false)
  for (src, want) in valueErrors do
    let r := parseValues src
    out := out.push <| if want == "" then check s!"values ok {src}" (!isErr r) (showE r)
      else checkError s!"values error {src}" r want
  let deep (n : Nat) := "(" ++ String.join (List.replicate n "opt ") ++ "5)"
  out := out.push <| check "value deep 511" (!isErr (parseValues (deep 510)))
    (errMsg (parseValues (deep 510)))
  out := out.push <| check "value deep fails" (isErr (parseValues (deep 600)))
  out := out.push <| check "value deep parens fails" (isErr (parseValues
    (String.join (List.replicate 600 "(") ++ String.join (List.replicate 600 ")"))))
  return out

/-! ## annotate -/

/-- Definitions for `annotate`: a recursive list, names for `blob` and `nat8`, a cycle of names,
and names for `reserved`, `opt nat` and `null`. -/
def annEnv : TypeEnv := { defs := #[
  ("List", .opt (.recordOf #[⟨.name "head", .int⟩, ⟨.name "tail", .var "List"⟩])),
  ("B", .blob), ("N8", .nat8), ("A", .var "C"), ("C", .var "A"), ("R", .reserved),
  ("O", .opt .nat), ("Nul", .null)] }

/-- Values parsed from `src` and annotated at `tys`, with the definitions `annEnv`. `>>=` passes
the result of the parse, if there is one, to `annotateArgs`. -/
def ann (src : String) (tys : Array Ty) : Except Error (Array Value) :=
  parseValues src >>= annotateArgs annEnv tys

/-- Values parsed from `src` and annotated at `tys`, as text, or the error. -/
def rhs (src : String) (tys : Array Ty) : String :=
  match parseValues src >>= annotateArgs {} tys with
  | .ok vs => toString vs
  | .error e => toString e

/-- Texts, types, and the values that annotating gives. -/
def annCases : List (String × Array Ty × Array Value) := [
  ("(5, 5, 5, 5, 5, 5, 5, 5, 5, 5)",
    #[.nat, .int, .nat8, .nat16, .nat32, .nat64, .int8, .int16, .int32, .int64],
    #[.nat 5, .int 5, .nat8 5, .nat16 5, .nat32 5, .nat64 5, .int8 5, .int16 5, .int32 5,
      .int64 5]),
  ("(255, 65535, 4294967295, 18446744073709551615, -128, 127, -32768, -2147483648, " ++
      "-9223372036854775808)",
    #[.nat8, .nat16, .nat32, .nat64, .int8, .int8, .int16, .int32, .int64],
    #[.nat8 255, .nat16 65535, .nat32 4294967295, .nat64 18446744073709551615, .int8 (-128),
      .int8 127, .int16 (-32768), .int32 (-2147483648), .int64 (-9223372036854775808)]),
  ("(-5, 2.5, -0.5)", #[.int, .float64, .float32],
    #[.int (-5), .float64 2.5, .float32 (-0.5 : Float).toFloat32]),
  ("(null, null, null, null, opt 5, opt null)",
    #[.null, .opt .nat, .reserved, .var "O", .opt .nat, .opt (.opt .nat)],
    #[.null, .opt none, .reserved, .opt none, .opt (some (.nat 5)), .opt (some (.opt none))]),
  ("(5, \"x\", record {}, vec { 1 })", #[.reserved, .reserved, .var "R", .reserved],
    #[.reserved, .reserved, .reserved, .reserved]),
  ("(vec { 1; 2 }, blob \"ab\", vec { 1 }, vec { 1 }, vec {}, vec { 1; 2 })",
    #[.blob, .blob, .var "B", .vec (.var "N8"), .blob, .vec .nat],
    #[.blob (bytesOf [1, 2]), .blob "ab".toUTF8, .blob (bytesOf [1]), .blob (bytesOf [1]),
      .blob .empty, .vec #[.nat 1, .nat 2]]),
  ("(vec { 1 : nat8; 255 })", #[.blob], #[.blob (bytesOf [1, 255])]),
  ("(record { a = 1; zzz = 2 })",
    #[.recordOf #[⟨.name "a", .nat⟩, ⟨.name "b", .opt .nat⟩, ⟨.name "c", .null⟩,
      ⟨.name "d", .reserved⟩, ⟨.name "e", .var "Nul"⟩]],
    #[.record (#[(.name "a", .nat 1), (.name "b", .opt none), (.name "c", .null),
      (.name "d", .reserved), (.name "e", .null)].qsort (·.1.id < ·.1.id))]),
  ("(record { 97 = 1 })", #[.record #[⟨.name "a", .nat⟩]], #[.record #[(.name "a", .nat 1)]]),
  ("(record { 42; true })", #[.tuple #[.int, .bool]],
    #[.record #[(.num 0, .int 42), (.num 1, .bool true)]]),
  ("(variant { ok = 5 }, variant { b })",
    #[.variantOf #[⟨.name "ok", .nat⟩, ⟨.name "err", .text⟩],
      .variantOf #[⟨.name "a", .null⟩, ⟨.name "b", .null⟩]],
    #[.variant (.name "ok") (.nat 5), .variant (.name "b") .null]),
  ("(principal \"aaaaa-aa\", service \"aaaaa-aa\", func \"aaaaa-aa\".m)",
    #[.principal, .service #[], .func #[] #[] #[]],
    #[.principal mgmt, .service mgmt, .func mgmt "m"]),
  ("(opt record { head = 1; tail = opt record { head = 2; tail = null } })", #[.var "List"],
    #[.opt (some (.record #[(.name "head", .int 1), (.name "tail",
      .opt (some (.record #[(.name "head", .int 2), (.name "tail", .opt none)])))]))]),
  ("()", #[.null, .opt .nat, .reserved, .var "O"], #[.null, .opt none, .reserved, .opt none]),
  ("(1, 2, 3)", #[.nat], #[.nat 1]),
  ("(true, \"t\")", #[.bool, .text], #[.bool true, .text "t"])
]

/-- Texts that cannot be annotated at the types, and a part of the error message. -/
def annErrors : List (String × Array Ty × String) := [
  ("(256)", #[.nat8], "out of the range"), ("(-1)", #[.nat], "out of the range"),
  ("(-129)", #[.int8], "out of the range"),
  ("(18446744073709551616)", #[.nat64], "out of the range"),
  ("(5)", #[.float64], "type mismatch"), ("(5)", #[.float32], "type mismatch"),
  ("(5)", #[.opt .nat], "type mismatch"), ("(5)", #[.text], "type mismatch"),
  ("(null)", #[.nat], "type mismatch"), ("(\"x\")", #[.principal], "type mismatch"),
  ("(principal \"aaaaa-aa\")", #[.service #[]], "type mismatch"),
  ("(service \"aaaaa-aa\")", #[.principal], "type mismatch"),
  ("(vec { 256 })", #[.blob], "out of the range of nat8"),
  ("(vec { -1 })", #[.blob], "out of the range of nat8"),
  ("(vec { \"a\" })", #[.blob], "type mismatch"), ("(blob \"a\")", #[.vec .nat], "type mismatch"),
  ("(vec { 1; -1 })", #[.vec .nat], "out of the range"),
  ("(record {})", #[.record #[⟨.name "a", .nat⟩]], "record field a not found"),
  ("(variant { c })", #[.variantOf #[⟨.name "a", .null⟩]], "variant field c not found"),
  ("(variant { a = 5 })", #[.variantOf #[⟨.name "a", .null⟩]], "type mismatch"),
  ("(5)", #[.var "A"], "cyclic"), ("(5)", #[.var "Undefined"], "unbound"),
  ("()", #[.nat], "Omitted values cannot be of type nat"), ("(1.5)", #[.int], "type mismatch"),
  ("(true)", #[.empty], "type mismatch"),
  ("(record { 1 = 2 })", #[.tuple #[.nat]], "record field 0 not found")]

/-- `opt opt … 1`, with `n` times `opt`. -/
def deepValue (n : Nat) : Value := (List.range n).foldl (fun v _ => .opt (some v)) (.nat 1)

/-- A `List` of `n` elements, each two levels deep: an `opt` and a `record`. -/
def longList (n : Nat) : Value :=
  (List.range n).foldl (init := .opt none) fun v (i : Nat) =>
    .opt (some (.record #[(.name "head", .int i), (.name "tail", v)]))

/-- The checks of `annotate` and `annotateArgs`, and of the annotated right-hand sides of a few
assertions of the conformance suite. -/
def annotateChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (src, tys, want) in annCases do
    let r := ann src tys
    out := out.push <| check s!"annotate {src}"
      (match r with | .ok got => valuesEq got want | _ => false) s!"got {showE r}"
  out := out.push <| check "annotate keeps the type's labels"
    (match ann "(record { 97 = 1 })" #[.record #[⟨.name "a", .nat⟩]] with
    | .ok #[v] => v.toText == "record { a = 1 }"
    | _ => false)
  for (src, tys, want) in annErrors do
    out := out.push <| checkError s!"annotate error {src} : {tys.toList.map Ty.toDid}" (ann src tys)
      want
  -- Typed values from elsewhere keep their types.
  out := out.push <| check "annotate nat8 at nat8" (okIs (annotate {} .nat8 (.nat8 5)) (.nat8 5))
  out := out.push <| check "annotate nat at int" (okIs (annotate {} .int (.nat 5)) (.int 5))
  out := out.push <| check "annotate nat at nat8 fails" (isErr (annotate {} .nat8 (.nat 5)))
  out := out.push <| check "annotate nat8 at nat16 fails" (isErr (annotate {} .nat16 (.nat8 5)))
  out := out.push <| check "annotate opt none at opt"
    (okIs (annotate {} (.opt .text) (.opt none)) (.opt none))
  out := out.push <| check "annotate reserved at opt"
    (okIs (annotate {} (.opt .text) .reserved) (.opt none))
  -- The depth limit, also through a recursive name.
  out := out.push <| check "annotate deep 500"
    (okIs (annotate {} (deepTy 500) (deepValue 500)) (deepValue 500))
  out := out.push <| check "annotate deep 600 fails"
    (isErr (annotate {} (deepTy 600) (deepValue 600)))
  out := out.push <| check "annotate list 250"
    (okIs (annotate annEnv (.var "List") (longList 250)) (longList 250))
  out := out.push <| check "annotate list 300 fails"
    (isErr (annotate annEnv (.var "List") (longList 300)))
  -- Right-hand sides of assertions of the suite.
  out := out.push <| check "rhs func"
    (rhs "(opt func \"aaaaa-aa\".m)" #[.opt (.func #[] #[.int] #[])] == "(opt func \"aaaaa-aa\".m)")
  let fooBar := #[.recordOf #[⟨.name "foo", .int32⟩, ⟨.name "bar", .bool⟩]]
  out := out.push <| check "rhs record"
    (rhs "(record { foo = 42; bar = true })" fooBar == "(record { bar = true; foo = 42 })")
    (rhs "(record { foo = 42; bar = true })" fooBar)
  out := out.push <| check "rhs missing"
    (rhs "(record { 0 = 5 })" #[.record #[⟨.num 1, .null⟩]] == "(record { 1 = null })")
  out := out.push <| check "rhs blob"
    (rhs "(blob \"\\01\\02\")" #[.vec .nat8] == "(blob \"\\01\\02\")")
  out := out.push <| check "rhs reserved field"
    (rhs "(record { foo = \"☃\" })" #[.record #[⟨.name "foo", .reserved⟩]] ==
      "(record { foo = null })")
  return out

/-- Round trips of 3000 generated values through their text: `Value.toText` of a value, parsed and
annotated at its type, is the value again. Types without values that `genValue` can make are
skipped. -/
def valueRoundTrips (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  let mut skipped := 0
  let mut seed : UInt64 := 0xD1B54A32D192ED03
  for i in [0:3000] do
    let (ty, s) := (genTy #[] (1 + i % 4)).run seed
    seed := s
    unless valueType ty do
      skipped := skipped + 1
      continue
    let (v, s) := (genValue ty 4).run seed
    seed := s
    let text := s!"({v.toText})"
    out := out.push <| match parseValues text >>= annotateArgs {} #[ty] with
      | .ok #[back] =>
        check s!"value round trip {i}" (bitsEq back v) s!"{text} : {ty} ↦ {back.toText}"
      | .ok vs => check s!"value round trip {i}" false s!"{vs.size} values"
      | .error e => check s!"value round trip {i}" false s!"{text} : {ty}: {e}"
  out := out.push <| check s!"value round trips: {skipped} of 3000 skipped" (skipped < 1500)
  return out

/-! ## The inputs of the Rust crate's tests

From candid_parser/tests/parse_value.rs and value.rs. -/

/-- The checks of the Rust tests' inputs. -/
def rustChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  let maxChar := String.singleton (Char.ofNat 0x10ffff)
  let rustCases : List (String × Array Value) := [
    (" (true, null, 42, 42., +42.42, -42e5, 42.42e-5)",
      #[.bool true, .null, .int 42, .float64 42.0, .float64 42.42, .float64 (-42e5),
        .float64 42.42e-5]),
    ("(\"\", \"\\u{10ffff}\\n\", \"\\0a\\0dd\")",
      #[.text "", .text (maxChar ++ "\n"), .text "\n\rd"]),
    ("(blob \"DIDL\\00\\01\\7d\\80\\00\")",
      #[.blob (bytesOf [0x44, 0x49, 0x44, 0x4c, 0, 1, 0x7d, 0x80, 0])]),
    ("(true, null, 4_2, \"哈哈\", \"string with whitespace\", 0x2a, -42, false)",
      #[.bool true, .null, .int 42, .text "哈哈", .text "string with whitespace", .int 42,
        .int (-42), .bool false]),
    ("(opt record {}, record { 1=42;44=\"test\"; 2=false }, variant { 5=null })",
      #[.opt (some (.record #[])),
        .record #[(.num 1, .int 42), (.num 2, .bool false), (.num 44, .text "test")],
        .variant (.num 5) .null]),
    ("(record { 42; record {}; true; record { 42; 0x2a=42; 42; 42 }; opt 42 })",
      #[.record #[(.num 0, .int 42), (.num 1, .record #[]), (.num 2, .bool true),
        (.num 3, .record #[(.num 0, .int 42), (.num 42, .int 42), (.num 43, .int 42),
          (.num 44, .int 42)]),
        (.num 4, .opt (some (.int 42)))]]),
    ("(variant { 0x2a }, variant { label })",
      #[.variant (.num 42) .null, .variant (.name "label") .null]),
    ("((1))", #[.int 1]),
    ("(1 : nat, (123 : int), 456 : int32, 789. : float32, 1011.0 : float64)",
      #[.nat 1, .int 123, .int32 456, .float32 (789.0 : Float).toFloat32, .float64 1011.0])]
  for (src, want) in rustCases do
    let r := parseValues src
    out := out.push <| check s!"rust values {src}"
      (match r with | .ok got => valuesEq got want | _ => false) s!"got {showE r}"
  for (src, want) in [("(\"DIDL\\00\\01\\7d\\80\\00\")", "not valid UTF-8"),
      ("(\"\\u{d800}\")", "out of range d800"), ("(\"\\q\")", "unknown escape character \"q\""),
      ("(vec {1;2;3;-4;5;6;7} : vec nat)", "out of the range")] do
    out := out.push <| checkError s!"rust value error {src}" (parseValues src) want
  out := out.push <| check "rust error offset" (errOffset (parseValues "(\"\\u{d800}\")") == some 2)
  for src in ["(true,42,+42,-42)", "(\"test\", variant {5})", "(opt null, record {}, vec{1;2;3})",
      "(record {1=42;44=\"test\";2=false})",
      "(record {label=42; 43=record {test100=\"test\"; \"标签\"=\"hello\"}; long_label=opt null}, " ++
        "variant {C})",
      "(record { record{ 42; opt 42 }; vec{4;5;6} })",
      "(variant { A=opt 42 }, variant {A=vec{1;2;3}})",
      "(variant { cons=record{ 42; variant { cons=record{43; variant { nil=record{} }} } } })",
      "(principal \"w7x7r-cok77-xa\")"] do
    out := out.push <| check s!"rust parse {src}" (!isErr (parseValues src))
      (showE (parseValues src))
  -- `annotate`, as parse_value.rs uses it.
  let nested :=
    "(record {label=42; 0x2b=record {test=\"test\"; \"opt\"=\"hello\"}; long_label=opt null})"
  let nestedTy :=
    "record {label: nat; 0x2b:record { test:text; \"opt\":text }; long_label: opt null }"
  match parseType nestedTy, parseType "record { label: nat }" with
  | .ok ty, .ok skip =>
    out := out.push <| check "rust nested record" (rhs nested #[ty] ==
      "(record { 43 = record { \"opt\" = \"hello\"; test = \"test\" }; long_label = opt null; " ++
        "label = 42 })") (rhs nested #[ty])
    out := out.push <| check "rust nested record skip"
      (rhs nested #[skip] == "(record { label = 42 })") (rhs nested #[skip])
  | _, _ => out := out.push <| check "rust nested record types" false
  out := out.push <| check "rust vec nat"
    (rhs "(vec{1;2;3;4})" #[.vec .nat] == "(vec { 1; 2; 3; 4 })")
  -- `test_typed_parser` in value.rs.
  let did := "type List = List1;\ntype List1 = List2;\n" ++
    "type List2 = opt record { head: int16; tail: List1 };\n" ++
    "type byte = nat8;\ntype enum = variant { a: nat; b: text; c };\n" ++
    "type f = func (byte, int, nat, int8) -> (List, enum);\nservice : {\n  f : f;\n}\n"
  match parseInterface did with
  | .ok i =>
    match i.service, i.env.resolve #[] (.var "f") with
    | some (.service #[⟨"f", .var "f"⟩]), .ok (.func args rets _) =>
      let a := parseValues "(42,42,42,42)" >>= annotateArgs i.env args
      out := out.push <| check "rust typed args"
        (match a with | .ok vs => valuesEq vs #[.nat8 42, .int 42, .nat 42, .int8 42] | _ => false)
        (showE a)
      let r := parseValues ("(opt record { head = 1000; tail = opt record {head = -2000; " ++
          "tail = null}}, variant {a = 42})") >>= annotateArgs i.env rets
      let want : Array Value := #[.opt (some (.record #[(.name "head", .int16 1000),
          (.name "tail", .opt (some (.record #[(.name "head", .int16 (-2000)),
            (.name "tail", .opt none)])))])),
        .variant (.name "a") (.nat 42)]
      out := out.push <| check "rust typed rets"
        (match r with | .ok vs => valuesEq vs want | _ => false) (showE r)
    | _, _ => out := out.push <| check "rust typed parser service" false (toString i)
  | .error e => out := out.push <| check "rust typed parser" false s!"{e}"
  return out

/-! ## Quoting

The printers quote a name that the Rust parser would read as something else: its keywords, and
`true` and `false`, which its lexer reads as booleans wherever they are, so that `record { true :
bool }` is not a type there. Any name may be quoted. -/

/-- Types and values with such names, and their text. -/
def quotedCases : List (String × String) := [
  ((Ty.recordOf #[⟨.name "true", .bool⟩]).toDid, "record { \"true\" : bool }"),
  ((Ty.variantOf #[⟨.name "false", .null⟩]).toDid, "variant { \"false\" }"),
  ((Ty.serviceOf #[⟨"true", .func #[] #[] #[]⟩]).toDid, "service { \"true\" : () -> () }"),
  ((Value.variant (.name "true") .null).toText, "variant { \"true\" }"),
  ((Value.record #[(.name "false", .bool true)]).toText, "record { \"false\" = true }")]

/-- The checks of quoting, and that the quoted text reads back. -/
def quotingChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (got, want) in quotedCases do
    out := out.push <| check s!"quoted {want}" (got == want) s!"got {got}"
  out := out.push <| check "quoted type reads back"
    (okIs (parseType "record { \"true\" : bool }") (.recordOf #[⟨.name "true", .bool⟩]))
  return out

/-! ## Hostile text

Text can come from anyone: a canister may take arguments in the text format. These checks give
the parser and the printers inputs that took time in proportion to the square of their length, or
the cube, or worse, so that the checks would not finish in the time of a test run, or that made
values or error messages far larger than the text, and check that their results are right. -/

/-- `n` copies of `s`, separated by `sep`. -/
def copies (n : Nat) (s : String) (sep : String := "") : String :=
  sep.intercalate (List.replicate n s)

/-- `record { a : t; b : t }`, `n` times nested: a type of `n` nodes whose text doubles with each
level. -/
def doubling (n : Nat) : Ty :=
  (List.range n).foldl (fun t _ => .recordOf #[⟨.name "a", t⟩, ⟨.name "b", t⟩]) .nat

/-- The checks of hostile text. -/
def hostileChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  -- Long numbers: the digits of a Unicode escape, of an exponent and of a decimal fraction are
  -- read only as far as they matter.
  let r := parseValues s!"(\"\\u\{{copies 100000 "7"}}\")"
  out := out.push <| check "long Unicode escape"
    (isErr r && contains (errMsg r) "out of range" && (errMsg r).length < 100)
    s!"an error of {(errMsg r).length} characters"
  let nines := copies 100000 "9"
  out := out.push <| check "long exponents"
    (match parseValues s!"(1e{nines}, -1e-{nines}, 0e{nines})" with
    | .ok #[.float64 a, .float64 b, .float64 c] =>
      a.isInf && a > 0 && b.toBits == 0x8000000000000000 && c.toBits == 0
    | _ => false)
  out := out.push <| check "long fraction"
    (match parseValues s!"(0.{copies 1000000 "3"}, {copies 100000 "1"}.5)" with
    | .ok #[.float64 a, .float64 b] => a == 1.0 / 3.0 && b.isInf
    | _ => false)
  -- A fraction rounds as all of its digits say, also beyond those that are kept: 2^53 + 1 is
  -- halfway between two floats, and rounds to the even one, 2^53, but a little more rounds up.
  let halfway := "9007199254740993" ++ copies 1000 "0"
  out := out.push <| check "long fraction rounds to even"
    (match parseValues s!"({halfway}e-1000, {halfway}1e-1001)" with
    | .ok #[.float64 a, .float64 b] => a == 9007199254740992.0 && b == 9007199254740994.0
    | _ => false)
  out := out.push <| check "long number"
    (okIs (parseValues s!"({copies 20000 "9"}, 0x{copies 20000 "f"})")
      #[.int (10 ^ 20000 - 1), .int (16 ^ 20000 - 1)])
  -- An error does not write out a long number, which would take long, but says that it is.
  for (src, want) in [(s!"({copies 100000 "7"} : nat8)", "a number of more than 30 digits is out"),
      (s!"(vec \{ -{copies 100000 "7"} } : blob)", "a negative number of more than 30 digits"),
      (s!"({copies 100000 "7"} : text)", "type mismatch: a number of more than 30 digits"),
      (s!"(1 {copies 100000 "7"})", "expected ')', found a number of more than 30 digits")] do
    let r := parseValues src
    out := out.push <| check s!"long number in an error: {want}"
      (isErr r && contains (errMsg r) want && (errMsg r).length < 100)
      s!"an error of {(errMsg r).length} characters"
  -- An error shows a long name in part: a canister traps if its reject message is too long.
  let long := copies 1000000 "x"
  -- (`errMsg` of each, as the results are of different types.)
  for (message, want) in [
      (errMsg (parseValues s!"({long})"), "expected a value, found the name xxx"),
      (errMsg (parseInterface s!"type a = {long};"), "unbound type identifier xxx"),
      (errMsg (parseType s!"variant \{ {long}; {long} }"), "duplicate field xxx")] do
    out := out.push <| check s!"long name in an error: {want}"
      (message.startsWith want && message.length < 200) s!"an error of {message.length} characters"
  -- Many labels, names and definitions, which are sorted and looked up.
  let r := parseType s!"variant \{ {copies 20000 "a" "; "} }"
  out := out.push <| check "many equal labels" (isErr r && errMsg r == "duplicate field a")
    (errMsg r)
  let r := parseType s!"service \{ {copies 20000 "m : () -> ()" "; "} }"
  out := out.push <| check "many equal methods" (isErr r && errMsg r == "duplicate method m")
    (errMsg r)
  let r := parseType s!"func ({copies 20000 "a : nat" ", "}) -> ()"
  out := out.push <| check "many equal argument names"
    (isErr r && errMsg r == "duplicate argument name a") (errMsg r)
  let n := 3000
  let chain := String.join ((List.range n).map fun i => s!"type a{i} = a{i + 1};\n")
  out := out.push <| check "long chain of names"
    (match parseInterface (chain ++ s!"type a{n} = nat;") with
    | .ok i => i.env.defs.size == n + 1 | _ => false)
  let r := parseInterface (chain ++ s!"type a{n} = a0;")
  out := out.push <| check "long cycle of names"
    (isErr r && errMsg r == "a0 has cyclic type definition") (errMsg r)
  let r := parseInterface (chain ++ s!"type a{n} = func () -> ();\nservice : \{ m : a0 }")
  out := out.push <| check "long chain of names to a function" (!isErr r) (errMsg r)
  let r := parseInterface (chain ++ s!"type a{n} = nat;\nservice : \{ m : a0 }")
  out := out.push <| check "long chain of names to no function"
    (isErr r && errMsg r == "method m is a non-function type") (errMsg r)
  let r := parseInterface (chain ++ s!"type a{n} = nat;\ntype a{n / 2} = text;")
  out := out.push <| check "many definitions, one twice"
    (isErr r && errMsg r == s!"duplicate binding for a{n / 2}") (errMsg r)
  -- A record value of many fields, at a record type of many fields.
  let fieldTypes := "; ".intercalate ((List.range 20000).map (s!"f{·} : nat"))
  let fieldValues := "; ".intercalate ((List.range 20000).map (s!"f{·} = 1"))
  out := out.push <| check "many fields annotated"
    (match parseValues s!"(record \{ {fieldValues} })", parseType s!"record \{ {fieldTypes} }" with
    | .ok vs, .ok t => match annotateArgs {} #[t] vs with
      | .ok #[.record fs] => fs.size == 20000 && fs.all (·.2 == .nat 1)
      | _ => false
    | _, _ => false)
  -- Many variant values at a variant type of many cases: each value's case is found by a binary
  -- search, rather than by a look at every case, which hashes the case's name.
  let k := 20000
  let caseTypes := "; ".intercalate ((List.range k).map (s!"c{·}"))
  let caseValues := "; ".intercalate ((List.range k).map (s!"variant \{ c{·} }"))
  out := out.push <| check "many variant values annotated"
    (match parseValues s!"(vec \{ {caseValues} } : vec variant \{ {caseTypes} })" with
    | .ok #[.vec vs] =>
      vs.size == k && (List.range k).all fun i => vs[i]? == some (.variant (.name s!"c{i}") .null)
    | _ => false)
  -- A record value gets the fields of its type that it lacks, if their types are `null`, `opt` or
  -- `reserved`: `record {}` at a type of `n` such fields is a value of `n` fields, so that a text
  -- of `n` times `record {}`, at that type, would be a value of `n * n` fields. The annotations
  -- of a text may fill in 16 fields per byte of it, and 10,000 more.
  let optFields (n : Nat) := "; ".intercalate ((List.range n).map (s!"f{·} : opt nat"))
  -- `n` times `record {}`, at a record type of `n` fields of type `opt nat`.
  let emptyRecords (n : Nat) :=
    s!"(vec \{ {copies n "record {}" "; "} } : vec record \{ {optFields n} })"
  let r := parseValues (emptyRecords 2000)
  out := out.push <| check "too many fields filled in"
    (isErr r && contains (errMsg r) "fill in too many missing fields") (errMsg r)
  let r := parseValues (emptyRecords 100)
  out := out.push <| check "fields filled in within the limit"
    (match r with
    | .ok #[.vec vs] => vs.size == 100 && vs.all fun
        | .record fs => fs.size == 100 && fs.all (·.2 == .opt none)
        | _ => false
    | _ => false) (errMsg r)
  -- A text longer than a principal's can be is rejected without being written into the error:
  -- `Principal.fromText` quotes the text that it rejects, with escapes, which can make the message
  -- five times as long as the text.
  for (what, s) in [("letters", copies 1000000 "a"),
      ("control characters", copies 100000 "\\01")] do
    let r := parseValues s!"(principal \"{s}\")"
    out := out.push <| check s!"long principal of {what}"
      (isErr r && (errMsg r).startsWith "invalid principal" && (errMsg r).length < 200)
      s!"an error of {(errMsg r).length} characters"
  -- Capped text costs as much for a large type as for a small one: the text of `doubling 64`
  -- has more than 2^64 characters.
  let capped := (doubling 64).toDidCapped
  out := out.push <| check "capped text of a huge type"
    (capped.length == 101 && capped.startsWith "record { a : record { a : record {") capped
  return out

/-! ## Running the checks -/

/-- Prints a line for each check of a group that fails, and one for the group, and returns how
many passed and how many failed. -/
def runGroup (group : String) (checks : Array Check) : IO (Nat × Nat) := do
  let mut failed := 0
  for c in checks do
    if let some why := c.failure then
      failed := failed + 1
      IO.println s!"FAIL {group}: {c.name}: {why}"
  IO.println s!"{group}: {checks.size - failed} passed, {failed} failed"
  -- Writes out what was printed, should the program fail after it.
  (← IO.getStdout).flush
  return (checks.size - failed, failed)

/-- Runs the groups, prints a summary, and returns the exit code: 0 if all checks pass, else 1.
The arguments are none, or `--assets` and a directory: the pattern `["--assets", dir]` matches a
list of two elements, the first `"--assets"`, and names the second `dir`. -/
def main (args : List String) : IO UInt32 := do
  let assets : Option System.FilePath := match args with
    | ["--assets", dir] => some dir
    | _ => none
  unless args.isEmpty || assets.isSome do
    IO.println "usage: lean --run Candid/Tests/Parse.lean [--assets DIR]"
    return 1
  let groups : Array (String × (Unit → Array Check)) := #[("lexer", lexerChecks),
    ("types", typeChecks), ("type round trips", typeRoundTrips), ("interfaces", interfaceChecks),
    ("interface round trips", interfaceRoundTrips), ("values", valueChecks),
    ("annotate", annotateChecks), ("value round trips", valueRoundTrips),
    ("Rust inputs", rustChecks), ("quoting", quotingChecks), ("hostile text", hostileChecks)]
  let mut passed := 0
  let mut failed := 0
  for (name, checks) in groups do
    let (p, f) ← runGroup name (checks ())
    passed := passed + p
    failed := failed + f
  match assets with
  | some dir =>
    let (p, f) ← runGroup "assets" (← assetChecks dir)
    passed := passed + p
    failed := failed + f
  | none => IO.println "assets: skipped, as no directory was given with --assets DIR"
  IO.println s!"parse tests: {passed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
