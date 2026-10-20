import Candid

/-!
Edge cases and round trips of the library's parts: LEB128, `idlHash`, the text form of principals,
the `.did` text of types and interfaces, every `CandidType` instance through `Candid.encode` and
`Candid.decode`, and generated types and values through `Candid.encodeValues` and
`Candid.decodeValues`; then the capped text of values, and the time that numbers of millions of
bits and long values take, which must grow about as their size.

The Nix checks also run this program compiled to wasm32, as a canister is, and its output there must
be the same as the native one, line for line. That is where 32 bits make a difference: natively a
`Nat` up to 2^63 - 1 fits in a machine word, but on wasm32 only up to 2^31 - 1, beyond which it is
a big number, so the numbers here sit around 2^31, 2^32, 2^63 and 2^64. The expected LEB128 bytes,
`idlHash`es and principal texts were computed with Python, independently of this library.

The generated cases come from a pseudo-random generator with a fixed seed, so that every run, native
or on wasm32, makes the same ones. Floats are compared by their bits, except NaNs: Lean's runtime
turns every NaN into the same one, so NaNs are compared with `isNaN`.

This is a program, not a `module`. It runs with `lean --run Candid/Tests/RoundTrip.lean`, with
`LEAN_PATH` on the library's `.olean` files. It prints a line per check, and one per group of
generated cases with a line per case that fails, then a summary, and returns 1 if a check fails.
-/

open Candid

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

/-- `==` on results, which `Init` does not define: equal values, or equal errors. An instance is
an implementation of a type class, here `BEq`, for a type, here `Except ε α`, given implementations
for `ε` and `α`. -/
instance [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok a, .ok b => a == b
    | .error a, .error b => a == b
    | _, _ => false

/-- Whether `sub` occurs in `s`: splitting `s` at it gives more than one piece. -/
def contains (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- At most `max` characters of `s`, and `…` if that is not all of it, for the lines of checks
that fail. `s.take max` is a *slice*, a part of `s`, which `copy` makes a string of its own. -/
def capped (s : String) (max : Nat := 200) : String :=
  if s.length ≤ max then s else (s.take max).copy ++ "…"

/-- Bytes as hexadecimal digits, a byte at a time: `44 49 44 4c`. -/
def hexList (bytes : List UInt8) : String := " ".intercalate (bytes.map (hexDigits ·.toNat))

/-- The bytes of a `ByteArray` in hexadecimal, cut after 200 characters. -/
def hex (bytes : ByteArray) : String := capped (hexList bytes.toList)

/-- A `ByteArray` of these bytes. -/
def bytesOf (l : List Nat) : ByteArray := ⟨(l.map (·.toUInt8)).toArray⟩

/-- A result as text, for the line of a check that fails. `{α}` makes the type `α` an implicit
argument, which Lean infers, and `[ToString α]` asks for a way to turn an `α` into text. -/
def showE {α} [ToString α] : Except Error α → String
  | .ok a => s!"ok {a}"
  | .error e => s!"error {e}"

/-! ## LEB128 -/

/-- Numbers and their LEB128 encodings, computed with Python. `List.replicate n b` is `n` times
`b`. -/
def natGoldens : Array (String × Nat × List UInt8) := #[
  ("0", 0, [0x00]), ("1", 1, [0x01]), ("63", 63, [0x3f]), ("64", 64, [0x40]),
  ("127", 127, [0x7f]), ("128", 128, [0x80, 0x01]), ("255", 255, [0xff, 0x01]),
  ("300", 300, [0xac, 0x02]), ("16383", 16383, [0xff, 0x7f]), ("16384", 16384, [0x80, 0x80, 0x01]),
  ("624485", 624485, [0xe5, 0x8e, 0x26]),
  ("2^31 - 1", 2 ^ 31 - 1, [0xff, 0xff, 0xff, 0xff, 0x07]),
  ("2^31", 2 ^ 31, [0x80, 0x80, 0x80, 0x80, 0x08]),
  ("2^31 + 1", 2 ^ 31 + 1, [0x81, 0x80, 0x80, 0x80, 0x08]),
  ("2^32 - 1", 2 ^ 32 - 1, [0xff, 0xff, 0xff, 0xff, 0x0f]),
  ("2^32", 2 ^ 32, [0x80, 0x80, 0x80, 0x80, 0x10]),
  ("2^63 - 1", 2 ^ 63 - 1, List.replicate 8 0xff ++ [0x7f]),
  ("2^63", 2 ^ 63, List.replicate 9 0x80 ++ [0x01]),
  ("2^64 - 1", 2 ^ 64 - 1, List.replicate 9 0xff ++ [0x01]),
  ("2^64", 2 ^ 64, List.replicate 9 0x80 ++ [0x02]),
  ("2^64 + 1", 2 ^ 64 + 1, [0x81] ++ List.replicate 8 0x80 ++ [0x02]),
  ("2^100", 2 ^ 100, List.replicate 14 0x80 ++ [0x04]),
  ("2^127 + 2^64 + 5", 2 ^ 127 + 2 ^ 64 + 5,
    [0x85] ++ List.replicate 8 0x80 ++ [0x82] ++ List.replicate 8 0x80 ++ [0x02])
]

/-- Numbers and their SLEB128 encodings, computed with Python. -/
def intGoldens : Array (String × Int × List UInt8) := #[
  ("0", 0, [0x00]), ("1", 1, [0x01]), ("-1", -1, [0x7f]), ("63", 63, [0x3f]),
  ("-63", -63, [0x41]), ("64", 64, [0xc0, 0x00]), ("-64", -64, [0x40]),
  ("-65", -65, [0xbf, 0x7f]), ("127", 127, [0xff, 0x00]), ("-127", -127, [0x81, 0x7f]),
  ("128", 128, [0x80, 0x01]), ("-128", -128, [0x80, 0x7f]), ("-129", -129, [0xff, 0x7e]),
  ("-123456", -123456, [0xc0, 0xbb, 0x78]),
  ("2^31 - 1", 2 ^ 31 - 1, [0xff, 0xff, 0xff, 0xff, 0x07]),
  ("2^31", 2 ^ 31, [0x80, 0x80, 0x80, 0x80, 0x08]),
  ("-2^31", -2 ^ 31, [0x80, 0x80, 0x80, 0x80, 0x78]),
  ("-2^31 - 1", -2 ^ 31 - 1, [0xff, 0xff, 0xff, 0xff, 0x77]),
  ("2^32", 2 ^ 32, [0x80, 0x80, 0x80, 0x80, 0x10]),
  ("-2^32", -2 ^ 32, [0x80, 0x80, 0x80, 0x80, 0x70]),
  ("2^63 - 1", 2 ^ 63 - 1, List.replicate 9 0xff ++ [0x00]),
  ("2^63", 2 ^ 63, List.replicate 9 0x80 ++ [0x01]),
  ("-2^63", -2 ^ 63, List.replicate 9 0x80 ++ [0x7f]),
  ("-2^63 - 1", -2 ^ 63 - 1, List.replicate 9 0xff ++ [0x7e]),
  ("2^64", 2 ^ 64, List.replicate 9 0x80 ++ [0x02]),
  ("-2^64", -2 ^ 64, List.replicate 9 0x80 ++ [0x7e]),
  ("2^100", 2 ^ 100, List.replicate 14 0x80 ++ [0x04]),
  ("-2^100", -2 ^ 100, List.replicate 14 0x80 ++ [0x7c])
]

/-- How many bytes the LEB128 encoding of `n` takes: one per seven bits, at least one. -/
def natSize (n : Nat) : Nat := if n == 0 then 1 else n.log2 / 7 + 1

/-- How many bytes the SLEB128 encoding of `i` takes: the fewest `m` such that
`-2^(7m - 1) ≤ i < 2^(7m - 1)`. A `while` loop in `Id.run do` runs while its condition holds. -/
def intSize (i : Int) : Nat := Id.run do
  let mut m := 1
  while !(-(2 ^ (7 * m - 1) : Int) ≤ i && i < 2 ^ (7 * m - 1)) do
    m := m + 1
  return m

/-- Encodings that `readNat` reads at a position, and what it gives: the number and the position
after it, or `none` if the input ends first. Overlong encodings, with high groups of zeros, are
read as the number. -/
def readNatCases : Array (String × List UInt8 × Nat × Option (Nat × Nat)) := #[
  ("overlong 0", [0x80, 0x00], 0, some (0, 2)),
  ("overlong 127", [0xff, 0x00], 0, some (127, 2)),
  ("overlong 0 of 12 bytes", List.replicate 11 0x80 ++ [0x00], 0, some (0, 12)),
  ("overlong 1 of 22 bytes", [0x81] ++ List.replicate 20 0x80 ++ [0x00], 0, some (1, 22)),
  ("2^32 - 1", [0xff, 0xff, 0xff, 0xff, 0x0f], 0, some (2 ^ 32 - 1, 5)),
  ("at an offset", [0xaa, 0x80, 0x01, 0xbb], 1, some (128, 3)),
  ("the second of two", [0x05, 0x80, 0x01], 1, some (128, 3)),
  ("truncated: nothing", [], 0, none),
  ("truncated: one byte", [0x80], 0, none),
  ("truncated: three bytes", [0xff, 0xff, 0xff], 0, none),
  ("truncated: 2^63 without its last byte", List.replicate 9 0x80, 0, none),
  ("past the end", [0x00], 1, none),
  ("far past the end", [0x01], 5, none)
]

/-- Encodings that `readInt` reads at a position, and what it gives. -/
def readIntCases : Array (String × List UInt8 × Nat × Option (Int × Nat)) := #[
  ("overlong -1", [0xff, 0x7f], 0, some (-1, 2)),
  ("overlong -1 of 4 bytes", [0xff, 0xff, 0xff, 0x7f], 0, some (-1, 4)),
  ("-128", [0x80, 0x7f], 0, some (-128, 2)),
  ("127, not overlong when signed", [0xff, 0x00], 0, some (127, 2)),
  ("overlong -123456", [0xc0, 0xbb, 0xf8, 0x7f], 0, some (-123456, 4)),
  ("-16384", [0x80, 0x80, 0x7f], 0, some (-16384, 3)),
  ("overlong 0 of 12 bytes", List.replicate 11 0x80 ++ [0x00], 0, some (0, 12)),
  ("at an offset", [0x00, 0x7f], 1, some (-1, 2)),
  ("truncated: one byte", [0x80], 0, none),
  ("truncated: c0", [0xc0], 0, none),
  ("truncated: nothing", [], 0, none),
  ("past the end", [0x7f], 1, none)
]

/-- Numbers around powers of two: `2^k - 1`, `2^k` and `2^k + 1` for `k` up to 130. -/
def aroundPowers : Array Nat := Id.run do
  let mut out := #[0]
  for k in [0:131] do
    out := out.push (2 ^ k - 1) |>.push (2 ^ k) |>.push (2 ^ k + 1)
  return out

/-- The checks of LEB128: the goldens, both ways; reading overlong and truncated encodings; and
round trips of numbers around powers of two, with the length that the formulas above give. -/
def lebChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (name, n, bytes) in natGoldens do
    let enc := Leb128.ofNat n
    out := out.push <| check s!"leb128 of {name} is {hexList bytes}" (enc.toList == bytes)
      s!"got {hex enc}"
    out := out.push <| check s!"leb128 of {name} reads back"
      (Leb128.readNat ⟨bytes.toArray⟩ 0 == some (n, bytes.length))
      s!"got {Leb128.readNat ⟨bytes.toArray⟩ 0}"
  for (name, i, bytes) in intGoldens do
    let enc := Leb128.ofInt i
    out := out.push <| check s!"sleb128 of {name} is {hexList bytes}" (enc.toList == bytes)
      s!"got {hex enc}"
    out := out.push <| check s!"sleb128 of {name} reads back"
      (Leb128.readInt ⟨bytes.toArray⟩ 0 == some (i, bytes.length))
      s!"got {Leb128.readInt ⟨bytes.toArray⟩ 0}"
  for (name, bytes, pos, want) in readNatCases do
    let got := Leb128.readNat ⟨bytes.toArray⟩ pos
    out := out.push <| check s!"readNat {name}" (got == want) s!"got {got}"
  for (name, bytes, pos, want) in readIntCases do
    let got := Leb128.readInt ⟨bytes.toArray⟩ pos
    out := out.push <| check s!"readInt {name}" (got == want) s!"got {got}"
  -- Round trips, after a byte that is not part of the number, to read at an offset.
  let mut natBad := #[]
  let mut intBad := #[]
  for n in aroundPowers do
    let enc := Leb128.pushNat ⟨#[0xaa]⟩ n
    unless Leb128.readNat enc 1 == some (n, 1 + natSize n) && enc.size == 1 + natSize n do
      natBad := natBad.push n
    for i in [(n : Int), -(n : Int)] do
      let enc := Leb128.pushInt ⟨#[0xaa]⟩ i
      unless Leb128.readInt enc 1 == some (i, 1 + intSize i) && enc.size == 1 + intSize i do
        intBad := intBad.push i
  out := out.push <| check s!"leb128 round trips of {aroundPowers.size} numbers around 2^k, k ≤ 130"
    natBad.isEmpty s!"failed for {natBad.toList.take 5}"
  out := out.push <| check
    s!"sleb128 round trips of {2 * aroundPowers.size} numbers around ±2^k, k ≤ 130"
    intBad.isEmpty s!"failed for {intBad.toList.take 5}"
  return out

/-! ## idlHash -/

/-- Names and their ids, computed with Python. `dnctwrq` and `sbusnjd` have the same id. -/
def hashGoldens : Array (String × UInt32) := #[
  ("", 0), ("a", 97), ("Ok", 17724), ("Err", 3456837), ("name", 1224700491),
  ("head", 1158359328), ("tail", 1291237008), ("foo", 5097222), ("bar", 4895187),
  ("type", 1292432058), ("☃", 11272781), ("🐂", 2669435233), ("dnctwrq", 2270622235),
  ("sbusnjd", 2270622235), ("a long field name, longer than the others", 1336345060)
]

/-- The checks of `idlHash`. -/
def hashChecks (_ : Unit) : Array Check :=
  hashGoldens.map fun (name, id) =>
    check s!"idlHash {repr name} is {id}" (idlHash name == id) s!"got {idlHash name}"

/-! ## Principals -/

/-- Principals, by their bytes, and their text, computed with Python: the management canister,
the anonymous principal, a canister of the NNS (`rwlgt-…`), and the longest, of 29 bytes. -/
def principalGoldens : Array (List Nat × String) := #[
  ([], "aaaaa-aa"),
  ([4], "2vxsx-fae"),
  ([0xca, 0xff, 0xee], "w7x7r-cok77-xa"),
  ([0xef, 0xcd, 0xab, 0, 0, 0, 0, 0, 1], "2chl6-4hpzw-vqaaa-aaaaa-c"),
  ([0, 0, 0, 0, 0, 0, 0, 0, 1, 1], "rwlgt-iiaaa-aaaaa-aaaaa-cai"),
  ([0], "2ibo7-dia"),
  ([1, 2], "w3gef-eqbai"),
  (List.range 29, "2mhjn-ayaae-bagba-faydq-qcikb-mga2d-qpcai-reeyu-culbo-gazdi-nry"),
  (List.replicate 29 0xff, "tsdi7-6x777-77777-77777-77777-77777-77777-77777-77777-77777-776")
]

/-- Texts in upper or mixed case, and the bytes of their principals: the text is "parsed
case-insensitively", as the Internet Computer's specification says ("Textual representation of
principals"), and as the Rust crate `ic_principal` and the IC's own tests do. -/
def principalAnyCase : Array (String × List Nat) := #[
  ("AAAAA-AA", []), ("2VXSX-FAE", [4]), ("W7x7R-cOK77-Xa", [0xca, 0xff, 0xee]),
  ("RWLGT-IIAAA-AAAAA-AAAAA-CAI", [0, 0, 0, 0, 0, 0, 0, 0, 1, 1])
]

/-- Texts that are not principals, and a part of the error message: a wrong checksum (a character
changed, in either case, or one missing), bits set after the last byte (in either case), the
wrong grouping, a character that is not base32, too short, and 30 bytes. -/
def principalErrors : Array (String × String) := #[
  ("", "too short"), ("w7x7s-cok77-xa", "wrong checksum"), ("W7X7S-COK77-XA", "wrong checksum"),
  ("2vxsx-fbe", "wrong checksum"), ("2vxsx-fa", "wrong checksum"),
  ("aaaaa-ab", "expected \"aaaaa-aa\""), ("AAAAA-AB", "expected \"aaaaa-aa\""),
  ("w7x7r-cok77-xb", "expected \"w7x7r-cok77-xa\""), ("aaaaaaa", "expected \"aaaaa-aa\""),
  ("AAAAAAA", "expected \"aaaaa-aa\""), ("aaaaa-aa-", "expected \"aaaaa-aa\""),
  ("aaaaa--aa", "expected \"aaaaa-aa\""), ("aaaaa_aa", "not base32"),
  ("2vxsx-fae ", "not base32"),
  ("yvtf6-waaae-bagba-faydq-qcikb-mga2d-qpcai-reeyu-culbo-gazdi-nryhi", "longer than 63 characters"),
  -- Without its dashes, the text of 30 bytes is short enough to be decoded first.
  ("yvtf6waaaebagbafaydqqcikbmga2dqpcaireeyuculbogazdinryhi", "longer than 29 bytes")
]

/-- The checks of principals' text: both ways for the goldens, the two named principals, and the
errors of `fromText`. -/
def principalChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (bytes, text) in principalGoldens do
    let p : Principal := ⟨bytesOf bytes⟩
    out := out.push <| check s!"principal {text} to text" (p.toText == text)
      s!"got {repr p.toText}"
    out := out.push <| match Principal.fromText text with
      | .ok q => check s!"principal {text} from text" (q == p) s!"got {hex q.bytes}"
      | .error e => check s!"principal {text} from text" false s!"{e}"
  out := out.push <| check "Principal.managementCanister is aaaaa-aa"
    (Principal.managementCanister.toText == "aaaaa-aa")
  out := out.push <| check "Principal.anonymous is 2vxsx-fae"
    (Principal.anonymous.toText == "2vxsx-fae")
  for (text, bytes) in principalAnyCase do
    out := out.push <| match Principal.fromText text with
      | .ok p => check s!"principal {text} from text, in any case" (p == ⟨bytesOf bytes⟩)
          s!"got {hex p.bytes}"
      | .error e => check s!"principal {text} from text, in any case" false s!"{e}"
  for (text, part) in principalErrors do
    out := out.push <| match Principal.fromText text with
      | .ok p => check s!"principal {repr text} is invalid" false s!"got {hex p.bytes}"
      | .error e => check s!"principal {repr text} is invalid: {part}" (contains e.message part)
          e.message
  return out

/-! ## The text of types and interfaces -/

/-- The `List` of the interfaces below. -/
def listTy : Ty := .opt (.recordOf #[⟨.name "head", .int⟩, ⟨.name "tail", .var "List"⟩])

/-- Types and their text, as the Rust printer lays it out: fields and cases in the order of their
ids, tuples without labels, `blob` for `vec nat8`, names quoted where they must be, and a type too
long for a line of 80 columns broken over lines, but without the `;` that the Rust printer writes
after the last field of a broken record (see `Ty.format`). -/
def tyTexts : Array (String × Ty × String) := #[
  ("nat", .nat, "nat"),
  ("fields in id order", .opt (.vec (.recordOf #[⟨.name "a", .nat⟩, ⟨.num 1, .text⟩])),
    "opt vec record { 1 : text; a : nat }"),
  ("a tuple", .tuple #[.nat, .text], "record { nat; text }"),
  ("a variant with a null case", .variantOf #[⟨.name "some", .nat⟩, ⟨.name "none", .null⟩],
    "variant { none; some : nat }"),
  ("blob", .vec .nat8, "blob"),
  ("vec blob", .vec (.vec .nat8), "vec blob"),
  ("a query", .func #[.nat, .text] #[.bool] #[.query], "func (nat, text) -> (bool) query"),
  ("a oneway function", .func #[] #[] #[.oneway], "func () -> () oneway"),
  ("a composite query", .func #[] #[.nat] #[.compositeQuery], "func () -> (nat) composite_query"),
  ("a service, methods in order",
    .serviceOf #[⟨"put", .func #[.nat] #[] #[]⟩, ⟨"get", .func #[] #[.nat] #[.query]⟩],
    "service { get : () -> (nat) query; put : (nat) -> () }"),
  ("quoted names", .recordOf #[⟨.name "type", .nat⟩, ⟨.name "my field", .bool⟩],
    "record { \"type\" : nat; \"my field\" : bool }"),
  ("an escaped name", .recordOf #[⟨.name "a\"b", .nat⟩], "record { \"a\\\"b\" : nat }"),
  ("a name", .var "List", "List"),
  ("an empty record", .record #[], "record {}"),
  ("an empty variant", .variant #[], "variant {}"),
  ("the other primitive types", .tuple #[.principal, .reserved, .empty, .float32, .int64],
    "record { principal; reserved; empty; float32; int64 }"),
  ("a long record",
    .recordOf #[⟨.name "alpha_field_number_one", .nat⟩, ⟨.name "beta_field_number_two", .text⟩,
      ⟨.name "gamma_field_number_three", .bool⟩, ⟨.name "delta_field_number_four", .vec .nat⟩,
      ⟨.name "epsilon_field_number_five", .int⟩],
    "record {\n  alpha_field_number_one : nat;\n  beta_field_number_two : text;\n" ++
    "  gamma_field_number_three : bool;\n  epsilon_field_number_five : int;\n" ++
    "  delta_field_number_four : vec nat\n}")
]

/-- A `.did` file: a recursive definition and a service with two methods. -/
def iface : Interface :=
  { env := { defs := #[("List", listTy)] },
    service := some (.serviceOf #[⟨"put", .func #[.var "List"] #[] #[]⟩,
      ⟨"get", .func #[.nat] #[.opt (.var "List")] #[.query]⟩]) }

/-- Interfaces and their text. -/
def ifaceTexts : Array (String × Interface × String) := #[
  ("a definition and a service", iface,
    "type List = opt record { head : int; tail : List };\nservice : {\n" ++
    "  get : (nat) -> (opt List) query;\n  put : (List) -> ();\n}\n"),
  ("a service with initialization arguments", { iface with initArgs := some #[.nat, .text] },
    "type List = opt record { head : int; tail : List };\nservice : (nat, text) -> {\n" ++
    "  get : (nat) -> (opt List) query;\n  put : (List) -> ();\n}\n"),
  ("a service by name",
    { env := { defs := #[("S", .serviceOf #[⟨"m", .func #[] #[] #[]⟩])] },
      service := some (.var "S") },
    "type S = service { m : () -> () };\nservice : S\n"),
  ("definitions only", { env := { defs := #[("N", .nat), ("T", .tuple #[.var "N", .text])] } },
    "type N = nat;\ntype T = record { N; text };\n"),
  ("nothing", {}, "")
]

/-- Whether two interfaces are the same: definitions, initialization arguments and service. -/
def sameInterface (a b : Interface) : Bool :=
  a.env.defs == b.env.defs && a.initArgs == b.initArgs && a.service == b.service

/-- The checks of `Ty.toDid` and `Interface.toDid`, and of parsing the texts back. -/
def didChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (name, t, text) in tyTexts do
    out := out.push <| check s!"toDid of {name}: {repr text}" (t.toDid == text)
      s!"got {repr t.toDid}"
    out := out.push <| check s!"toDid of {name} parses back" (parseType text == .ok t)
      (showE (parseType text))
  for (name, i, text) in ifaceTexts do
    out := out.push <| check s!"Interface.toDid of {name}" (i.toDid == text) s!"got {repr i.toDid}"
    out := out.push <| match parseInterface text with
      | .ok j => check s!"Interface.toDid of {name} parses back" (sameInterface i j) j.toDid
      | .error e => check s!"Interface.toDid of {name} parses back" false s!"{e}"
  return out

/-! ## The typed layer

`Candid.encode` and `Candid.decode` with each `CandidType` instance of Candid/Class.lean. -/

/-- Whether two floats are the same: the same bits, or both NaN. -/
def sameFloat (a b : Float) : Bool := (a.isNaN && b.isNaN) || a.toBits == b.toBits

/-- Whether two 32-bit floats are the same: the same bits, or both NaN. -/
def sameFloat32 (a b : Float32) : Bool := (a.isNaN && b.isNaN) || a.toBits == b.toBits

/-- That `decode (encode x)`, at the Lean type of `x`, gives `x` back, as `same` compares, and that
the message is `golden`, if there is one. `[CandidArgs α]` asks Lean for the arguments' Candid
types, found from the Lean type `α` of `x`. `(e : T)` says that `e` has the type `T`, which tells
`Candid.decode` what to decode. -/
def typedTrip [CandidArgs α] (name : String) (x : α) (same : α → α → Bool)
    (golden : Option (List UInt8) := none) : Check :=
  match Candid.encode x with
  | .error e => check s!"typed {name}" false s!"encode: {e}"
  | .ok bytes =>
    if golden.any (· != bytes.toList) then check s!"typed {name}" false s!"got {hex bytes}"
    else match (Candid.decode bytes : Except Error α) with
      | .ok y => check s!"typed {name}" (same x y) "decode gave another value"
      | .error e => check s!"typed {name}" false s!"decode: {e}"

/-- `typedTrip` with `==` to compare. -/
def typedEq [CandidArgs α] [BEq α] (name : String) (x : α) (golden : Option (List UInt8) := none) :
    Check :=
  typedTrip name x (· == ·) golden

/-- The bytes `DIDL`, which start every message. -/
def didl : List UInt8 := [0x44, 0x49, 0x44, 0x4c]

/-- That the Candid type of `α`, as text, is `text`. -/
def tyIs (α : Type) [CandidType α] (text : String) : Check :=
  check s!"CandidType.ty is {text}" ((CandidType.ty α).toDid == text)
    s!"got {(CandidType.ty α).toDid}"

/-- That decoding `bytes` at the Lean type `α` gives `want`. -/
def decodesTo [CandidArgs α] [BEq α] (name : String) (bytes : ByteArray) (want : α) : Check :=
  match (Candid.decode bytes : Except Error α) with
  | .ok got => check s!"decode {name}" (got == want) "another value"
  | .error e => check s!"decode {name}" false s!"{e}"

/-- That decoding `bytes` at the Lean type `α` fails with an error that contains `part`. -/
def decodeFails (α : Type) [CandidArgs α] (name : String) (bytes : ByteArray) (part : String) :
    Check :=
  match (Candid.decode bytes : Except Error α) with
  | .ok _ => check s!"decode {name} fails" false "it succeeded"
  | .error e => check s!"decode {name} fails: {part}" (contains e.message part) e.message

/-- The message of `x`, or no bytes if it cannot be encoded (which a check then reports). -/
def encoded [CandidArgs α] (x : α) : ByteArray := (Candid.encode x).toOption.getD .empty

/-- Floats with their special values, by name: zeros of both signs, the largest, the smallest
subnormal, infinities and NaNs. `Float.ofBits` makes a float of its IEEE 754 bits. -/
def floats : Array (String × Float) :=
  #[("0", 0), ("-0", -0.0), ("1.5", 1.5), ("-2.25", -2.25), ("0.1", 0.1),
    ("the largest", Float.ofBits 0x7fefffffffffffff), ("the smallest", Float.ofBits 1),
    ("infinity", 1 / 0), ("-infinity", -1 / 0), ("NaN", 0 / 0),
    ("NaN with a payload", Float.ofBits 0x7ff0000000000001)]

/-- 32-bit floats with their special values, by name. -/
def floats32 : Array (String × Float32) :=
  #[("0", 0), ("-0", Float32.ofBits 0x80000000), ("1.5", 1.5), ("-2.25", -2.25), ("0.1", 0.1),
    ("the largest", Float32.ofBits 0x7f7fffff), ("the smallest", Float32.ofBits 1),
    ("infinity", 1 / 0), ("-infinity", -1 / 0), ("NaN", 0 / 0),
    ("NaN with a payload", Float32.ofBits 0x7f800001)]

/-- The checks of the typed layer: a round trip through each instance, with goldens for a few,
the Candid types of the instances, and decoding with coercions. -/
def typedChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  -- `()` as the arguments is no arguments; as a value, it is `null`.
  out := out.push <| typedTrip "()" () (fun _ _ => true) (golden := some (didl ++ [0x00, 0x00]))
  out := out.push <| typedEq "((), 5)" ((), (5 : Nat))
    (golden := some (didl ++ [0x00, 0x02, 0x7f, 0x7d, 0x05]))
  -- A `()` in a product is a `null`, wherever it is: `(5, ())` is two arguments, as `((), 5)` is.
  out := out.push <| typedEq "(5, ())" ((5 : Nat), ())
    (golden := some (didl ++ [0x00, 0x02, 0x7d, 0x7f, 0x05]))
  out := out.push <| typedEq "((), ())" ((), ())
    (golden := some (didl ++ [0x00, 0x02, 0x7f, 0x7f]))
  out := out.push <| typedEq "(true, 5, ())" (true, (5 : Nat), ())
    (golden := some (didl ++ [0x00, 0x03, 0x7e, 0x7d, 0x7f, 0x01, 0x05]))
  out := out.push <| check "Candid.method with a () last in a product"
    ((Candid.method "m" (Nat × Unit) Unit).ty.toDid == "func (nat, null) -> ()")
    s!"got {(Candid.method "m" (Nat × Unit) Unit).ty.toDid}"
  out := out.push <| typedEq "true" true (golden := some (didl ++ [0x00, 0x01, 0x7e, 0x01]))
  out := out.push <| typedEq "false" false
  for n in [0, 1, 2 ^ 31 - 1, 2 ^ 31, 2 ^ 32, 2 ^ 63 - 1, 2 ^ 63, 2 ^ 64, 2 ^ 100 + 7] do
    out := out.push <| typedEq s!"(Nat) {n}" n
  for i in ([0, -1, 2 ^ 31 - 1, -2 ^ 31, 2 ^ 31, -2 ^ 31 - 1, 2 ^ 63, -2 ^ 63, -2 ^ 64, 2 ^ 100,
      -2 ^ 100] : List Int) do
    out := out.push <| typedEq s!"(Int) {i}" i
  out := out.push <| typedEq "(UInt8) 255" (255 : UInt8)
  out := out.push <| typedEq "(UInt16) 65535" (65535 : UInt16)
  out := out.push <| typedEq "(UInt32) 2^31" (2147483648 : UInt32)
  out := out.push <| typedEq "(UInt32) 2^32 - 1" (4294967295 : UInt32)
  out := out.push <| typedEq "(UInt64) 2^63" (9223372036854775808 : UInt64)
  out := out.push <| typedEq "(UInt64) 2^64 - 1" (18446744073709551615 : UInt64)
  out := out.push <| typedEq "(Int8) -128" (-128 : Int8)
  out := out.push <| typedEq "(Int16) -32768" (-32768 : Int16)
  out := out.push <| typedEq "(Int32) -2^31" (-2147483648 : Int32)
  out := out.push <| typedEq "(Int32) 2^31 - 1" (2147483647 : Int32)
  out := out.push <| typedEq "(Int64) -2^63" (-9223372036854775808 : Int64)
  out := out.push <| typedEq "(Int64) 2^63 - 1" (9223372036854775807 : Int64)
  out := out.push <| typedEq "(Int64) -1" (-1 : Int64)
    (golden := some (didl ++ [0x00, 0x01, 0x74] ++ List.replicate 8 0xff))
  for (name, x) in floats do
    out := out.push <| typedTrip s!"(Float) {name}" x sameFloat
  for (name, x) in floats32 do
    out := out.push <| typedTrip s!"(Float32) {name}" x sameFloat32
  for s in ["", "hello", "☃🐂", "\x00", "".pushn 'é' 10000] do
    out := out.push <| typedEq s!"(String) of length {s.length}" s
  for p in [Principal.managementCanister, Principal.anonymous, ⟨bytesOf (List.range 29)⟩] do
    out := out.push <| typedEq s!"(Principal) of {p.bytes.size} bytes" p
  out := out.push <| typedEq "(Reserved)" ({} : Reserved)
    (golden := some (didl ++ [0x00, 0x01, 0x70]))
  out := out.push <| typedEq "(Option Nat) none" (none : Option Nat)
  out := out.push <| typedEq "(Option Nat) some 5" (some 5 : Option Nat)
  out := out.push <| typedEq "(Option (Option (Option Nat))) some (some none)"
    (some (some none) : Option (Option (Option Nat)))
  out := out.push <| typedEq "(Option Unit) some ()" (some () : Option Unit)
  out := out.push <| typedEq "(Array Nat) empty" (#[] : Array Nat)
  out := out.push <| typedEq "(Array Nat)" (#[1, 2, 2 ^ 70] : Array Nat)
  out := out.push <| typedEq "(Array (Array String))" (#[#[], #["a", "b"]] : Array (Array String))
  out := out.push <| typedEq "(Array UInt8), a blob" (#[0, 1, 255] : Array UInt8)
    (golden := some (didl ++ [0x01, 0x6d, 0x7b, 0x01, 0x00, 0x03, 0x00, 0x01, 0xff]))
  out := out.push <| typedEq "(List Int)" ([-1, 0, 2 ^ 40] : List Int)
  out := out.push <| typedEq "(List String) empty" ([] : List String)
  out := out.push <| typedEq "(ByteArray) empty" ByteArray.empty
  out := out.push <| typedEq "(ByteArray)" (bytesOf [0, 255, 1])
  out := out.push <| typedEq "(ByteArray) of 100000 bytes"
    (bytesOf ((List.range 100000).map (· % 251)))
  out := out.push <| typedEq "(Except String Nat) ok" (.ok 5 : Except String Nat)
  out := out.push <| typedEq "(Except String Nat) error" (.error "boom" : Except String Nat)
  out := out.push <| typedEq "(String × Nat × Option Nat)" ("world", (3 : Nat), (none : Option Nat))
    (golden := some (didl ++ [0x01, 0x6e, 0x7d, 0x03, 0x71, 0x7d, 0x00, 0x05] ++
      "world".toUTF8.toList ++ [0x03, 0x00]))
  out := out.push <| typedEq "(Bool × Int8 × List Nat × Option String)"
    (false, (-3 : Int8), ([1, 2] : List Nat), (some "x" : Option String))
  -- The Candid types of the instances.
  out := out.push <| tyIs Unit "null"
  out := out.push <| tyIs Int "int"
  out := out.push <| tyIs Float "float64"
  out := out.push <| tyIs Float32 "float32"
  out := out.push <| tyIs Reserved "reserved"
  out := out.push <| tyIs Empty "empty"
  out := out.push <| tyIs Principal "principal"
  out := out.push <| tyIs ByteArray "blob"
  out := out.push <| tyIs (Array UInt8) "blob"
  out := out.push <| tyIs (List (Option Int16)) "vec opt int16"
  out := out.push <| tyIs (Except String Nat) "variant { Ok : nat; Err : text }"
  -- Decoding with the coercion rules: `nat` at `int`, an extra argument, a missing one, and the
  -- errors of a missing argument, a value of another type, and a value of type `empty`.
  out := out.push <| decodesTo "(nat) at Int" (encoded (5 : Nat)) (5 : Int)
  out := out.push <| decodesTo "(bool, nat) at Bool" (encoded (true, (5 : Nat))) true
  out := out.push <| decodesTo "() at Option Nat" (encoded ()) (none : Option Nat)
  out := out.push <| decodesTo "(opt nat) at Option (Option Nat)" (encoded (some 5 : Option Nat))
    (some (some 5) : Option (Option Nat))
  out := out.push <| decodesTo "(blob) at ByteArray" (encoded (#[1, 2] : Array UInt8))
    (bytesOf [1, 2])
  out := out.push <| decodesTo "(blob) at List UInt8" (encoded (bytesOf [1, 2]))
    ([1, 2] : List UInt8)
  out := out.push <| decodeFails Nat "() at Nat" (encoded ()) "No more values"
  out := out.push <| decodeFails String "(nat) at String" (encoded (5 : Nat))
    "nat cannot be deserialized to text"
  out := out.push <| decodeFails Empty "(empty) at Empty"
    (bytesOf (didl.map (·.toNat) ++ [0, 1, 0x6f])) "Cannot decode empty type"
  out := out.push <| decodesTo "() at Option Empty" (encoded ()) (none : Option Empty)
  return out

/-! ## A pseudo-random generator -/

/-- Computations that draw pseudo-random numbers: `StateM UInt64 α` takes the generator's state, a
`UInt64`, and returns an `α` and the next state. -/
abbrev Gen := StateM UInt64

/-- The next state, which is also the number drawn: Knuth's linear congruential generator of MMIX,
`s * 6364136223846793005 + 1442695040888963407`, which wraps around at 2^64 as `UInt64` arithmetic
does. `modifyGet f` replaces the state `s` with the second part of `f s`, and returns the first. -/
def next : Gen UInt64 :=
  modifyGet fun s => let s' := s * 6364136223846793005 + 1442695040888963407; (s', s')

/-- A number below `n`, or 0 if `n` is 0, from the high 32 bits of the next state, which are more
random than the low ones. -/
def below (n : Nat) : Gen Nat := do
  let s ← next
  return if n == 0 then 0 else (s >>> 32).toNat % n

/-- True once in `n` times. -/
def oneIn (n : Nat) : Gen Bool := return (← below n) == 0

/-- 64 random bits, the high halves of two states. -/
def bits64 : Gen UInt64 := do
  let hi ← next
  let lo ← next
  return (hi &&& (0xFFFFFFFF00000000 : UInt64)) ||| (lo >>> 32)

/-- An element of a non-empty array. `[Inhabited α]` gives `xs[i]!` a default value, should the
index be out of bounds. -/
def pick {α} [Inhabited α] (xs : Array α) : Gen α := return xs[← below xs.size]!

/-- `n` values that `g` draws. -/
def many (n : Nat) (g : Gen α) : Gen (Array α) := do
  let mut out := #[]
  for _ in [0:n] do
    out := out.push (← g)
  return out

/-- A number of at most `bits` bits, built from 64 bits at a time. -/
def natBits (bits : Nat) : Gen Nat := do
  let mut n := 0
  for _ in [0:(bits + 63) / 64] do
    n := n * 2 ^ 64 + (← bits64).toNat
  return n % 2 ^ bits

/-- Numbers at the edges: where a `Nat` stops fitting in a machine word on wasm32 (2^31) and
natively (2^63), and the ends of `nat32` and `nat64`. -/
def edgeNats : Array Nat :=
  #[0, 1, 127, 128, 2 ^ 31 - 1, 2 ^ 31, 2 ^ 31 + 1, 2 ^ 32 - 1, 2 ^ 32, 2 ^ 32 + 1, 2 ^ 63 - 1,
    2 ^ 63, 2 ^ 63 + 1, 2 ^ 64 - 1, 2 ^ 64, 2 ^ 64 + 1, 2 ^ 100, 2 ^ 128 - 1]

/-- A number: an edge, or one of up to 70 or 300 bits. -/
def genNat : Gen Nat := do
  match ← below 3 with
  | 0 => pick edgeNats
  | 1 => natBits (← below 70)
  | _ => natBits (← below 300)

/-- A number of either sign. -/
def genInt : Gen Int := do
  let n ← genNat
  return if ← oneIn 2 then -(n : Int) else n

/-- A float: a special value, or any bits, which may be those of a NaN or a subnormal. -/
def genFloat : Gen Float := do
  if ← oneIn 4 then return (← pick floats).2 else return Float.ofBits (← bits64)

/-- A 32-bit float: a special value, or any bits. -/
def genFloat32 : Gen Float32 := do
  if ← oneIn 4 then return (← pick floats32).2 else return Float32.ofBits (← bits64).toUInt32

/-- Characters of one to four bytes in UTF-8, and control characters. -/
def chars : Array Char := #['a', 'Z', '0', ' ', '"', '\\', '\n', '\x00', '\x7f', 'é', '☃', '🐂', '中']

/-- A text of up to 20 characters, or now and then up to 1000. -/
def genText : Gen String := do
  let n ← if ← oneIn 20 then below 1000 else below 20
  return (← many n (pick chars)).foldl (·.push ·) ""

/-- Up to 40 bytes, or now and then up to 2000. -/
def genBytes : Gen ByteArray := do
  let n ← if ← oneIn 20 then below 2000 else below 40
  return ⟨← many n do return (← bits64).toUInt8⟩

/-- A principal of up to 29 bytes. -/
def genPrincipal : Gen Principal := do
  return ⟨⟨← many (← below 30) do return (← bits64).toUInt8⟩⟩

/-! ## Generated types and values -/

/-- Definitions that generated types refer to: recursive ones (a list, a tree, two types that
refer to each other, a stream of tuples), names for names and for primitive types, and a function
and a service that refer to them. -/
def env : TypeEnv := { defs := #[
  ("List", listTy),
  ("Tree", .variantOf #[⟨.name "leaf", .nat⟩,
    ⟨.name "node", .recordOf #[⟨.name "left", .var "Tree"⟩, ⟨.name "right", .var "Tree"⟩]⟩]),
  ("A", .recordOf #[⟨.name "name", .text⟩, ⟨.name "next", .opt (.var "B")⟩]),
  ("B", .vec (.var "A")),
  ("Stream", .opt (.tuple #[.nat64, .var "Stream"])),
  ("Bytes", .vec (.var "N8")),
  ("N8", .nat8),
  ("Alias", .var "List"),
  ("N", .nat),
  ("F", .func #[.var "List"] #[.var "Tree"] #[.query]),
  ("S", .serviceOf #[⟨"get", .var "F"⟩, ⟨"self", .func #[] #[.var "S"] #[]⟩])
] }

/-- The names that `env` defines. -/
def envNames : Array String := env.defs.map (·.1)

/-- The primitive types that have values, and `opt empty`, whose only value is `null`. -/
def primTys : Array Ty :=
  #[.null, .bool, .nat, .int, .nat8, .nat16, .nat32, .nat64, .int8, .int16, .int32, .int64,
    .float32, .float64, .text, .reserved, .principal, .opt .empty]

/-- Field names, among them some that the text format quotes. -/
def labelNames : Array String := #["a", "b", "head", "tail", "☃", "type", "", "a b", "🐂", "Ok"]

/-- A field label: a number, among them the largest and 2^31, or a name. -/
def genLabel : Gen Label := do
  if ← oneIn 2 then return .num (← pick #[0, 1, 2, 3, 42, 97, 2147483648, 4294967295])
  return .name (← pick labelNames)

/-- The fields, without those whose id an earlier one has. -/
def dedup (fs : Array Field) : Array Field :=
  fs.foldl (init := #[]) fun acc f => if acc.any (·.label.id == f.label.id) then acc else acc.push f

/-- Method names, which need not be identifiers. -/
def methodNames : Array String := #["get", "put", "", "🐂", "a b", "query"]

mutual

/-- A type of at most `depth` levels of composite types, whose names are those of `env`. -/
partial def genTy (depth : Nat) : Gen Ty := do
  if depth == 0 then
    if ← oneIn 4 then return .var (← pick envNames)
    return (← pick primTys)
  match ← below 12 with
  | 0 | 1 | 2 => pick primTys
  | 3 => return .var (← pick envNames)
  | 4 => return .opt (← genTy (depth - 1))
  | 5 => return .vec (← genTy (depth - 1))
  | 6 => return .blob
  | 7 =>
    let fields ← many (← below 6) do return ⟨← genLabel, ← genTy (depth - 1)⟩
    return .recordOf (dedup fields)
  | 8 => return .tuple (← many (← below 4) (genTy (depth - 1)))
  | 9 =>
    let cases ← many (1 + (← below 5)) do return ⟨← genLabel, ← genTy (depth - 1)⟩
    return .variantOf (dedup cases)
  | 10 => genFunc (depth - 1)
  | _ =>
    let methods ← many (← below 4) do return ⟨← pick methodNames, ← genFunc (depth - 1)⟩
    let unique := methods.foldl (init := #[]) fun (acc : Array Method) m =>
      if acc.any (·.name == m.name) then acc else acc.push m
    return .serviceOf unique

/-- A function type, with at most one mode; a `oneway` function has no results. -/
partial def genFunc (depth : Nat) : Gen Ty := do
  let args ← many (← below 3) (genTy depth)
  let rets ← many (← below 3) (genTy depth)
  let modes : Array FuncMode := match ← below 4 with
    | 0 => #[.query]
    | 1 => #[.compositeQuery]
    | 2 => if rets.isEmpty then #[.oneway] else #[]
    | _ => #[]
  return .func args rets modes

end

/-- Whether `t` stands for `nat8`, through names. -/
def isNat8 (t : Ty) : Bool := env.resolve #[] t matches .ok .nat8

/-- The case of a variant to take where the value may nest no deeper: one whose type is primitive,
if there is one, as `leaf` is for `Tree`. -/
def baseCase (cases : Array Field) : Field :=
  (cases.find? fun c => (env.resolve #[] c.ty).toOption.any Ty.isPrimitive).getD cases[0]!

/-- A value of the type `t`, nested at most `depth` levels in options, vectors and the cases of
variants. A `vec nat8` is a blob or a vector of `nat8` values, and a record's fields are in the
type's order or the reverse, which the encoder accepts alike. -/
partial def genValue (t : Ty) (depth : Nat) : Gen Value := do
  match t with
  | .var name => genValue ((env.find? name).getD .null) depth
  | .null => return .null
  | .bool => return .bool (← oneIn 2)
  | .nat => return .nat (← genNat)
  | .int => return .int (← genInt)
  | .nat8 => return .nat8 (← bits64).toUInt8
  | .nat16 => return .nat16 (← bits64).toUInt16
  | .nat32 => return .nat32 (← bits64).toUInt32
  | .nat64 => return .nat64 (← bits64)
  | .int8 => return .int8 (← bits64).toUInt8.toInt8
  | .int16 => return .int16 (← bits64).toUInt16.toInt16
  | .int32 => return .int32 (← bits64).toUInt32.toInt32
  | .int64 => return .int64 (← bits64).toInt64
  | .float32 => return .float32 (← genFloat32)
  | .float64 => return .float64 (← genFloat)
  | .text => return .text (← genText)
  | .reserved => return .reserved
  | .principal => return .principal (← genPrincipal)
  | .opt e =>
    if depth == 0 || e == .empty || (← oneIn 3) then return .opt none
    return .opt (some (← genValue e (depth - 1)))
  | .vec e =>
    if isNat8 e then
      let bytes ← genBytes
      return if ← oneIn 2 then .blob bytes else .vec (bytes.toList.toArray.map .nat8)
    let n ← if depth == 0 then pure 0 else below 4
    return .vec (← many n (genValue e (depth - 1)))
  | .record fields =>
    let values ← fields.mapM fun f => do return (f.label, ← genValue f.ty depth)
    return .record (if ← oneIn 3 then values.reverse else values)
  | .variant cases =>
    let c ← if depth == 0 then pure (baseCase cases) else pick cases
    return .variant c.label (← genValue c.ty (depth - 1))
  | .func .. => return .func (← genPrincipal) (← pick methodNames)
  | .service _ => return .service (← genPrincipal)
  | _ => return .null

/-- The value that decoding `v`, of the type `t`, gives: a `vec nat8` is a blob, and a record's
fields are in the type's order, with its labels, as are the cases of variants. -/
partial def expected (t : Ty) (v : Value) : Value :=
  match (env.resolve #[] t).toOption.getD t, v with
  | .opt e, .opt (some v) => .opt (some (expected e v))
  | .vec e, .vec vs =>
    if isNat8 e then .blob ⟨vs.filterMap fun | .nat8 b => some b | _ => none⟩
    else .vec (vs.map (expected e))
  | .record fields, .record values =>
    .record (fields.filterMap fun f =>
      (values.find? (·.1.id == f.label.id)).map fun (_, v) => (f.label, expected f.ty v))
  | .variant cases, .variant l v =>
    match cases.find? (·.label.id == l.id) with
    | some c => .variant c.label (expected c.ty v)
    | none => .variant l v
  | _, v => v

/-- Whether two values are the same: floats by their bits, or both NaN; labels by their ids. -/
partial def sameValue : Value → Value → Bool
  | .float32 a, .float32 b => sameFloat32 a b
  | .float64 a, .float64 b => sameFloat a b
  | .opt (some a), .opt (some b) => sameValue a b
  | .vec as, .vec bs => as.size == bs.size && (as.zip bs).all fun (a, b) => sameValue a b
  | .record as, .record bs =>
    as.size == bs.size && (as.zip bs).all fun ((l, a), (m, b)) => l.id == m.id && sameValue a b
  | .variant l a, .variant m b => l.id == m.id && sameValue a b
  | a, b => a == b

/-- Whether two arrays of values are the same, value by value. -/
def sameValues (as bs : Array Value) : Bool :=
  as.size == bs.size && (as.zip bs).all fun (a, b) => sameValue a b

/-- The arguments of a message, for the line of a check that fails. -/
def describe (args : Array (Ty × Value)) (bytes : ByteArray) : String :=
  let shown := args.toList.map fun (t, v) => s!"{v.toTextCapped} : {t.toDidCapped}"
  s!"{capped (toString shown) 600}; bytes {hex bytes}"

/-- That a message of `args` round-trips: `encodeValues` writes it, `decodeValues` at the same
types gives back the values, as `expected` says, `decodeAny` gives them too, at the message's own
types, and encoding the decoded values gives the same bytes again. -/
def roundTrip (name : String) (args : Array (Ty × Value)) (config : DecodeConfig := {}) : Check :=
  let tys := args.map (·.1)
  let want := args.map fun (t, v) => expected t v
  match encodeValues env args with
  | .error e => check name false s!"encode: {e}; {describe args .empty}"
  | .ok bytes =>
    match decodeValues env tys bytes config with
    | .error e => check name false s!"decode: {e}; {describe args bytes}"
    | .ok got =>
      if !sameValues got want then
        check name false s!"decode gave {capped (toString got.toList) 600}; {describe args bytes}"
      else match decodeAny bytes config with
        | .error e => check name false s!"decodeAny: {e}; {describe args bytes}"
        | .ok (_, wire) =>
          if !sameValues (wire.map (·.2)) want then
            check name false s!"decodeAny gave other values; {describe args bytes}"
          else match encodeValues env (tys.zip got) with
            | .ok again => check name (again == bytes)
                s!"the decoded values encode to {hex again}; {describe args bytes}"
            | .error e => check name false s!"encoding the decoded values: {e}"

/-- The arguments of a message: up to four, of generated types, with generated values. -/
def genMessage : Gen (Array (Ty × Value)) := do
  many (← below 5) do
    let t ← genTy (1 + (← below 3))
    return (t, ← genValue t (2 + (← below 5)))

/-- Messages of up to four arguments of generated types, with generated values. -/
def generatedChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  let mut seed : UInt64 := 20261019
  for i in [0:1500] do
    let (args, s) := genMessage.run seed
    seed := s
    out := out.push (roundTrip s!"generated message {i}" args)
  return out

/-- Numbers at and around the edges, and random ones, at every type of number; and `nat`s read
as `int`s, as the coercion rules allow. -/
def numberChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for n in edgeNats do
    out := out.push <| roundTrip s!"nat {n}" #[(.nat, .nat n)]
    out := out.push <| roundTrip s!"int {n}" #[(.int, .int n)]
    out := out.push <| roundTrip s!"int -{n}" #[(.int, .int (-(n : Int)))]
    out := out.push <| roundTrip s!"nat64, int64, nat32, int32 of {n}"
      #[(.nat64, .nat64 n.toUInt64), (.int64, .int64 (Int64.ofInt n)), (.nat32, .nat32 n.toUInt32),
        (.int32, .int32 (Int32.ofInt (-(n : Int))))]
    let wire := (encodeValues {} #[(.nat, .nat n)]).toOption.getD .empty
    out := out.push <| check s!"nat {n} at int" (decodeValues {} #[.int] wire == .ok #[.int n])
      (showE (decodeValues {} #[.int] wire))
  let mut seed : UInt64 := 0xC0FFEE
  for i in [0:500] do
    let (args, s) := (do return #[(Ty.nat, Value.nat (← genNat)), (Ty.int, Value.int (← genInt)),
      (Ty.vec .int, Value.vec (← many 3 do return Value.int (← genInt)))] : Gen _).run seed
    seed := s
    out := out.push (roundTrip s!"random numbers {i}" args)
  return out

/-- Floats of any bits, NaNs and subnormals among them, at both widths. -/
def floatChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (name, x) in floats do
    out := out.push <| roundTrip s!"float64 {name}" #[(.float64, .float64 x)]
  for (name, x) in floats32 do
    out := out.push <| roundTrip s!"float32 {name}" #[(.float32, .float32 x)]
  let mut seed : UInt64 := 0xF10A7
  for i in [0:300] do
    let (args, s) := (do return #[(Ty.float64, Value.float64 (Float.ofBits (← bits64))),
      (Ty.float32, Value.float32 (Float32.ofBits (← bits64).toUInt32)),
      (Ty.vec .float64, Value.vec (← many 4 do return Value.float64 (← genFloat)))] : Gen _).run
        seed
    seed := s
    out := out.push (roundTrip s!"random floats {i}" args)
  return out

/-- `n` levels of `wrap` around `x`. -/
def nest (n : Nat) (wrap : α → α) (x : α) : α := (List.range n).foldl (fun x _ => wrap x) x

/-- The `List` of `n` elements, `opt record { head = n - 1; tail = … }`, nested `2n + 1` levels
deep. -/
def listOf (n : Nat) : Value :=
  nest n (fun v => .opt (some (.record #[(.name "head", .int 7), (.name "tail", v)]))) (.opt none)

/-- A complete `Tree` of depth `d`. -/
def treeOf : Nat → Value
  | 0 => .variant (.name "leaf") (.nat 1)
  | d + 1 =>
    .variant (.name "node") (.record #[(.name "left", treeOf d), (.name "right", treeOf d)])

/-- Deeply nested values, up to 400 levels, within the decoder's limit of 512, and one that goes
past it, which the decoder rejects before it recurses further. -/
def deepChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  out := out.push <| roundTrip "400 levels of opt"
    #[(nest 400 .opt .nat, nest 400 (fun v => .opt (some v)) (.nat 5))]
  out := out.push <| roundTrip "400 levels of vec"
    #[(nest 400 .vec .nat, nest 400 (fun v => .vec #[v]) (.nat 5))]
  out := out.push <| roundTrip "300 levels of record"
    #[(nest 300 (fun t => .tuple #[t]) .nat, nest 300 (fun v => .record #[(.num 0, v)]) (.nat 5))]
  out := out.push <| roundTrip "300 levels of variant"
    #[(nest 300 (fun t => .variant #[⟨.num 1, t⟩]) .text,
      nest 300 (fun v => .variant (.num 1) v) (.text "deep"))]
  out := out.push <| roundTrip "a List of 200 elements" #[(.var "List", listOf 200)]
  out := out.push <| roundTrip "a Tree of depth 10" #[(.var "Tree", treeOf 10)]
  let tooDeep := encodeValues {} #[(nest 600 .opt .nat, nest 600 (fun v => .opt (some v)) (.nat 5))]
  out := out.push <| match tooDeep with
    | .ok bytes => match decodeValues {} #[nest 600 .opt .nat] bytes with
      | .ok _ => check "600 levels of opt fail to decode" false "decoded"
      | .error e => check "600 levels of opt fail to decode: Recursion limit exceeded"
          (contains e.message "Recursion limit exceeded") e.message
    | .error e => check "600 levels of opt fail to decode" false s!"encode: {e}"
  return out

/-- Wide values: long vectors, blobs and texts, records and variants of 300 fields, and messages of
300 arguments. -/
def wideChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  let (nats, seed) := (many 20000 genNat).run 7
  out := out.push <| roundTrip "a vec of 20000 nats" #[(.vec .nat, .vec (nats.map .nat))]
  let (bytes, seed) := (many 100000 do return (← bits64).toUInt8).run seed
  out := out.push <| roundTrip "a blob of 100000 bytes" #[(.blob, .blob ⟨bytes⟩)]
  let (text, seed) := (many 50000 (pick chars)).run seed
  out := out.push <| roundTrip "a text of 50000 characters"
    #[(.text, .text (text.foldl (·.push ·) ""))]
  let ids := (Array.range 300).map fun i => (i * 14318057 % 2 ^ 32).toUInt32
  let fields : Array Field := ids.map fun id => ⟨.num id, .text⟩
  out := out.push <| roundTrip "a record of 300 fields"
    #[(.recordOf fields, .record (ids.map fun id => (.num id, .text s!"field {id}")))]
  out := out.push <| roundTrip "a variant of 300 cases, the last"
    #[(.variantOf fields, .variant (.num ids[299]!) (.text "last"))]
  let (args, _) := (many 300 do
    let t ← genTy 1
    return (t, ← genValue t 2)).run seed
  out := out.push <| roundTrip "300 arguments" args
  let record := Ty.recordOf #[⟨.name "a", .nat⟩, ⟨.name "b", .text⟩]
  out := out.push <| roundTrip "a vec of 2000 records" #[(.vec record,
    .vec ((Array.range 2000).map fun i =>
      .record #[(.name "a", .nat i), (.name "b", .text s!"{i}")]))]
  return out

/-! ## Capped texts

`Value.toTextCapped` writes only as much of a value as it shows, which must be the start of what
`Value.toText` writes, but for numbers too long to show in decimal, which it writes in
hexadecimal. -/

/-- Values with long parts, the length to cut their text at, and their capped text, when it is not
`toText` cut there: `none`. -/
def cappedCases : Array (String × Value × Nat × Option String) := #[
  ("a long text", .text ("".pushn 'é' 150), 100, none),
  ("a long method name", .func Principal.anonymous ("".pushn 'm' 200 ++ " "), 100, none),
  ("a long blob", .blob ⟨(Array.range 300).map (·.toUInt8)⟩, 100, none),
  ("300 options", nest 300 (fun v => .opt (some v)) (.nat 5), 100, none),
  ("a long vector", .vec (Array.replicate 300 (.int (-7))), 100, none),
  ("a record of long names",
    .record #[(.name ("".pushn 'x' 80), .nat 1), (.name "y z", .text ("".pushn 'w' 80))], 100,
    none),
  ("empty ones", .record #[(.num 0, .vec #[]), (.num 1, .record #[]), (.num 2, .blob .empty)], 100,
    none),
  ("a nat of 399 bits, in decimal", .nat (2 ^ 399), 100, none),
  ("a nat of 501 bits, in hexadecimal", .nat (2 ^ 500), 100,
    some ("0x1" ++ "".pushn '0' 97 ++ "…")),
  ("an int of 501 bits, in hexadecimal", .int (-2 ^ 500 - 1), 100,
    some ("-0x1" ++ "".pushn '0' 96 ++ "…")),
  ("a nat of 21 bits at 5 characters", .nat (2 ^ 20 + 2 ^ 19), 5, some "0x180…"),
  ("a short value", .variant (.name "ok") (.opt (some (.nat 1))), 100, none)
]

/-- The checks of capped texts: the cases above, and the values of the generated messages. -/
def cappedChecks (_ : Unit) : Array Check := Id.run do
  let mut out := #[]
  for (name, v, max, want) in cappedCases do
    let want := want.getD (capped v.toText max)
    out := out.push <| check s!"the capped text of {name}" (v.toTextCapped max == want)
      s!"got {repr (v.toTextCapped max)}, not {repr want}"
  let mut seed : UInt64 := 20261019
  let mut bad := #[]
  for i in [0:1500] do
    let (args, s) := genMessage.run seed
    seed := s
    for (_, v) in args do
      unless v.toTextCapped == capped v.toText 100 do
        bad := bad.push i
  out := out.push <| check "the capped texts of the values of 1500 generated messages"
    bad.isEmpty s!"not for messages {bad.toList.take 5}"
  return out

/-! ## Work

A canister must answer within its instruction limit whatever a message holds, so the work of
encoding, decoding and writing error messages must grow about as the size of what they work on,
not as its square: a number of a million bits must not take a million steps of a million bits
each. These checks time such work, and fail if it takes longer than a bound: about ten times
what it takes with `lean --run`, which interprets the library's code (on wasm32, where it is
compiled, it takes less), and less than what it took when it grew as the square of the size.
They print no times, so that their output is the same on every machine, and on wasm32. -/

/-- A check that `f` gives `true`, and takes less than `limit` milliseconds. `f` gets the time at
which it starts, and its result must depend on it: Lean computes an expression that depends on
nothing once, when the program starts, which is before the time is taken. Storing the result in
a reference, with an `IO` action, makes Lean compute it before the time is taken again. -/
def workCheck (name : String) (limit : Nat) (f : Nat → Bool) : IO Check := do
  let result ← IO.mkRef false
  let start ← IO.monoMsNow
  result.set (f start)
  let ms := (← IO.monoMsNow) - start
  return check s!"{name} takes less than {limit} ms" ((← result.get) && ms < limit)
    s!"gave {← result.get}, in {ms} ms"

/-- The checks of work: LEB128 of numbers of millions of bits, both ways, also in messages, and
the capped text of values with such a number, a long text deep in options, and a long vector. -/
def workChecks : IO (Array Check) := do
  let bits := 2 ^ 21
  let mut out := #[]
  out := out.push (← workCheck s!"a nat of 2^22 bits to LEB128 and back" 5000 fun t =>
    let n := 2 ^ (2 * bits) - 1 - t % 2
    let bytes := Leb128.ofNat n
    bytes.size == (2 * bits + 6) / 7 && Leb128.readNat bytes 0 == some (n, bytes.size))
  out := out.push (← workCheck s!"an int of 2^21 bits to SLEB128 and back" 5000 fun t =>
    let i := -((2 ^ bits - t % 2 : Nat) : Int)
    let bytes := Leb128.ofInt i
    bytes.size == (bits + 7) / 7 && Leb128.readInt bytes 0 == some (i, bytes.size))
  out := out.push (← workCheck s!"a message of a nat and an int of 2^21 bits, encoded and decoded"
      5000 fun t =>
    let args := #[(Ty.nat, Value.nat (2 ^ bits - 1 - t % 2)),
      (Ty.int, Value.int (-((2 ^ bits - t % 2 : Nat) : Int)))]
    match encodeValues {} args with
    | .ok bytes => decodeValues {} #[.nat, .int] bytes == .ok (args.map (·.2))
    | .error _ => false)
  out := out.push (← workCheck "the capped text of a nat of 2^21 bits" 1000 fun t =>
    (Value.nat (2 ^ bits - t % 2)).toTextCapped.length ≤ 101)
  -- The text is made before the time is taken, as making it takes longer than writing its text.
  let long := "".pushn 'a' 10000000
  out := out.push (← workCheck "the capped text of a text of 10^7 characters in 500 options" 1000
      fun t =>
    let v : Value := nest (500 + t % 2) (fun v => .opt (some v)) (.text long)
    v.toTextCapped.length ≤ 101)
  out := out.push (← workCheck "the capped text of a vec of 10^6 records" 1000 fun t =>
    let r := Value.record #[(.name "a", .nat 1), (.name "b", .text "x")]
    (Value.vec (Array.replicate (1000000 + t % 2) r)).toTextCapped.length ≤ 101)
  return out

/-! ## Running the checks -/

/-- Prints a line per check, `ok` or `FAIL` with what went wrong, and returns how many passed and
how many failed. -/
def runChecks (checks : Array Check) : IO (Nat × Nat) := do
  let mut failed := 0
  for c in checks do
    match c.failure with
    | none => IO.println s!"ok   {c.name}"
    | some why =>
      failed := failed + 1
      IO.println s!"FAIL {c.name}: {why}"
  -- Writes out what was printed, should the program fail after it.
  (← IO.getStdout).flush
  return (checks.size - failed, failed)

/-- Prints a line for each check of a group that fails, and one for the group, and returns how
many passed and how many failed. -/
def runGroup (group : String) (checks : Array Check) : IO (Nat × Nat) := do
  let mut failed := 0
  for c in checks do
    if let some why := c.failure then
      failed := failed + 1
      IO.println s!"FAIL {group}: {c.name}: {why}"
  IO.println s!"{group}: {checks.size - failed} passed, {failed} failed"
  (← IO.getStdout).flush
  return (checks.size - failed, failed)

/-- Runs the checks, prints a summary, and returns the exit code: 0 if all pass, else 1. The
program takes no arguments; the `_` at the start of `_args` tells Lean that it is unused on
purpose. -/
def main (_args : List String) : IO UInt32 := do
  let mut passed := 0
  let mut failed := 0
  for checks in [lebChecks, hashChecks, principalChecks, didChecks, typedChecks, cappedChecks] do
    let (p, f) ← runChecks (checks ())
    passed := passed + p
    failed := failed + f
  let (p, f) ← runChecks (← workChecks)
  passed := passed + p
  failed := failed + f
  let groups := #[("generated messages", generatedChecks), ("numbers", numberChecks),
    ("floats", floatChecks), ("deep values", deepChecks), ("wide values", wideChecks)]
  for (name, checks) in groups do
    let (p, f) ← runGroup name (checks ())
    passed := passed + p
    failed := failed + f
  IO.println s!"round-trip tests: {passed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
