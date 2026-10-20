module

public import Candid.Error
public import Candid.Hash

/-!
Candid types as Lean values, and their `.did` text.

`Ty` is an inductive type: its values are made with the constructors below, as those of a Rust
`enum` are, and functions on it match on them. `Ty`, `Field` and `Method` are *mutual*: they are
defined together, because a record's `Field`s hold `Ty`s, which may be records again. Lean
derives `==` (`BEq`), `repr` (`Repr`), `hash` (`Hashable`) and a default value (`Inhabited`) for
them.

A type is *structural*: `record { a : nat }` is the same type wherever it appears. A `var` names
a definition in a `TypeEnv` (`type List = opt record { head : nat; tail : List }` in a `.did`
file), which is how a type refers to itself. A `table` refers to an entry of a message's type
table, which only the decoder makes; a message's types refer to each other that way.
-/

public section

namespace Candid

/-- The label of a record field or a variant case: a number, its id, or a name, whose id is its
`idlHash`. The binary format carries ids only, so `==` compares the ids, and
`.name "a" == .num 97`. -/
inductive Label where
  | num (id : UInt32)
  | name (s : String)
  deriving Inhabited

namespace Label

/-- The id that the binary format carries. -/
def id : Label → UInt32
  | num id => id
  | name s => idlHash s

instance : BEq Label := ⟨fun a b => a.id == b.id⟩

-- `hash` must agree with `==`: labels that are equal must have the same hash.
instance : Hashable Label := ⟨fun l => hash l.id⟩

instance : Repr Label where
  reprPrec l _ := match l with
    | num id => s!"Label.num {id}"
    | name s => s!"Label.name {repr s}"

end Label

/-- The annotation of a function type: `query`, `oneway` or `composite_query`. -/
inductive FuncMode where
  | query
  | oneway
  | compositeQuery
  deriving BEq, Repr, Hashable, Inhabited

namespace FuncMode

/-- The byte that stands for the mode in the binary format. -/
def code : FuncMode → UInt8
  | query => 1
  | oneway => 2
  | compositeQuery => 3

/-- The mode for a byte of the binary format, the inverse of `code`. -/
def ofCode? : UInt8 → Option FuncMode
  | 1 => some query
  | 2 => some oneway
  | 3 => some compositeQuery
  | _ => none

/-- The keyword of the mode in the text format. -/
def keyword : FuncMode → String
  | query => "query"
  | oneway => "oneway"
  | compositeQuery => "composite_query"

end FuncMode

mutual

/-- A Candid type. The constructors up to `principal` are the primitive types, those from `opt`
to `service` the composite ones (spec: "Types"). -/
inductive Ty where
  | null
  | bool
  | nat
  | int
  | nat8
  | nat16
  | nat32
  | nat64
  | int8
  | int16
  | int32
  | int64
  | float32
  | float64
  | text
  | reserved
  | empty
  | principal
  | opt (t : Ty)
  | vec (t : Ty)
  /-- A record's fields, sorted by id, which are unique. `Ty.recordOf` sorts them. -/
  | record (fields : Array Field)
  /-- A variant's cases, sorted by id, which are unique. `Ty.variantOf` sorts them. -/
  | variant (cases : Array Field)
  /-- A function type, `func (args) -> (rets) mode`, with at most one mode. -/
  | func (args rets : Array Ty) (modes : Array FuncMode)
  /-- A service type, whose methods have function types (or `var`s naming them), sorted by name
  in the byte order of their UTF-8, which is the order of `<` on `String`. -/
  | service (methods : Array Method)
  /-- The type that `name` stands for in a `TypeEnv`. -/
  | var (name : String)
  /-- Entry `index` of a message's type table; only the decoder makes these. -/
  | table (index : Nat)
  /-- A type that a later version of Candid may add, which a message can contain: its opcode, a
  number below -24. Its values can only be skipped. -/
  | future (opcode : Int)

/-- A record field or a variant case. -/
structure Field where
  label : Label
  ty : Ty

/-- A service's method. -/
structure Method where
  name : String
  ty : Ty

end

deriving instance BEq, Repr, Hashable, Inhabited for Ty, Field, Method

namespace Field

/-- Sorts fields by id, the order that `Ty.record` and `Ty.variant` need. -/
def sortById (fields : Array Field) : Array Field :=
  fields.qsort (·.label.id < ·.label.id)

/-- Two fields with the same id, if there are such in `sorted`, which is sorted by id. -/
def duplicate? (sorted : Array Field) : Option (Field × Field) := Id.run do
  for i in [1:sorted.size] do
    if sorted[i - 1]!.label.id == sorted[i]!.label.id then
      return some (sorted[i - 1]!, sorted[i]!)
  return none

end Field

namespace Ty

/-- `blob`, which is short for `vec nat8`. -/
def blob : Ty := vec nat8

/-- A record type with these fields, sorted by id. -/
def recordOf (fields : Array Field) : Ty := record (Field.sortById fields)

/-- A variant type with these cases, sorted by id. -/
def variantOf (cases : Array Field) : Ty := variant (Field.sortById cases)

/-- A tuple type, `record { t₀; t₁; … }`: a record with the fields 0, 1, …. -/
def tuple (tys : Array Ty) : Ty :=
  record (tys.mapIdx fun i t => { label := .num i.toUInt32, ty := t })

/-- A service type with these methods, sorted by name. -/
def serviceOf (methods : Array Method) : Ty := service (methods.qsort (·.name < ·.name))

/-- The primitive types whose opcodes are -1, -2, …, -17, in that order. -/
private def primitivesByOpcode : Array Ty :=
  #[null, bool, nat, int, nat8, nat16, nat32, nat64, int8, int16, int32, int64, float32, float64,
    text, reserved, empty]

/-- The opcode of a primitive type, a negative number, which stands for the type in the binary
format (spec: `T`), or `none` for the other types. -/
def primOpcode? : Ty → Option Int
  | null => some (-1)
  | bool => some (-2)
  | nat => some (-3)
  | int => some (-4)
  | nat8 => some (-5)
  | nat16 => some (-6)
  | nat32 => some (-7)
  | nat64 => some (-8)
  | int8 => some (-9)
  | int16 => some (-10)
  | int32 => some (-11)
  | int64 => some (-12)
  | float32 => some (-13)
  | float64 => some (-14)
  | text => some (-15)
  | reserved => some (-16)
  | empty => some (-17)
  | principal => some (-24)
  | _ => none

/-- The primitive type of an opcode, the inverse of `primOpcode?`. -/
def ofPrimOpcode? (opcode : Int) : Option Ty :=
  if opcode == -24 then some principal
  else if -17 ≤ opcode && opcode ≤ -1 then primitivesByOpcode[(-opcode - 1).toNat]?
  else none

/-- Whether the type is primitive, that is, has an opcode of its own. -/
def isPrimitive (t : Ty) : Bool := t.primOpcode?.isSome

/-- The opcodes of the composite types, which start their entries in a message's type table. -/
def optOpcode : Int := -18
def vecOpcode : Int := -19
def recordOpcode : Int := -20
def variantOpcode : Int := -21
def funcOpcode : Int := -22
def serviceOpcode : Int := -23

end Ty

/-- Named type definitions, the `type X = …;` of a `.did` file, which `Ty.var` refers to. A list
of pairs rather than a map: an interface has few, and Lean's `Init`, which is all that a canister
links, has no hash map. -/
structure TypeEnv where
  defs : Array (String × Ty) := #[]
  deriving Inhabited, Repr

namespace TypeEnv

/-- The type that `name` stands for. -/
def find? (env : TypeEnv) (name : String) : Option Ty :=
  (env.defs.find? (·.1 == name)).map (·.2)

/-- Follows `var` and `table` references until a type that is not one, with `table` the type
table of a message. Fails on a name or index that refers to nothing, and on a cycle of
references such as `type A = B; type B = A`, which stands for no type: there cannot be more
steps than definitions and entries. -/
def resolve (env : TypeEnv) (table : Array Ty) (t : Ty) : Except Error Ty :=
  go (env.defs.size + table.size + 1) t
where
  go : Nat → Ty → Except Error Ty
    | 0, _ => fail "cyclic type definition"
    | n + 1, .var name => match env.find? name with
      | some t => go n t
      | none => fail s!"unbound type identifier {name}"
    | n + 1, .table i => match table[i]? with
      | some t => go n t
      | none => fail s!"type index {i} out of range"
    | _, t => pure t

end TypeEnv

/-- A `.did` file: its type definitions, and its service, if it has one. A service that a
canister's init arguments parameterize, `service : (nat) -> { … }`, is a service constructor
(a "class"), whose arguments are `initArgs`. -/
structure Interface where
  env : TypeEnv := {}
  initArgs : Option (Array Ty) := none
  /-- `service ms` or a `var` naming one. -/
  service : Option Ty := none
  deriving Inhabited, Repr

/-! ## The text format -/

/-- The words that the printers quote where they are names: the keywords of the Rust printer,
and `true` and `false`, which the Rust lexer reads as booleans wherever they are, so that the
Rust parser does not read `record { true : bool }` (this library's parser does). -/
def keywords : Array String :=
  #["import", "service", "func", "type", "opt", "vec", "record", "variant", "blob", "principal",
    "nat", "nat8", "nat16", "nat32", "nat64", "int", "int8", "int16", "int32", "int64", "float32",
    "float64", "bool", "text", "null", "reserved", "empty", "oneway", "query", "composite_query",
    "true", "false"]

/-- Whether `s` can be written unquoted: an ASCII letter or `_`, then letters, digits and `_`
(`Char.isAlpha` and `Char.isAlphanum` are about ASCII only), and not one of the `keywords`. -/
def isPlainName (s : String) : Bool :=
  !s.isEmpty && !s.front.isDigit && s.all (fun c => c.isAlphanum || c == '_') &&
    !keywords.contains s

/-- Hexadecimal digits of `n`, at least `width` of them. -/
def hexDigits (n : Nat) (width : Nat := 2) : String :=
  let digits := Nat.toDigits 16 n
  String.ofList (List.replicate (width - digits.length) '0' ++ digits)

/-- The characters of `s` as a string literal writes them: `"`, `\` and control characters
escaped, the others as they are. -/
def escapeText (s : String) : String :=
  s.foldl (init := "") fun out c =>
    match c with
    | '"' => out ++ "\\\""
    | '\\' => out ++ "\\\\"
    | '\n' => out ++ "\\n"
    | '\r' => out ++ "\\r"
    | '\t' => out ++ "\\t"
    | c => if c.toNat < 0x20 || c.toNat == 0x7f then out ++ s!"\\u\{{hexDigits c.toNat 1}}"
      else out.push c

/-- `s` as a string literal of the text format: in double quotes, with `"`, `\` and control
characters escaped. -/
def quote (s : String) : String :=
  "\"" ++ escapeText s ++ "\""

/-- A name as the text format writes it: quoted if it is not a plain name. -/
def nameText (s : String) : String := if isPlainName s then s else quote s

/-- A label as the text format writes it: its number, or its name. -/
def Label.text : Label → String
  | .num id => toString id
  | .name s => nameText s

open Std (Format)

/-- `{ item; item }` on one line if it fits, else with an item per line, indented. -/
private def braces (items : Array Format) : Format :=
  if items.isEmpty then "{}"
  else .group (.nest 2 ("{" ++ .line ++ .joinSep items.toList (";" ++ .line)) ++ .line ++ "}")

/-- `(t, t)`, which breaks after each `,` if the line is too long. -/
private def parens (items : Array Format) : Format :=
  if items.isEmpty then "()"
  else .group (.nest 2 ("(" ++ .joinSep items.toList ("," ++ .line)) ++ ")")

/-- Whether a record's fields are those of a tuple, 0, 1, …, written without labels. -/
def isTuple (fields : Array Field) : Bool := Id.run do
  for h : i in [0:fields.size] do
    if fields[i].label.id != i.toUInt32 then return false
  return true

mutual

/-- The text of a type, laid out as by the Rust printer where it fits on a line of 80 columns:
`record { a : nat; b : text }`. A longer one is broken over lines, with an item per line, as the
Rust printer breaks it, except that the last item of a broken record, variant or service has no
`;` after it, and that a broken function type's arguments start after its `(`: the text reads
back as the same type either way. -/
partial def Ty.format : Ty → Format
  | .null => "null"
  | .bool => "bool"
  | .nat => "nat"
  | .int => "int"
  | .nat8 => "nat8"
  | .nat16 => "nat16"
  | .nat32 => "nat32"
  | .nat64 => "nat64"
  | .int8 => "int8"
  | .int16 => "int16"
  | .int32 => "int32"
  | .int64 => "int64"
  | .float32 => "float32"
  | .float64 => "float64"
  | .text => "text"
  | .reserved => "reserved"
  | .empty => "empty"
  | .principal => "principal"
  | .opt t => "opt " ++ t.format
  | .vec .nat8 => "blob"
  | .vec t => "vec " ++ t.format
  | .record fields =>
    if isTuple fields then "record " ++ braces (fields.map (·.ty.format))
    else "record " ++ braces (fields.map fun f => f.label.text ++ " : " ++ f.ty.format)
  | .variant cases =>
    -- A case of type `null` is written without its type: `variant { none; some : nat }`.
    "variant " ++ braces (cases.map fun c =>
      if c.ty == .null then c.label.text else c.label.text ++ " : " ++ c.ty.format)
  | .func args rets modes => "func " ++ funcFormat args rets modes
  | .service methods => "service " ++ serviceFormat methods
  | .var name => name
  | .table index => s!"table{index}"
  | .future _ => "future"

/-- `(args) -> (rets) mode`, a function type without `func`, as a method's type is written. -/
partial def funcFormat (args rets : Array Ty) (modes : Array FuncMode) : Format :=
  let modes := modes.foldl (fun acc m => acc ++ " " ++ m.keyword) ""
  .nest 2 (parens (args.map Ty.format) ++ " -> " ++ parens (rets.map Ty.format) ++ modes)

/-- A method's type: a function type without `func`, or the name of one. -/
partial def methodFormat (m : Method) : Format :=
  nameText m.name ++ " : " ++ match m.ty with
    | .func args rets modes => funcFormat args rets modes
    | t => t.format

/-- `{ m : (a) -> (r); … }`. -/
partial def serviceFormat (methods : Array Method) : Format :=
  braces (methods.map methodFormat)

end

/-- The text of a type, broken into lines of at most `width` columns where it can be. -/
def Ty.toDid (t : Ty) (width : Nat := 80) : String := t.format.pretty width

/-! ### Capped text, for error messages

An error message shows the types involved, but a message from anyone can have types of
thousands of fields and methods. Writing all of such a type's text, as `Ty.toDid` does, would
take as long as reading the whole type, to show only its start; `Ty.toDidCapped` writes no more
than it shows. (The decoder makes the text of an error only for the error that it returns, not
for those that it recovers from under `opt`: see `Failure` in Decode.lean.) -/

/-- The text that `Ty.toDidCapped` has written, how many more characters there is room for, and
whether it has had to leave some out. -/
private structure Capped where
  text : String := ""
  room : Nat
  cut : Bool := false

namespace Capped

/-- Writes `s`, or as much of it as there is room for. -/
private def push (c : Capped) (s : String) : Capped :=
  if c.room == 0 then (if s.isEmpty then c else { c with cut := true })
  else
    let n := s.length
    if n ≤ c.room then { c with text := c.text ++ s, room := c.room - n }
    else { c with text := c.text ++ (s.take c.room).toString, room := 0, cut := true }

/-- Writes a name as `nameText` does. Whether a name must be quoted depends on all of its
characters, so a name of more bytes than four times the room left is quoted without looking
(any name may be). -/
private def name (c : Capped) (s : String) : Capped :=
  if s.utf8ByteSize ≤ 4 * c.room + 4 then c.push (nameText s)
  else c.push ("\"" ++ escapeText (s.take c.room).toString)

/-- Writes a label as `Label.text` does. -/
private def label (c : Capped) : Label → Capped
  | .num id => c.push (toString id)
  | .name s => c.name s

/-- Writes `items` with `item` as `braces` does on one line, `{ a; b }`, or as `parens` does,
`(a, b)`. It stops once there is no room left, rather than going through the other items. -/
private def items (c : Capped) (xs : Array α) (item : Capped → α → Capped)
    (empty opening separator closing : String) : Capped := Id.run do
  if xs.isEmpty then return c.push empty
  let mut c := c.push opening
  for h : i in [0:xs.size] do
    if c.room == 0 then return { c with cut := true }
    if i > 0 then c := c.push separator
    c := item c xs[i]
  return c.push closing

mutual

/-- Writes a type as `Ty.format` lays it out on one line. -/
private partial def ty (c : Capped) (t : Ty) : Capped :=
  if c.room == 0 then { c with cut := true } else
  match t with
  | .opt t => ty (c.push "opt ") t
  | .vec .nat8 => c.push "blob"
  | .vec t => ty (c.push "vec ") t
  | .record fields =>
    if isTuple fields then
      (c.push "record ").items fields (fun c f => ty c f.ty) "{}" "{ " "; " " }"
    else
      (c.push "record ").items fields (fun c f => ty ((c.label f.label).push " : ") f.ty)
        "{}" "{ " "; " " }"
  | .variant cases =>
    (c.push "variant ").items cases (fun c f =>
      if f.ty == .null then c.label f.label else ty ((c.label f.label).push " : ") f.ty)
      "{}" "{ " "; " " }"
  | .func args rets modes => func (c.push "func ") args rets modes
  | .service methods =>
    (c.push "service ").items methods (fun c m =>
      let c := (c.name m.name).push " : "
      match m.ty with
      | .func args rets modes => func c args rets modes
      | t => ty c t)
      "{}" "{ " "; " " }"
  -- The primitive types, `var`, `table` and `future`, whose text is short.
  | t => c.push (t.format.pretty)

/-- Writes `(args) -> (rets) mode`, as `funcFormat` lays it out on one line. -/
private partial def func (c : Capped) (args rets : Array Ty) (modes : Array FuncMode) : Capped :=
  let c := c.items args ty "()" "(" ", " ")"
  let c := (c.push " -> ").items rets ty "()" "(" ", " ")"
  modes.foldl (fun c m => c.push (" " ++ m.keyword)) c

end

end Capped

/-- The text of a type on one line, as `Ty.toDid` writes it where it fits, but cut after `max`
characters, and then followed by `…`: for error messages. It writes only those characters, so
that a large type costs little more than a small one: what it reads of the rest is, for a record
whose first fields are 0, 1, …, the other labels, to see whether it is a tuple. -/
def Ty.toDidCapped (t : Ty) (max : Nat := 100) : String :=
  let c := Capped.ty { room := max } t
  if c.cut then c.text ++ "…" else c.text

instance : ToString Ty := ⟨(·.toDid)⟩

/-- The text of a `.did` file: a line `type X = …;` per definition, then the service, with a
line per method (unless one is longer than 1000 columns), as `.did` files list them. -/
def Interface.toDid (i : Interface) : String := Id.run do
  let mut out := ""
  for (name, t) in i.env.defs do
    -- A definition's name is an identifier, which the grammar does not quote.
    out := out ++ ("type " ++ name ++ " = " ++ t.format ++ ";" : Format).pretty 80 ++ "\n"
  if let some service := i.service then
    let initArgs := match i.initArgs with
      | some args => (parens (args.map Ty.format)).pretty 80 ++ " -> "
      | none => ""
    match service with
    | .service methods =>
      out := out ++ "service : " ++ initArgs ++ "{\n"
      for m in methods do
        out := out ++ "  " ++ (methodFormat m).pretty 1000 ++ ";\n"
      out := out ++ "}\n"
    | t => out := out ++ "service : " ++ initArgs ++ t.toDid ++ "\n"
  return out

end Candid
