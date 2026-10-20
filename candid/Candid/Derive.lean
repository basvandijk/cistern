module

public import Candid.Class
meta import Lean
meta import Candid.Hash

/-!
`deriving CandidType`: Lean writes the `CandidType` instance of a structure or an inductive type.

```
structure ProbeResult where
  result : Nat
  instructions : Array UInt64
  deriving CandidType
```

gives `ProbeResult` the Candid type `record { result : nat; instructions : vec nat64 }`, and
`toValue` and `ofValue` to match. `deriving instance CandidType for T` does the same for a type
declared elsewhere.

## The Candid type of a Lean type

- A `structure` is a `record` with a field per Lean field, labelled by the field's name. The
  fields of parent structures (`extends`) are fields of the record too.
- An `inductive` type is a `variant` with a case per constructor, labelled by the constructor's
  name. A case's type depends on the constructor's arguments: none, `null`; one, its type; more,
  a record of their names if they all have names, and a tuple, `record { t₀; t₁; … }`, otherwise.
  An argument has a name when the source gives it one, as `w` and `h` in `| rect (w h : Float)`;
  in `| pair : Nat → String → Shape`, Lean makes the names up (they show as `a✝`), and they do not
  count. So `| rect (w h : Float)` is `rect : record { h : float64; w : float64 }`, and
  `| pair : Nat → String → Shape` is `pair : record { nat; text }`. A single argument is the
  case's type, named or not: `| circle (radius : Float)` is `circle : float64`, as Lean code
  names arguments even where there is one (`| some (val : α)`). Rust's `#[derive(CandidType)]`
  has the same rules but for that one: there, a variant with one named field,
  `Circle { radius: f64 }`, is `Circle : record { radius : float64 }`. In Lean, a structure as
  the argument gives that record. An implicit argument, `{n : Nat}`, is an argument like the
  others.
- Candid sorts fields and cases by their id, the `idlHash` of their name, and the handler sorts
  them while Lean compiles the type, so that `toValue` writes them in that order. Two names with
  the same id are an error that names both: the binary format could not tell them apart.
- A type with parameters gets an instance that needs one for each type parameter:
  `structure Page (α : Type)` gets `instance [CandidType α] : CandidType (Page α)`. Universe
  levels are 0, as `CandidType` is for types in `Type`: `structure Box (α : Type u)` gets an
  instance for `Box α` with `α : Type`.
- Not supported, and an error: recursive types (their Candid type would need a named definition,
  `Ty.var`, which the handler does not make yet), mutually inductive types, indexed families
  (`inductive Vec : Nat → Type`), classes, `unsafe` types, propositions and types in `Type 1` or
  above, and fields or arguments that are proofs or types, whose types depend on other fields, or
  that have no `CandidType` instance.

`ofValue` accepts what the decoder makes at `ty`: it finds a record's fields by id, so their order
does not matter, and it says where an error is: `Candid: ProbeResult.result: expected a
value of type nat, got "seven"`, or `Candid: ProbeResult: missing field result`.

## Using it

A deriving handler is Lean code that runs while Lean compiles a file, so this module imports
Lean's own modules (`meta import Lean`), which a canister cannot link. In a file that starts with
`module`, import it with `meta import Candid.Derive`: Lean then loads it to compile the file but
leaves it out of the code that runs. In the C that `lean -c` writes for a module `X`, the runtime
initializer `runtime_initialize_X`, which `main` and a canister call, does not refer to this
module: only `initialize_X` and `meta_initialize_X`, the initializers of all phases and of the
meta phase, do, and nothing in a canister calls them. The file must also import `Candid` itself,
with `public import Candid`, as the instance uses the library when the program runs; without
that, Lean or the handler reports an error that names the import. A program that is not a
`module` writes `import Candid.Derive`.

In a module, the instance is public if the type is, wherever the `deriving` is, so the modules
that import this one can use the instances of its public types; the instance of a private type is
private. The instance's definition is not *exposed* to other modules, though (`@[no_expose]`):
they can use it but not unfold it in a proof. `deriving @[expose] CandidType` exposes it, which
needs the type's constructors and field types to be public.

The handler calls `idlHash` while Lean compiles, which is why it imports `Candid.Hash` with
`meta import` too: in a module, code that runs at compile time may only call code that a `meta`
import provides; the `public import Candid.Class` above is for the code that it writes. Nothing
here is public: a public definition's type would name Lean's types, such as `CommandElabM`,
which needs `public meta import Lean`, and that would make Lean's declarations visible in every
file that imports this one. The handler needs no name: `initialize`, at the end, registers it.

`set_option trace.Elab.Deriving.candidType true in` before a declaration shows the instance that
the handler writes.

## How the handler works

`deriveCandidType` is the handler. For each type, it reads the declaration (Lean's `InductiveVal`,
which lists the parameters and constructors), checks it, and writes the instance as *syntax*, as
if it were source text, with *quotations*: `` `(CandidType.toValue $x) `` is the syntax of that
term, with the syntax `x` spliced in where `$x` is. Then `elabCommand` compiles it as Lean would
compile the same text in the file. Names in a quotation are *hygienic*: a variable `v` that the
handler introduces cannot capture or be captured by a user's `v` (the trace shows it as `v✝`).

The handler knows the types of fields as Lean terms (`Expr`), not as text, and does not print
them back: names, implicit arguments and notation would not always read back the same. The
instance lets Lean infer them instead: with `tyOf {β : Type} [CandidType β] (_ : T → β) :=
CandidType.ty β`, `tyOf (fun x => x.items)` is `CandidType.ty (Array α)`, since Lean infers `β`
from the type of `x.items`. For a constructor `C : A → B → T`, a `tyOf` of two arguments does the
same with `tyOf C`.
-/

namespace Candid.Derive

open Lean Elab Command Meta Deriving
open Lean.Parser.Term (bracketedBinderF)

/-! ## What the handler reads from a declaration

The code below runs while Lean compiles a file that derives `CandidType`, so it is `meta`. It is
written in Lean's own monads: `MetaM`, which can look at declarations and types, `TermElabM`,
which can also elaborate terms, and `CommandElabM`, which can add declarations. A `do` block in
them reads like imperative code; `← e` runs `e` and takes its result, and `throwError m!"…"`
stops with an error message, which Lean shows where the `deriving` clause is. -/

/-- The last component of a name, such as `rect` for `Shape.rect`, without the marks that
hygiene adds. A `Name` is a list of components, and `match` takes it apart by its constructors:
`.str p s` is the name `p` followed by the component `s`. -/
meta def lastString (n : Name) : String :=
  match n.eraseMacroScopes with
  | .str _ s => s
  | n => n.toString

/-- A record field or a variant case, with its Candid name, its id, and `info`, what else the
handler needs: the Lean name of a field, the position of an argument, a constructor. -/
structure Item (α : Type) where
  name : String
  id : UInt32
  info : α

/-- Gives each name its id and sorts by id, the order of a record's fields and a variant's cases
in Candid. Names with the same id stay in their order, for `checkUnique`'s message. -/
meta def sortById (named : Array (String × α)) : Array (Item α) :=
  -- `{ name, id := …, info : Item α }` is an `Item α`; `name` alone is `name := name`.
  let items := named.mapIdx fun i (name, info) => (i, { name, id := idlHash name, info : Item α })
  (items.qsort fun (i, a) (j, b) => a.id < b.id || (a.id == b.id && i < j)).map (·.2)

/-- Fails if two of the sorted `items` have the same id, naming both: `the {what} a and b{whose}
have the same id`. -/
meta def checkUnique (typeName : Name) (what : String) (items : Array (Item α))
    (whose : String := "") : MetaM Unit := do
  for (a, b) in items.zip (items.extract 1 items.size) do
    if a.id == b.id then
      throwError m!"deriving CandidType for {.ofConstName typeName}: the {what} {a.name} and \
        {b.name}{whose} have the same id {a.id} (their idlHash), which Candid cannot tell \
        apart; rename one of them"

/-- How the arguments of a constructor make the type of its case. -/
inductive Payload where
  /-- No arguments: `null`. -/
  | unit
  /-- One argument: its type. -/
  | single
  /-- Named arguments: a record of them, sorted by id, each with its position. -/
  | named (fields : Array (Item Nat))
  /-- Arguments without names, or not all with names: a tuple of this many. -/
  | tuple (count : Nat)

/-- A constructor: its name, its number of arguments, and how they make its case's type. -/
structure Ctor where
  name : Name
  arity : Nat
  payload : Payload

/-- Fails unless the inductive type is one that the handler supports: data in `Type` (universe
0), without indices, not recursive, not mutual, not a class. -/
meta def checkType (typeName : Name) (indVal : InductiveVal) : MetaM Unit := do
  let reject (why : MessageData) : MetaM Unit :=
    throwError m!"deriving CandidType for {.ofConstName typeName}: {why}"
  if isClass (← getEnv) typeName then
    reject "it is a class; Candid types are for data"
  if indVal.all.length > 1 then
    reject m!"it is one of the mutually inductive types \
      {MessageData.andList (indVal.all.map (m!"{.ofConstName ·}"))}, which are not supported"
  if indVal.isRec || indVal.numNested > 0 then
    reject "it is recursive, which deriving does not support yet: its Candid type would need a \
      named type definition (`Ty.var`)"
  if indVal.numIndices > 0 then
    reject "it is an indexed family, whose constructors make values of different types, which \
      is not supported"
  if indVal.isUnsafe then
    reject "it is `unsafe`"

/-- Whether the parameter `p` is a type in `Type`, which `CandidType` takes: such a parameter `α`
gets an instance `[CandidType α]`. One in `Type 1` gets none, and needs none: a field of its type
would put the type itself in `Type 1`, which the handler rejects. -/
meta def isTypeParam (p : Expr) : MetaM Bool := do
  isDefEq (← inferType p) (mkSort Level.one)

/-- Runs `k` with the type's parameters as local variables, its universe levels at 0 (`CandidType`
is for types in `Type`), and an instance `[CandidType α]` for each parameter `α` in `Type`, as the
derived instance has. `k` gets the parameters and the type applied to them. -/
meta def withParams (typeName : Name) (indVal : InductiveVal) (k : Array Expr → Expr → MetaM α) :
    MetaM α := do
  let levels := indVal.levelParams.map fun _ => Level.zero
  let type := indVal.type.instantiateLevelParams indVal.levelParams levels
  -- `forallBoundedTelescope` opens the first `numParams` binders of `∀ (α : Type) …, Type` and
  -- runs the function with them as local variables (`fvar`s), as `intro` does in a proof.
  forallBoundedTelescope type indVal.numParams fun params sort => do
    unless ← isDefEq sort (mkSort Level.one) do
      throwError m!"deriving CandidType for {.ofConstName typeName}: it is in `{sort}`, but \
        CandidType is for types in `Type`"
    -- `let rec` defines a local recursive function. Lean checks that it ends, as `i` grows
    -- towards `params.size`; each instance stays in scope for the rest, as `withLocalDecl` runs
    -- the rest inside it.
    let rec addInstances (i : Nat) : MetaM α := do
      if h : i < params.size then
        let p := params[i]
        if ← isTypeParam p then
          withLocalDecl `inst .instImplicit (mkApp (mkConst ``CandidType) p) fun _ =>
            addInstances (i + 1)
        else addInstances (i + 1)
      else
        k params (mkAppN (mkConst typeName levels) params)
    addInstances 0

/-- Fails unless a field or argument `x` can be Candid: not a proof or a type, of a type that has
a `CandidType` instance and depends on none of the `others` (the other fields or arguments). `what`
says which one it is, `kind` whether it is a field or an argument. -/
meta def checkField (typeName : Name) (kind : String) (what : MessageData) (x : Expr)
    (others : Array Expr) : MetaM Unit := do
  let reject (why : MessageData) : MetaM Unit :=
    throwError m!"deriving CandidType for {.ofConstName typeName}: {what} {why}"
  if ← isProof x then reject "is a proof, which has no Candid value"
  if ← isType x then reject "is a type, which has no Candid value"
  -- `cleanupAnnotations` drops `optParam`, the mark of a default value, as in `x : Nat := 0`.
  let t := (← inferType x).cleanupAnnotations
  -- The type as text on one line (`ppExpr` is Lean's pretty printer).
  let text := (← ppExpr t).pretty 1000
  if others.any (t.containsFVar ·.fvarId!) then
    reject m!"has type {text}, which depends on the value of another {kind}, as no Candid type \
      can"
  -- `synthInstance?` looks for an instance as Lean does for `[CandidType t]`; `try … catch` turns
  -- an error (a type outside `Type`, say) into none.
  let instance? ← try synthInstance? (mkApp (mkConst ``CandidType) t) catch _ => pure none
  if instance?.isNone then
    reject m!"has type {text}, which has no CandidType instance"

/-- The fields of a structure, those of its parents included, sorted by id. -/
meta def structFields (typeName : Name) (indVal : InductiveVal) : MetaM (Array (Item Name)) := do
  let names := getStructureFieldsFlattened (← getEnv) typeName (includeSubobjectFields := false)
  withParams typeName indVal fun _ self =>
    withLocalDeclD `x self fun x => do
      for name in names do
        -- `mkProjection x name` is `x.name`, through the parent for a parent's field.
        checkField typeName "field" m!"field {name}" (← mkProjection x name) #[x]
  let fields := sortById (names.map fun name => (lastString name, name))
  checkUnique typeName "fields" fields
  return fields

/-- The constructors of an inductive type, sorted by id. -/
meta def inductCases (typeName : Name) (indVal : InductiveVal) : MetaM (Array (Item Ctor)) := do
  let ctors ← indVal.ctors.toArray.mapM fun ctorName => do
    let ctorInfo ← getConstInfoCtor ctorName
    let levels := ctorInfo.levelParams.map fun _ => Level.zero
    let ctorType := ctorInfo.type.instantiateLevelParams ctorInfo.levelParams levels
    let payload ← withParams typeName indVal fun params _ => do
      -- The constructor's type is `∀ params, A → B → T params`; instantiating the parameters and
      -- opening the rest makes its arguments local variables.
      forallTelescopeReducing (← instantiateForall ctorType params) fun args _ => do
        let mut names := #[]
        for h : i in [0:args.size] do
          let userName := (← args[i].fvarId!.getDecl).userName
          let what := if userName.hasMacroScopes then m!"argument {i + 1}"
            else m!"argument {userName}"
          checkField typeName "argument" m!"{what} of constructor {lastString ctorName}" args[i]
            (args.extract 0 i)
          -- Names that Lean makes up have *macro scopes*, the marks of hygiene.
          unless userName.hasMacroScopes do
            names := names.push userName
        if args.size == 0 then return Payload.unit
        if args.size == 1 then return Payload.single
        if names.size < args.size then return Payload.tuple args.size
        let fields := sortById (names.mapIdx fun i name => (lastString name, i))
        checkUnique typeName "arguments" fields s!" of constructor {lastString ctorName}"
        return Payload.named fields
    return (lastString ctorName, { name := ctorName, arity := ctorInfo.numFields, payload : Ctor })
  let cases := sortById ctors
  checkUnique typeName "constructors" cases
  return cases

/-! ## The instance that the handler writes

The instance is one term: a few local helpers (`let`), then the class's three fields, `ty`,
`toValue` and `ofValue`. The helpers come first:

- `within path r` is `r`, with `path: ` before its error message, if it fails.
- `field fields i id owner name byName` is `ofValue` of the field with id `id` among `fields`, a
  record's, with `owner.name` in its error, or an error if there is none. The decoder makes the
  fields of `ty`, in its order, so `field` looks at the `i`th first, and, if `byName`, compares a
  label's name with `name` before it computes the label's id, the `idlHash` of the name. Values
  made otherwise can have their fields in any order. A tuple's field `i` has the id `i`, not that
  of the name `"i"`, so it is found by id only, with `byName` false.

For a structure `Point` with fields `x : Nat` and `name : String`, the rest is, in essence:

```
let tyOf {β : Type} [CandidType β] (_ : Point → β) : Candid.Ty := CandidType.ty β
let ty := Candid.Ty.record #[⟨.name "x", tyOf (·.x)⟩, ⟨.name "name", tyOf (·.name)⟩]
{ ty
  toValue := fun p => .record #[(.name "x", toValue p.x), (.name "name", toValue p.name)]
  ofValue := fun
    | .record fields => do
      let x ← field fields 0 120 "Point" "x" true
      let name ← field fields 1 1224700491 "Point" "name" true
      pure { x, name }
    | v => CandidType.mismatch ty v }
```

with the fields in id order (`x` is 120, `name` 1224700491). For an inductive type, `toValue` is a
`match` with a case per constructor, and `ofValue` compares the id of the variant's label with
those of the constructors. -/

/-- The syntax of a number. -/
meta def numLit (n : Nat) : Term := Syntax.mkNumLit (toString n)

/-- The syntax of a string literal. -/
meta def strLit (s : String) : Term := Syntax.mkStrLit s

/-- `n` fresh hygienic names `a✝`, for variables of the generated code. -/
meta def freshIdents (base : Name) (n : Nat) : TermElabM (Array Ident) :=
  (Array.range n).mapM fun _ => return mkIdent (← mkFreshUserName base)

/-- A reference to the constructor `name` that a declaration of the same name in the scope of the
`deriving` clause cannot hide, as `mkInductiveApp` makes for the type. -/
meta def ctorIdent (name : Name) : Ident := mkCIdent name

/-- The instance's methods for a structure, whose type applied to the parameters is `self`. -/
meta def mkStructBody (owner : String) (self : Term) (fields : Array (Item Name)) :
    TermElabM Term := do
  let x := mkIdent (← mkFreshUserName `x)
  let tyFields ← fields.mapM fun f =>
    `({ label := Candid.Label.name $(strLit f.name),
        ty := tyOf (fun ($x : $self) => ($x).$(mkIdent f.info):ident) })
  let values ← fields.mapM fun f =>
    `((Candid.Label.name $(strLit f.name), CandidType.toValue ($x).$(mkIdent f.info):ident))
  let vars ← freshIdents `a fields.size
  -- `doElem` is the syntax category of a statement in a `do` block. `mapIdxM` gives each field's
  -- position too.
  let reads ← fields.mapIdxM fun i f =>
    `(doElem| field fields $(numLit i) $(numLit f.id.toNat) $(strLit owner) $(strLit f.name) true)
  let names := fields.map (mkIdent ·.info)
  -- `$xs,*` splices an array of syntax with commas between; `$[…]*` repeats a piece of syntax
  -- for each element of the arrays inside it.
  `(let tyOf {β : Type} [CandidType β] (_ : $self → β) : Candid.Ty := CandidType.ty β
    let ty : Candid.Ty := Candid.Ty.record #[$tyFields,*]
    { ty := ty
      toValue := fun $x => Candid.Value.record #[$values,*]
      ofValue := fun v => match v with
        | Candid.Value.record fields => do
          $[let $vars:ident ← $reads]*
          pure { $[$names:ident := $vars],* }
        | v => CandidType.mismatch ty v })

/-- The instance's methods for an inductive type, whose type applied to the parameters is
`self`, with `params` the names of the parameters. -/
meta def mkInductBody (owner : String) (self : Term) (params : Array Ident)
    (cases : Array (Item Ctor)) : TermElabM Term := do
  -- The type of each case, as a local definition `tyᵢ`, and the variant `ty` of them all.
  let tyNames ← freshIdents `ty cases.size
  let mut tyDefs := #[]
  for c in cases do
    let betas ← freshIdents `β c.info.arity
    let betaTys ← betas.mapM fun b => `(CandidType.ty $b)
    let caseTy : Term ← match c.info.payload with
      | .unit => `(Candid.Ty.null)
      | .single => pure betaTys[0]!
      | .named fields => do
        let fs ← fields.mapM fun f =>
          `({ label := Candid.Label.name $(strLit f.name), ty := $(betaTys[f.info]!) })
        `(Candid.Ty.record #[$fs,*])
      | .tuple _ => `(Candid.Ty.tuple #[$betaTys,*])
    if c.info.arity == 0 then
      tyDefs := tyDefs.push caseTy
    else
      -- `tyOf (@C α)` makes Lean infer `β₀ β₁ …` from the constructor's type `A → B → T α`.
      let ctorType ← betas.foldrM (fun b acc => `($b → $acc)) self
      let typeBinders ← betas.mapM fun b => `(bracketedBinderF| {$b : Type})
      let instBinders ← betas.mapM fun b => `(bracketedBinderF| [CandidType $b])
      let binders : Array (TSyntax ``Parser.Term.letIdBinder) :=
        (typeBinders ++ instBinders).map (⟨·.raw⟩)
      tyDefs := tyDefs.push (← `(
        let tyOf $binders* (_ : $ctorType) : Candid.Ty := $caseTy
        tyOf (@$(ctorIdent c.info.name) $params*)))
  let variantCases ← (cases.zip tyNames).mapM fun (c, tyName) =>
    `({ label := Candid.Label.name $(strLit c.name), ty := $tyName })
  -- `toValue`: a `match` with a case per constructor, `@C _ a₀ a₁ => .variant (.name "C") …`.
  let x := mkIdent (← mkFreshUserName `x)
  let alts ← cases.mapM fun c => do
    let args ← freshIdents `a c.info.arity
    let wildcards ← params.mapM fun _ => `(_)
    let payload : Term ← match c.info.payload with
      | .unit => `(Candid.Value.null)
      | .single => `(CandidType.toValue $(args[0]!):ident)
      | .named fields => do
        let fs ← fields.mapM fun f =>
          `((Candid.Label.name $(strLit f.name), CandidType.toValue $(args[f.info]!):ident))
        `(Candid.Value.record #[$fs,*])
      | .tuple _ => do
        let fs ← args.mapIdxM fun i a => `((Candid.Label.num $(numLit i), CandidType.toValue $a))
        `(Candid.Value.record #[$fs,*])
    `(Parser.Term.matchAltExpr| | @$(ctorIdent c.info.name) $wildcards* $args* =>
        Candid.Value.variant (Candid.Label.name $(strLit c.name)) $payload)
  let toValue ← if alts.isEmpty then `(fun $x => nomatch $x)
    else `(fun $x => match $x:term with $alts:matchAlt*)
  -- `ofValue`: `if id == id₀ then … else if id == id₁ then … else` an error.
  let p := mkIdent (← mkFreshUserName `p)
  let mut decodeCases ← `(Candid.fail ($(strLit owner) ++ ": unknown case " ++ l.text))
  for (c, tyName) in (cases.zip tyNames).reverse do
    let path := strLit s!"{owner}.{c.name}"
    let ctor ← `(@$(ctorIdent c.info.name) $params*)
    -- `@C α a₀ a₁` is one application, with all arguments explicit: in `(@C α) a₀ a₁`, Lean would
    -- fill in an implicit argument, as in `| c {n : Nat} (s : String)`, and take `a₀` for `s`.
    let decodeArgs (reads : Array (TSyntax `doElem)) (args : Array Ident) : TermElabM Term :=
      `(match $p:term with
        | Candid.Value.record fields => do
          $[$reads:doElem]*
          pure (@$(ctorIdent c.info.name) $params* $args*)
        | $p => within $path (CandidType.mismatch $tyName $p))
    let decode : Term ← match c.info.payload with
      | .unit => `((fun () => $ctor) <$> within $path (CandidType.ofValue $p))
      | .single => `($ctor <$> within $path (CandidType.ofValue $p))
      | .named fields => do
        let args ← freshIdents `a c.info.arity
        decodeArgs (← fields.mapIdxM fun i f => do
          let read ← `(field fields $(numLit i) $(numLit f.id.toNat) $path $(strLit f.name) true)
          `(doElem| let $(args[f.info]!):ident ← $read:term)) args
      | .tuple count => do
        let args ← freshIdents `a count
        -- A tuple's field `i` has the id `i`, which a label named `"i"` does not have.
        let reads ← args.mapIdxM fun i a => do
          let read ← `(field fields $(numLit i) $(numLit i) $path $(strLit s!"{i}") false)
          `(doElem| let $a:ident ← $read:term)
        decodeArgs reads args
    decodeCases ← `(if id == $(numLit c.id.toNat) then $decode else $decodeCases)
  let methods ←
    `(let ty : Candid.Ty := Candid.Ty.variant #[$variantCases,*]
      { ty := ty
        toValue := $toValue
        ofValue := fun v => match v with
          | Candid.Value.variant l $p => let id := l.id; $decodeCases
          | v => CandidType.mismatch ty v })
  (tyNames.zip tyDefs).foldrM (init := methods) fun (tyName, tyDef) body =>
    `(let $tyName : Candid.Ty := $tyDef; $body)

/-- The `instance` command for a type. In a module, an instance's definition is *exposed* to the
modules that import it, unless it is `@[no_expose]`; an exposed definition can only use what is
public, which a type's private constructor or field type is not. The instance is `@[no_expose]`
unless `expose`, as with `deriving @[expose] CandidType` or in an `@[expose] section`. Other
modules can use it either way; they only cannot unfold it in proofs. -/
meta def mkInstanceCmd (typeName : Name) (expose : Bool) : TermElabM Command := do
  let indVal ← getConstInfoInduct typeName
  checkType typeName indVal
  -- The type's name in error messages, as the user wrote it, also for a private type.
  let owner := toString (privateToUserName typeName)
  -- `mkInductArgNames` makes fresh names for the parameters, `α✝`; the instance binds them as
  -- `{α✝}` and, for those in `Type`, also `[CandidType α✝]`.
  let paramNames ← mkInductArgNames indVal
  let binders ← withParams typeName indVal fun params _ => do
    let mut binders := #[]
    for (p, name) in params.zip paramNames do
      binders := binders.push (← `(bracketedBinderF| {$(mkIdent name)}))
      if ← isTypeParam p then
        binders := binders.push (← `(bracketedBinderF| [CandidType $(mkIdent name)]))
    return binders
  let self ← mkInductiveApp indVal paramNames
  let methods ← if isStructure (← getEnv) typeName then
      mkStructBody owner self (← structFields typeName indVal)
    else
      mkInductBody owner self (paramNames.map mkIdent) (← inductCases typeName indVal)
  let value ← `(
    let within {β : Type} (path : String) (r : Except Candid.Error β) : Except Candid.Error β :=
      r.mapError fun e => { e with message := path ++ ": " ++ e.message }
    let field {β : Type} [CandidType β] (fields : Array (Candid.Label × Candid.Value)) (i : Nat)
        (id : UInt32) (owner name : String) (byName : Bool) : Except Candid.Error β :=
      let isIt (l : Candid.Label) : Bool := match l with
        | Candid.Label.name s => (byName && s == name) || l.id == id
        | Candid.Label.num n => n == id
      -- `filter` keeps the `i`th field if it is the one, and `<|>` looks further if it is not.
      match fields[i]?.filter (isIt ·.1) <|> fields.find? (isIt ·.1) with
      | some (_, v) => within (owner ++ "." ++ name) (CandidType.ofValue v)
      | none => Candid.fail (owner ++ ": missing field " ++ name)
    $methods)
  if expose then `(instance $binders:bracketedBinder* : CandidType $self := $value)
  else `(@[no_expose] instance $binders:bracketedBinder* : CandidType $self := $value)

/-- The deriving handler: writes a `CandidType` instance for each of the types. Lean calls it for
`deriving CandidType` after a declaration, and for `deriving instance CandidType for T, U`. It
returns `false` for what is not an inductive type, to let Lean say that it does not apply. -/
meta def deriveCandidType (typeNames : Array Name) : CommandElabM Bool :=
  -- In a module, Lean elaborates a public declaration, and its `deriving` clause, with private
  -- declarations hidden, as a public definition must not use them; the handler reads some, such as
  -- the projection of a public structure's `private` field, so it shows them again, as Lean's
  -- `deriving Hashable` does. The instance gets its visibility from the scope that Lean sets up
  -- for deriving handlers, public if the types are, and from `@[no_expose]`.
  withoutExporting do
  unless ← typeNames.allM isInductive do
    return false
  for typeName in typeNames do
    -- In a module, the instance can only use the library if the file imports it for the code that
    -- runs: `meta import Candid.Derive` makes it available to the compiler only.
    if getIRPhases (← getEnv) ``CandidType.toValue == .comptime then
      throwError m!"deriving CandidType for {.ofConstName typeName}: the instance needs the \
        library when the program runs; add `public import Candid` next to \
        `meta import Candid.Derive`"
    -- As Lean's own handlers do: a type with private constructors gets no `@[expose]` instance.
    withoutExposeFromCtors typeName do
      let expose := (← getScope).attrs.any (· matches `(Parser.Term.attrInstance| expose))
      let cmd ← liftTermElabM (mkInstanceCmd typeName expose)
      trace[Elab.Deriving.candidType] "{cmd}"
      elabCommand cmd
  return true

-- `initialize` runs when a file that imports this module is compiled, before its first line:
-- it adds the handler to Lean's table of deriving handlers, and the trace option.
meta initialize
  registerDerivingHandler ``CandidType deriveCandidType
  registerTraceClass `Elab.Deriving.candidType

end Candid.Derive
