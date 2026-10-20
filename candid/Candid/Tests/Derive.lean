import Candid
import Candid.Derive

/-!
Tests of `deriving CandidType` (Candid/Derive.lean): the Candid types that it gives structures and
inductive types of every shape, `toValue` and `ofValue` on their values, the errors of `ofValue`,
and the errors that the handler reports while Lean compiles this file.

This is a program, not a `module`: it imports `Candid.Derive` plainly, and runs with
`lean --run Candid/Tests/Derive.lean` (with `LEAN_PATH` on the library's `.olean` files). It prints
a line per check and a summary, and exits with code 1 if a check fails. The errors that the
handler reports are checked by `#guard_msgs` as Lean compiles the file: if one differs, the file
does not compile, and the program does not run. The checks of modules run `lean` on module files
that the program writes to a temporary directory.
-/

open Candid

/-! ## Types that derive `CandidType`

`deriving CandidType, BEq` asks Lean for both instances; `BEq` gives `==`, which the round trips
compare with. The Candid types in the comments list fields and cases in id order, the order of
their `idlHash`es, which is how Candid sorts them (`x` is 120, `name` 1224700491). -/

/-- `record { x : nat; name : text }` -/
structure Point where
  x : Nat
  name : String
  deriving CandidType, BEq

/-- `record { active : bool; balance : int; owner : text; memo : opt text; tags : vec text }` -/
structure Account where
  owner : String
  balance : Int
  tags : Array String
  memo : Option String
  active : Bool
  deriving CandidType, BEq

structure Base where
  id : Nat
  deriving BEq

/-- A parent's fields are fields of the record too: `record { id : nat; label : text }`. -/
structure Item extends Base where
  label : String
  deriving CandidType, BEq

/-- A case per shape of arguments: none (`dot`), one (`circle`), named (`rect`), and unnamed
(`pair`, whose argument names Lean makes up):
`variant { dot; pair : record { nat; text }; rect : record { h : float64; w : float64 };
circle : float64 }`. -/
inductive Shape where
  | dot
  | circle (radius : Float)
  | rect (w h : Float)
  | pair : Nat → String → Shape
  deriving CandidType, BEq

/-- Arguments of which only some have names are a tuple: `variant { m : record { nat; text } }`. -/
inductive Mixed where
  | m (x : Nat) : String → Mixed
  deriving CandidType, BEq

/-- An enumeration: `variant { red; blue; green }`. -/
inductive Color where
  | red
  | green
  | blue
  deriving CandidType, BEq

/-- A parameter: `Page Nat` is `record { next : opt nat; items : vec nat }`. -/
structure Page (α : Type) where
  items : Array α
  next : Option Nat
  deriving CandidType, BEq

/-- Two parameters: `Outcome String Nat` is
`variant { failure : record { error : text; retryable : bool }; success : nat }`. -/
inductive Outcome (ε α : Type) where
  | success (value : α)
  | failure (error : ε) (retryable : Bool)
  deriving CandidType, BEq

/-- Derived types inside a derived type. -/
structure Drawing where
  title : String
  shapes : Array Shape
  origin : Point
  page : Page Point
  deriving CandidType, BEq

universe u

/-- A parameter in any universe: the instance is for `Box.{0}`, `CandidType` being for `Type`. -/
structure Box (α : Type u) where
  val : α
  deriving CandidType, BEq

/-- No fields: `record {}`. -/
structure Blank where
  deriving CandidType, BEq

/-- No constructors, and so no values: `variant {}`. -/
inductive Never
  deriving CandidType

/-- Names that the text format quotes: `record { "type" : nat; "my field" : bool }`. -/
structure Keywords where
  «type» : Nat
  «my field» : Bool
  deriving CandidType, BEq

/-- Default values change nothing: `record { verbose : bool; retries : nat }`. -/
structure Config where
  retries : Nat := 3
  verbose : Bool := false
  deriving CandidType, BEq

/-- A type declared without `CandidType`, which gets it later. -/
inductive Late where
  | early
  | late (n : Nat)
  deriving BEq

/-- Another one, for a `deriving instance` of two types. -/
structure Hour where
  hour : UInt8
  deriving BEq

deriving instance CandidType for Late, Hour

/-- Errors name a private type as it is written. -/
private structure Hidden where
  secret : Nat
  deriving CandidType, BEq

/-- An implicit argument is an argument like the others:
`variant { c : record { n : nat; s : text } }`. -/
inductive Implicit where
  | c {n : Nat} (s : String)
  deriving CandidType, BEq

/-- A parameter outside `Type` gets no `CandidType`, and needs none, as no field has its type:
`Tagged Type` is `record { n : nat }`. -/
structure Tagged (tag : Type 1) where
  n : Nat
  deriving CandidType

/-- A field whose name has the same id as another name, `sbusnjd` (see the errors below), which
`ofValue` takes for it. -/
structure Hashed where
  dnctwrq : Nat
  deriving CandidType, BEq

/-! ## Errors that the handler reports

`#guard_msgs in` checks that the command after it reports exactly the messages in the doc comment
before it, and makes those messages part of the check rather than errors of the file;
`(whitespace := lax)` lets the expected message break over lines. -/

/--
error: deriving CandidType for Tree: it is recursive, which deriving does not support yet: its
Candid type would need a named type definition (`Ty.var`)
-/
#guard_msgs (whitespace := lax) in
inductive Tree where
  | leaf
  | node (left right : Tree)
  deriving CandidType

/--
error: deriving CandidType for Rose: it is recursive, which deriving does not support yet: its
Candid type would need a named type definition (`Ty.var`)
-/
#guard_msgs (whitespace := lax) in
structure Rose where
  children : Array Rose
  deriving CandidType

-- `dnctwrq` and `sbusnjd` have the same `idlHash`, 2270622235.

/--
error: deriving CandidType for Clash: the fields dnctwrq and sbusnjd have the same id 2270622235
(their idlHash), which Candid cannot tell apart; rename one of them
-/
#guard_msgs (whitespace := lax) in
structure Clash where
  dnctwrq : Nat
  sbusnjd : Nat
  deriving CandidType

/--
error: deriving CandidType for ClashCase: the constructors dnctwrq and sbusnjd have the same id
2270622235 (their idlHash), which Candid cannot tell apart; rename one of them
-/
#guard_msgs (whitespace := lax) in
inductive ClashCase where
  | dnctwrq
  | sbusnjd
  deriving CandidType

/--
error: deriving CandidType for ClashArgs: the arguments dnctwrq and sbusnjd of constructor c have
the same id 2270622235 (their idlHash), which Candid cannot tell apart; rename one of them
-/
#guard_msgs (whitespace := lax) in
inductive ClashArgs where
  | c (dnctwrq sbusnjd : Nat)
  deriving CandidType

/--
error: deriving CandidType for Vec: it is an indexed family, whose constructors make values of
different types, which is not supported
-/
#guard_msgs (whitespace := lax) in
inductive Vec : Nat → Type where
  | nil : Vec 0
  deriving CandidType

/--
error: deriving CandidType for Letter: field c has type Char, which has no CandidType instance
-/
#guard_msgs (whitespace := lax) in
structure Letter where
  c : Char
  deriving CandidType

/--
error: deriving CandidType for Positive: field pos is a proof, which has no Candid value
-/
#guard_msgs (whitespace := lax) in
structure Positive where
  n : Nat
  pos : n > 0
  deriving CandidType

/--
error: deriving CandidType for Claim: field statement is a type, which has no Candid value
-/
#guard_msgs (whitespace := lax) in
structure Claim where
  statement : Prop
  deriving CandidType

/--
error: deriving CandidType for Sized: field index has type Fin x.size, which depends on the value
of another field, as no Candid type can
-/
#guard_msgs (whitespace := lax) in
structure Sized where
  size : Nat
  index : Fin size
  deriving CandidType

/--
error: deriving CandidType for Indexed: argument index of constructor at has type Fin size, which
depends on the value of another argument, as no Candid type can
-/
#guard_msgs (whitespace := lax) in
inductive Indexed where
  | at (size : Nat) (index : Fin size)
  deriving CandidType

mutual
inductive Ping where
  | ping (next : Pong)
  | stop
inductive Pong where
  | pong (next : Ping)
end

/--
error: deriving CandidType for Ping: it is one of the mutually inductive types Ping and Pong,
which are not supported
-/
#guard_msgs (whitespace := lax) in
deriving instance CandidType for Ping

/--
error: deriving CandidType for Greeter: it is a class; Candid types are for data
-/
#guard_msgs (whitespace := lax) in
class Greeter where
  greeting : String
  deriving CandidType

/--
error: deriving CandidType for Fact: it is in `Prop`, but CandidType is for types in `Type`
-/
#guard_msgs (whitespace := lax) in
structure Fact : Prop where
  holds : True
  deriving CandidType

/--
error: deriving CandidType for Packed: it is in `Type 1`, but CandidType is for types in `Type`
-/
#guard_msgs (whitespace := lax) in
structure Packed where
  carrier : Type
  deriving CandidType

/--
error: deriving CandidType for Raw: it is `unsafe`
-/
#guard_msgs (whitespace := lax) in
unsafe inductive Raw where
  | raw
  deriving CandidType

/-! ## Checks

A check is a value: the functions below compute them, and `main` prints them. `ofValue` returns
an `Except Candid.Error α`, which is either `.ok a` or `.error e`; `match` tells them apart. -/

/-- `==` on results, which Init does not define: equal results, or equal errors. -/
instance [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok a, .ok b => a == b
    | .error a, .error b => a == b
    | _, _ => false

/-- A check: its name, and `none` if it passes, or `some` what went wrong. -/
structure Check where
  name : String
  failure : Option String

/-- A check that `ok` holds, with `detail` saying what went wrong if it does not. -/
def check (name : String) (ok : Bool) (detail : String) : Check :=
  { name, failure := if ok then none else some detail }

/-- `s` on one line: `Ty.toDid` breaks a long type over lines, with an item per line; this turns
each line break and the indentation after it into a space. -/
def oneLine (s : String) : String :=
  " ".intercalate ((s.splitOn "\n").map (·.trimAsciiStart.copy))

/-- That the Candid type of `α`, as text, is `expected`. `(α : Type)` is an explicit argument, as
`CandidType.ty α` is: Lean cannot infer `α` from the result. -/
def checkTy (name : String) (α : Type) [CandidType α] (expected : String) : Check :=
  let got := oneLine (CandidType.ty α).toDid
  check s!"ty {name} = {expected}" (got == expected) s!"got {got}"

/-- That `toValue x` is `expected`, and `ofValue` of it is `x` again. `[CandidType α]` asks Lean
for the instance of whatever type `x` has; `(e : T)` says which type `e` has, here which instance
`ofValue` is from. -/
def checkValue [CandidType α] [BEq α] (name : String) (x : α) (expected : Value) : Check :=
  let v := CandidType.toValue x
  if v != expected then
    check s!"value {name}" false s!"toValue gave {v}, expected {expected}"
  else match (CandidType.ofValue v : Except Candid.Error α) with
    | .ok y => check s!"value {name}" (y == x) "ofValue gave another value back"
    | .error e => check s!"value {name}" false s!"ofValue failed: {e}"

/-- That `ofValue v` is `expected`. -/
def checkOfValue [CandidType α] [BEq α] (name : String) (v : Value) (expected : α) : Check :=
  match (CandidType.ofValue v : Except Candid.Error α) with
  | .ok y => check s!"ofValue {name}" (y == expected) "ofValue gave another value"
  | .error e => check s!"ofValue {name}" false s!"ofValue failed: {e}"

/-- That `ofValue v` at `α` fails with `message`. -/
def checkError (name : String) (α : Type) [CandidType α] (v : Value) (message : String) : Check :=
  match (CandidType.ofValue v : Except Candid.Error α) with
  | .ok _ => check s!"error {name}" false "ofValue succeeded"
  | .error e => check s!"error {name}: {message}" (e.message == message) s!"got {e.message}"

/-- That `decode (encode args)` is `args`: a round trip through the binary format. `args` is a
method's arguments: a value, or a product of them. -/
def checkWireTrip [CandidArgs α] [BEq α] (name : String) (args : α) : Check :=
  let result : Except Candid.Error α := do Candid.decode (← Candid.encode args)
  match result with
  | .ok y => check s!"wire {name}" (y == args) "decode gave another value back"
  | .error e => check s!"wire {name}" false s!"{e}"

/-- That `encode x` is the message `expected`. -/
def checkWireBytes [CandidType α] (name : String) (x : α) (expected : List UInt8) : Check :=
  let hex (bytes : List UInt8) := " ".intercalate (bytes.map (hexDigits ·.toNat))
  match Candid.encode x with
  | .ok bytes => check s!"wire bytes {name}" (bytes.toList == expected) s!"got {hex bytes.toList}"
  | .error e => check s!"wire bytes {name}" false s!"{e}"

/-! ## The expected Candid types -/

def shapeTy : String :=
  "variant { dot; pair : record { nat; text }; rect : record { h : float64; w : float64 }; " ++
  "circle : float64 }"

def pointTy : String := "record { x : nat; name : text }"

def tyChecks : Array Check := #[
  checkTy "Point" Point pointTy,
  checkTy "Account" Account
    "record { active : bool; balance : int; owner : text; memo : opt text; tags : vec text }",
  checkTy "Item" Item "record { id : nat; label : text }",
  checkTy "Shape" Shape shapeTy,
  checkTy "Mixed" Mixed "variant { m : record { nat; text } }",
  checkTy "Color" Color "variant { red; blue; green }",
  checkTy "Page Nat" (Page Nat) "record { next : opt nat; items : vec nat }",
  checkTy "Page Point" (Page Point) s!"record \{ next : opt nat; items : vec {pointTy} }",
  checkTy "Outcome String Nat" (Outcome String Nat)
    "variant { failure : record { error : text; retryable : bool }; success : nat }",
  checkTy "Drawing" Drawing
    (s!"record \{ title : text; shapes : vec {shapeTy}; " ++
     s!"page : record \{ next : opt nat; items : vec {pointTy} }; origin : {pointTy} }"),
  checkTy "Box Nat" (Box Nat) "record { val : nat }",
  checkTy "Blank" Blank "record {}",
  checkTy "Never" Never "variant {}",
  checkTy "Keywords" Keywords "record { \"type\" : nat; \"my field\" : bool }",
  checkTy "Config" Config "record { verbose : bool; retries : nat }",
  checkTy "Late" Late "variant { late : nat; early }",
  checkTy "Hour" Hour "record { hour : nat8 }",
  checkTy "Hidden" Hidden "record { secret : nat }",
  checkTy "Implicit" Implicit "variant { c : record { n : nat; s : text } }",
  checkTy "Tagged Type" (Tagged Type) "record { n : nat }",
  -- Derived types inside the library's instances.
  checkTy "Option Point" (Option Point) s!"opt {pointTy}",
  checkTy "Array Color" (Array Color) "vec variant { red; blue; green }",
  checkTy "Except String Point" (Except String Point) s!"variant \{ Ok : {pointTy}; Err : text }"
]

/-! ## Values -/

def point : Point := { x := 3, name := "p" }

def pointValue : Value := .record #[(.name "x", .nat 3), (.name "name", .text "p")]

def drawing : Drawing :=
  { title := "d", shapes := #[.dot, .circle 1], origin := { x := 0, name := "o" },
    page := { items := #[point], next := none } }

def valueChecks : Array Check := #[
  checkValue "Point" point pointValue,
  checkValue "Account"
    ({ owner := "ann", balance := -5, tags := #["a", "b"], memo := none, active := true } : Account)
    (.record #[(.name "active", .bool true), (.name "balance", .int (-5)),
      (.name "owner", .text "ann"), (.name "memo", .opt none),
      (.name "tags", .vec #[.text "a", .text "b"])]),
  checkValue "Item" ({ id := 7, label := "seven" } : Item)
    (.record #[(.name "id", .nat 7), (.name "label", .text "seven")]),
  checkValue "Shape.dot" Shape.dot (.variant (.name "dot") .null),
  checkValue "Shape.circle" (Shape.circle 1.5) (.variant (.name "circle") (.float64 1.5)),
  checkValue "Shape.rect" (Shape.rect 2 3)
    (.variant (.name "rect") (.record #[(.name "h", .float64 3), (.name "w", .float64 2)])),
  checkValue "Shape.pair" (Shape.pair 7 "x")
    (.variant (.name "pair") (.record #[(.num 0, .nat 7), (.num 1, .text "x")])),
  checkValue "Mixed.m" (Mixed.m 1 "s")
    (.variant (.name "m") (.record #[(.num 0, .nat 1), (.num 1, .text "s")])),
  checkValue "Color.green" Color.green (.variant (.name "green") .null),
  checkValue "Page Nat" ({ items := #[1, 2], next := some 3 } : Page Nat)
    (.record #[(.name "next", .opt (some (.nat 3))), (.name "items", .vec #[.nat 1, .nat 2])]),
  checkValue "Outcome.success" (Outcome.success 5 : Outcome String Nat)
    (.variant (.name "success") (.nat 5)),
  checkValue "Outcome.failure" (Outcome.failure "boom" true : Outcome String Nat)
    (.variant (.name "failure")
      (.record #[(.name "error", .text "boom"), (.name "retryable", .bool true)])),
  checkValue "Drawing" drawing
    (.record #[(.name "title", .text "d"),
      (.name "shapes",
        .vec #[.variant (.name "dot") .null, .variant (.name "circle") (.float64 1)]),
      (.name "page", .record #[(.name "next", .opt none), (.name "items", .vec #[pointValue])]),
      (.name "origin", .record #[(.name "x", .nat 0), (.name "name", .text "o")])]),
  checkValue "Box Nat" ({ val := 5 } : Box Nat) (.record #[(.name "val", .nat 5)]),
  checkValue "Blank" ({} : Blank) (.record #[]),
  checkValue "Keywords" ({ «type» := 1, «my field» := false } : Keywords)
    (.record #[(.name "type", .nat 1), (.name "my field", .bool false)]),
  checkValue "Config" ({} : Config)
    (.record #[(.name "verbose", .bool false), (.name "retries", .nat 3)]),
  checkValue "Late.late" (Late.late 4) (.variant (.name "late") (.nat 4)),
  checkValue "Late.early" Late.early (.variant (.name "early") .null),
  checkValue "Hour" ({ hour := 23 } : Hour) (.record #[(.name "hour", .nat8 23)]),
  checkValue "Option Point" (some point) (.opt (some pointValue)),
  checkValue "Except String Point" (Except.ok point : Except String Point)
    (.variant (.name "Ok") pointValue),
  checkValue "Implicit.c" (@Implicit.c 5 "s")
    (.variant (.name "c") (.record #[(.name "n", .nat 5), (.name "s", .text "s")])),
  -- `ofValue` finds fields by id: in any order, with numbers for labels, and with more fields.
  checkOfValue "fields in another order"
    (.record #[(.name "name", .text "p"), (.name "x", .nat 3)]) point,
  checkOfValue "labels by number"
    (.record #[(.num 120, .nat 3), (.num 1224700491, .text "p")]) point,
  checkOfValue "an extra field" (.record #[(.name "x", .nat 3), (.name "name", .text "p"),
    (.name "z", .null)]) point,
  checkOfValue "a case by number" (.variant (.num 4997769) .null) Shape.dot,
  checkOfValue "another name with the field's id" (.record #[(.name "sbusnjd", .nat 1)])
    ({ dnctwrq := 1 } : Hashed)
]

/-! ## Errors of `ofValue` -/

def errorChecks : Array Check := #[
  checkError "field" Point (.record #[(.name "x", .text "a"), (.name "name", .text "n")])
    "Point.x: expected a value of type nat, got \"a\"",
  checkError "missing field" Point (.record #[(.name "x", .nat 1)]) "Point: missing field name",
  checkError "not a record" Point (.nat 5) s!"expected a value of type {pointTy}, got 5",
  checkError "unknown case" Shape (.variant (.name "nope") .null) "Shape: unknown case nope",
  checkError "case type" Shape (.variant (.name "rect") (.nat 1))
    "Shape.rect: expected a value of type record { h : float64; w : float64 }, got 1",
  checkError "case field" Shape (.variant (.name "rect") (.record #[(.name "w", .float64 1)]))
    "Shape.rect: missing field h",
  checkError "tuple element" Shape
    (.variant (.name "pair") (.record #[(.num 0, .nat 1), (.num 1, .nat 2)]))
    "Shape.pair.1: expected a value of type text, got 2",
  -- A tuple's field 0 has the id 0; a field named "0" has the id 48, `idlHash "0"`.
  checkError "tuple field by name" Shape
    (.variant (.name "pair") (.record #[(.name "0", .nat 1), (.name "1", .text "x")]))
    "Shape.pair: missing field 0",
  checkError "null case" Shape (.variant (.name "dot") (.nat 1))
    "Shape.dot: expected a value of type null, got 1",
  checkError "not a variant" Color (.text "red")
    "expected a value of type variant { red; blue; green }, got \"red\"",
  checkError "nested" Drawing
    (.record #[(.name "title", .text "d"), (.name "shapes", .vec #[]),
      (.name "page", .record #[(.name "next", .opt none), (.name "items", .vec #[])]),
      (.name "origin", .record #[(.name "x", .bool true), (.name "name", .text "o")])])
    "Drawing.origin: Point.x: expected a value of type nat, got true",
  checkError "parameter" (Page Nat)
    (.record #[(.name "next", .opt none), (.name "items", .vec #[.text "a"])])
    "Page.items: expected a value of type nat, got \"a\"",
  checkError "named case field" (Outcome String Nat)
    (.variant (.name "failure") (.record #[(.name "error", .text "e")]))
    "Outcome.failure: missing field retryable",
  checkError "no cases" Never (.variant (.name "x") .null) "Never: unknown case x",
  checkError "private type" Hidden (.record #[]) "Hidden: missing field secret"
]

/-! ## Method arguments and results

`CandidArgs` makes a sequence of a product: `Point × Shape × Option Nat` is three arguments. -/

def argsChecks : Array Check :=
  let tys := (CandidArgs.tys (Point × Shape × Option Nat)).map (oneLine ·.toDid)
  let values := CandidArgs.toValues (point, Shape.dot, (none : Option Nat))
  let method := Candid.method "draw" (Point × Color) Drawing (mode := some .query)
  #[check "args tys of Point × Shape × Option Nat" (tys == #[pointTy, shapeTy, "opt nat"])
      s!"got {tys}",
    check "args toValues of (point, dot, none)"
      (values == #[pointValue, .variant (.name "dot") .null, .opt none]) s!"got {values}",
    match (CandidArgs.ofValues values : Except Candid.Error (Point × Shape × Option Nat)) with
    | .ok (p, s, n) => check "args ofValues" (p == point && s == .dot && n == none) "another value"
    | .error e => check "args ofValues" false s!"{e}",
    check "method draw (Point × Color) Drawing"
      (method.name == "draw" &&
        match method.ty with
        | .func args rets modes =>
          args.map (oneLine ·.toDid) == #[pointTy, "variant { red; blue; green }"] &&
            rets == #[CandidType.ty Drawing] && modes == #[.query]
        | _ => false)
      "another method type"]

/-! ## Round trips through the binary format -/

/-- The messages of `point` and `Color.green`, from the spec: `DIDL`, a type table of one entry,
the argument types, and the values. For `point`: the entry `6c 02` (a record of two fields), field
120 (`78`), `nat` (`7d`), field 1224700491 (`cb e4 fd c7 04`), `text` (`71`); one argument, of type
entry 0 (`01 00`); then `x`, 3, and `name`, of length 1, `p`. For `Color.green`: `6b 03` (a
variant of three cases), each `null` (`7f`), and the value is case 2, the third in id order. -/
def wireGoldens : Array Check := #[
  checkWireBytes "point" point
    [0x44, 0x49, 0x44, 0x4c, 0x01, 0x6c, 0x02, 0x78, 0x7d, 0xcb, 0xe4, 0xfd, 0xc7, 0x04, 0x71,
      0x01, 0x00, 0x03, 0x01, 0x70],
  checkWireBytes "Color.green" Color.green
    [0x44, 0x49, 0x44, 0x4c, 0x01, 0x6b, 0x03, 0xd1, 0xb2, 0xdb, 0x02, 0x7f, 0x9a, 0x85, 0xe5,
      0x88, 0x04, 0x7f, 0xc3, 0x9d, 0xb4, 0xcf, 0x09, 0x7f, 0x01, 0x00, 0x02]]

def wireChecks : Array Check := #[
  checkWireTrip "Point" point,
  checkWireTrip "Account"
    ({ owner := "ann", balance := -5, tags := #["a", "b"], memo := some "m", active := true } :
      Account),
  checkWireTrip "Item" ({ id := 7, label := "seven" } : Item),
  checkWireTrip "Shape.dot" Shape.dot, checkWireTrip "Shape.circle" (Shape.circle 1.5),
  checkWireTrip "Shape.rect" (Shape.rect 2 3), checkWireTrip "Shape.pair" (Shape.pair 7 "x"),
  checkWireTrip "Mixed.m" (Mixed.m 1 "s"), checkWireTrip "Color.green" Color.green,
  checkWireTrip "Page Nat" ({ items := #[1, 2], next := some 3 } : Page Nat),
  checkWireTrip "Outcome.success" (Outcome.success 5 : Outcome String Nat),
  checkWireTrip "Outcome.failure" (Outcome.failure "boom" true : Outcome String Nat),
  checkWireTrip "Drawing" drawing, checkWireTrip "Box Nat" ({ val := 5 } : Box Nat),
  checkWireTrip "Blank" ({} : Blank),
  checkWireTrip "Keywords" ({ «type» := 1, «my field» := false } : Keywords),
  checkWireTrip "Config" ({} : Config), checkWireTrip "Late.late" (Late.late 4),
  checkWireTrip "Implicit.c" (@Implicit.c 5 "s"),
  checkWireTrip "Option Point" (some point),
  checkWireTrip "(Point, Shape, Option Nat)" (point, Shape.rect 1 2, (some 3 : Option Nat))
] ++ wireGoldens

/-- The checks that `#guard_msgs` made while Lean compiled this file: if the program runs, they
passed. And the premise of the three on duplicate ids. -/
def compileChecks : Array Check :=
  #[check "idlHash \"dnctwrq\" = idlHash \"sbusnjd\" = 2270622235"
      (idlHash "dnctwrq" == 2270622235 && idlHash "sbusnjd" == 2270622235) "they differ"] ++
  #["recursive type", "recursive structure (nested)", "duplicate field ids",
    "duplicate constructor ids", "duplicate argument ids", "indexed family",
    "field without an instance", "proof field", "type field", "dependent field",
    "dependent argument", "mutual types", "class", "proposition", "type in Type 1",
    "unsafe type"].map fun name =>
    { name := s!"compile error: {name} (#guard_msgs)", failure := none }

/-! ## In modules

`deriving CandidType` is meant for module files, which `meta import Candid.Derive`, and in which
declarations are public or private. This program is not a module, so it writes modules to a
temporary directory and runs `lean`, the program that runs this one, on them: `A` derives
instances, `B` imports `A` and uses them, a program runs `B`'s code, and `C`, which has the library
at compile time only, gets the handler's error. `r#"…"#` is a string in which `"` and `\` stand for
themselves. -/

/-- A module with instances of a public structure with a private field, of an inductive type with
an exposed instance, and of a type that is private to the module. -/
def moduleA : String := r#"module

public import Candid
meta import Candid.Derive

public section

structure Secret where
  name : String
  private pin : Nat
  deriving CandidType

inductive Mode where
  | quiet
  | loud (level : Nat)
  deriving @[expose] CandidType

def secret : Secret := { name := "s", pin := 7 }

end

structure Hidden where
  n : Nat
  deriving CandidType

public def hiddenTy : String := (CandidType.ty Hidden).toDid
"#

/-- A module that uses `A`'s instances, and unfolds the exposed one in a proof by computation
(`rfl`). -/
def moduleB : String := r#"module

public import A

public def tys : Array String := #[(CandidType.ty Secret).toDid, (CandidType.ty Mode).toDid]

public def message : Except Candid.Error ByteArray := Candid.encode secret

example : CandidType.ty Mode = .variant #[⟨.name "loud", .nat⟩, ⟨.name "quiet", .null⟩] := rfl
"#

/-- A program that runs `B`'s code, and `A`'s, which `B` imports: the types, and `secret` back
from its message. -/
def programMain : String := r#"import B

def main : IO Unit := do
  for t in tys do
    IO.println t
  IO.println hiddenTy
  match (do Candid.decode (← message) : Except Candid.Error Secret) with
  | .ok s => IO.println (CandidType.toValue s)
  | .error e => IO.println e
"#

/-- What the program prints. -/
def expectedMain : String :=
  "record { pin : nat; name : text }\nvariant { loud : nat; quiet }\nrecord { n : nat }\n" ++
  "record { pin = 7; name = \"s\" }\n"

/-- A module that has the library at compile time only, through `meta import`. -/
def moduleC : String := r#"module

meta import Candid
meta import Candid.Derive

structure S where
  n : Nat
  deriving CandidType
"#

/-- Runs `lean` in `dir` with `args`, and with `dir` on `LEAN_PATH`, so that a module there can
import another one there. `IO.appPath` is the path of the running program, `lean`. -/
def runLean (dir : System.FilePath) (args : Array String) : IO IO.Process.Output := do
  let leanPath := match ← IO.getEnv "LEAN_PATH" with
    | some path => s!"{dir}{System.SearchPath.separator}{path}"
    | none => dir.toString
  IO.Process.output
    { cmd := (← IO.appPath).toString, args, cwd := dir, env := #[("LEAN_PATH", some leanPath)] }

/-- Compiles the modules, with `lean -o`, which writes the `.olean` file that importers read, and
runs the program. `withTempDir` deletes the directory afterwards. -/
def moduleChecks : IO (Array Check) :=
  IO.FS.withTempDir fun dir => do
    IO.FS.writeFile (dir / "A.lean") moduleA
    IO.FS.writeFile (dir / "B.lean") moduleB
    IO.FS.writeFile (dir / "Main.lean") programMain
    IO.FS.writeFile (dir / "C.lean") moduleC
    let compile (name : String) := runLean dir #["-o", s!"{name}.olean", s!"{name}.lean"]
    let a ← compile "A"
    let b ← compile "B"
    let run ← runLean dir #["--run", "Main.lean"]
    let c ← compile "C"
    let output (o : IO.Process.Output) := o.stdout ++ o.stderr
    return #[
      check "module A derives instances (a private field, @[expose], a private type)"
        (a.exitCode == 0) (output a),
      check "module B uses A's instances, and unfolds the exposed one" (b.exitCode == 0)
        (output b),
      check "a program runs B's code" (run.exitCode == 0 && run.stdout == expectedMain)
        (output run),
      check "module C, without the library at run time, gets the handler's error"
        (c.exitCode != 0 &&
          (output c).contains "the instance needs the library when the program runs")
        (output c)]

/-- Runs the checks. `main` returns the exit code: 0 if all pass, else 1. In its `do` block,
`let mut` declares a variable that the `for` loop can change. -/
def main : IO UInt32 := do
  let checks := tyChecks ++ valueChecks ++ errorChecks ++ argsChecks ++ wireChecks ++
    compileChecks ++ (← moduleChecks)
  let mut failed := 0
  for c in checks do
    match c.failure with
    | none => IO.println s!"ok   {c.name}"
    | some why =>
      IO.println s!"FAIL {c.name}: {why}"
      failed := failed + 1
  IO.println s!"derive tests: {checks.size - failed} passed, {failed} failed"
  return if failed == 0 then 0 else 1
