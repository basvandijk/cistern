module

public import Candid.Ty

/-!
Subtyping: `t1 <: t2` says that a value of `t1` can be read as one of `t2`, which is what makes
a change of an interface safe (spec: "Upgrading and Subtyping"). The decoder needs it for
references only: a function or service reference in a message is accepted at an expected type
if its type in the message is a subtype (spec: "Coercion", "References"). Other values are
converted by the coercion rules in Candid/Decode.lean, value by value.

Types can be recursive, through `var` (a name defined in a `TypeEnv`) and `table` (an entry of a
message's type table), so following them can go on forever. The check is therefore
*coinductive*, as the Rust crate's is (`subtype.rs`): it keeps a set of the pairs of types that
it is checking or has checked, and when it meets one of them again, it takes the pair to be
related. Only pairs with a reference on one side go into the set, as only a reference leads
back to a pair already met; there are finitely many of those, so the check ends.

Every premise of every rule must hold, so the first one that fails decides the whole check. The
checker therefore runs in a monad with errors, where a failed premise is an error that ends it,
and with state, the set of assumed pairs and a count of steps (see `checkSubtype`).
-/

public section

namespace Candid

/-- A set of pairs of types, as the subtype check assumes them. It is a hash table: an array of
buckets, where a pair goes into the bucket that its hash picks, so that looking a pair up
compares it with about one other rather than with all. Lean's `Init`, which is all that a
canister links, has no hash set. Each pair is kept with its hash, which is compared first, as
comparing types takes time in proportion to their size. -/
structure TyPairSet where
  /-- The buckets, with the pairs and their hashes. -/
  buckets : Array (Array (UInt64 × Ty × Ty)) := Array.replicate 8 #[]
  /-- The number of pairs. -/
  size : Nat := 0

instance : Inhabited TyPairSet := ⟨{}⟩

namespace TyPairSet

/-- The bucket for the hash `h`, among `n`. The remainder is taken in `UInt64`: a `Nat` of 64
bits would be a big number on a 32-bit canister, where small `Nat`s have 31 bits. -/
private def bucket (h : UInt64) (n : Nat) : Nat := (h % n.toUInt64).toNat

/-- Whether the set holds the pair `(t1, t2)`. -/
def contains (s : TyPairSet) (t1 t2 : Ty) : Bool :=
  let h := hash (t1, t2)
  match s.buckets[bucket h s.buckets.size]? with
  | some entries => entries.any fun (h', t1', t2') => h' == h && t1' == t1 && t2' == t2
  | none => false

/-- The set with the pair `(t1, t2)` added, which it must not hold already. When there are as
many pairs as buckets, the buckets double first.

`let { buckets, size } := s` takes the structure apart, so that nothing refers to `s` any more
when the array is changed: Lean changes an array in place only if nothing else refers to it,
and copies it otherwise. -/
def insert (s : TyPairSet) (t1 t2 : Ty) : TyPairSet :=
  let { buckets, size } := s
  let buckets := if size < buckets.size then buckets else grow buckets
  let h := hash (t1, t2)
  { buckets := buckets.modify (bucket h buckets.size) (·.push (h, t1, t2)), size := size + 1 }
where
  /-- The same pairs in twice as many buckets, at least 8. -/
  grow (buckets : Array (Array (UInt64 × Ty × Ty))) : Array (Array (UInt64 × Ty × Ty)) :=
    let n := max 8 (2 * buckets.size)
    buckets.foldl (init := Array.replicate n #[]) fun acc entries =>
      entries.foldl (init := acc) fun acc entry => acc.modify (bucket entry.1 n) (·.push entry)

end TyPairSet

/-- Limits on a subtype check: how deeply it may recurse, and how many steps it may take, a step
being the comparison of one pair of types. A decoder needs them, as a message's types are as
large and as deep as its sender likes. -/
structure SubtypeLimits where
  /-- How deeply the check may recurse. -/
  maxDepth : Nat
  /-- How many steps the check may take. -/
  fuel : Nat

/-- What `checkSubtype` found. -/
inductive SubtypeResult where
  /-- `t1 <: t2`, found in `steps` steps. `assumed` is the set that the check started from, with
  the pairs added that it assumed on the way: they all hold, so a later check of the same types
  can start from it. -/
  | holds (assumed : TyPairSet) (steps : Nat)
  /-- `t1 <: t2` does not hold, which the check found in `steps` steps. -/
  | fails (steps : Nat)
  /-- The check needed more steps, or a deeper recursion, than its limits allow. -/
  | exceeded (message : String)
  deriving Inhabited

/-- Why a check stopped early: a premise failed, or a limit was reached. -/
private inductive Stop where
  | fails
  | exceeded (message : String)
  deriving Inhabited

/-- The state of a check: the pairs assumed so far, and the steps taken. -/
private structure CheckState where
  assumed : TyPairSet
  steps : Nat := 0

/-- Whether the type is a reference to another, which only `TypeEnv.resolve` can see through. -/
private def isRef : Ty → Bool
  | .var _ | .table _ => true
  | _ => false

/-- Whether two functions have the same modes, as sets (spec: "Functions"). -/
private def sameModes (m1 m2 : Array FuncMode) : Bool :=
  m1.all m2.contains && m2.all m1.contains

/-- Decides `t1 <: t2`, where `var`s refer to `env` and `table`s to `table`, starting from the
pairs in `assumed`, which must hold, and within `limits`, if there are any. A type that refers
to a name or an index that is not defined is a subtype of itself only.

The rules, from the spec and `subtype.rs`, first match wins: a type is a subtype of itself; a
pair met before holds; a reference is followed to the type that it stands for; `t <: reserved`;
`empty <: t`; `nat <: int`; `service _ <: principal`; `vec a <: vec b` if `a <: b`; `t <: opt _`
for any `t`; and the rules for records, variants, services and functions, at `records`,
`variants`, `services` and in `sub`.

`EStateM Stop CheckState α` is the type of a computation that, from a state of type
`CheckState`, either succeeds with a value of type `α` and a new state, or stops with an error
of type `Stop`. Its `do` blocks read like imperative code: `← get` reads the state, `modify f`
changes it, `throw e` stops, and `← x` runs `x` and takes its value, passing an error on.

`partial` lets the definition call itself without a proof that the recursion ends, which Lean
would otherwise ask for; here it ends because the pairs that can be assumed are finitely many.
`where` introduces local definitions that can use the arguments of the main one (`env`,
`table`, `limits`). -/
partial def checkSubtype (env : TypeEnv) (table : Array Ty) (limits : Option SubtypeLimits)
    (assumed : TyPairSet) (t1 t2 : Ty) : SubtypeResult :=
  -- `run` gives the computation its first state; `match` takes its result apart, case by case.
  match (sub t1 t2 0).run { assumed } with
  | .ok () s => .holds s.assumed s.steps
  | .error .fails s => .fails s.steps
  | .error (.exceeded message) _ => .exceeded message
where
  /-- Fails the check unless `t1 <: t2`, at nesting `depth`. -/
  sub (t1 t2 : Ty) (depth : Nat) : EStateM Stop CheckState Unit := do
    let steps := (← get).steps
    if let some l := limits then
      if depth ≥ l.maxDepth then throw (.exceeded s!"Recursion limit exceeded at depth {depth}")
      if steps ≥ l.fuel then throw (.exceeded "Decoding cost exceeds the limit")
    modify fun s => { s with steps := steps + 1 }
    if t1 == t2 then return
    if isRef t1 || isRef t2 then
      -- A pair met before holds: it is being checked further up, or it was checked already.
      if (← get).assumed.contains t1 t2 then return
      modify fun s => { s with assumed := s.assumed.insert t1 t2 }
      sub (← resolve t1) (← resolve t2) (depth + 1)
    else
      match t1, t2 with
      | _, .reserved | .empty, _ | .nat, .int | .service _, .principal => return
      | .vec a, .vec b => sub a b (depth + 1)
      -- Every type is a subtype of every option type: `null` and `reserved`, an option whose
      -- content is a subtype, a type that is a subtype of the content, and, by the spec's two
      -- unusual rules (spec: "Options"), all the others too. The Rust crate checks the first
      -- cases only to warn when the unusual rules were needed.
      | _, .opt _ => return
      | .record fs1, .record fs2 => records fs1 fs2 depth
      | .variant cs1, .variant cs2 => variants cs1 cs2 depth
      | .service ms1, .service ms2 => services ms1 ms2 depth
      | .func args1 rets1 modes1, .func args2 rets2 modes2 =>
        unless sameModes modes1 modes2 do throw .fails
        -- Arguments and results are compared as tuples, `record { 0 : a₀; 1 : a₁; … }`, so
        -- that arguments can be dropped and results added; arguments the other way round.
        sub (.tuple args2) (.tuple args1) (depth + 1)
        sub (.tuple rets1) (.tuple rets2) (depth + 1)
      | _, _ => throw .fails
  /-- The type that a reference leads to; a reference that leads nowhere fails the check. -/
  resolve (t : Ty) : EStateM Stop CheckState Ty :=
    match env.resolve table t with
    | .ok t => pure t
    | .error _ => throw .fails
  /-- Every field of the record `fs2` is in `fs1` with a subtype of its type, or is not, and has
  type `opt`, `null` or `reserved`. Fields are sorted by id, so one pass over both pairs them
  up. `let mut` declares a variable that the loops below can change. -/
  records (fs1 fs2 : Array Field) (depth : Nat) : EStateM Stop CheckState Unit := do
    let mut i := 0
    for f2 in fs2 do
      while i < fs1.size && fs1[i]!.label.id < f2.label.id do
        i := i + 1
      if i < fs1.size && fs1[i]!.label.id == f2.label.id then
        sub fs1[i]!.ty f2.ty (depth + 1)
      else
        match ← resolve f2.ty with
        | .opt _ | .null | .reserved => pure ()
        | _ => throw .fails
  /-- Every case of the variant `cs1` is in `cs2`, with a supertype of its type. -/
  variants (cs1 cs2 : Array Field) (depth : Nat) : EStateM Stop CheckState Unit := do
    let mut j := 0
    for c1 in cs1 do
      while j < cs2.size && cs2[j]!.label.id < c1.label.id do
        j := j + 1
      if j < cs2.size && cs2[j]!.label.id == c1.label.id then
        sub c1.ty cs2[j]!.ty (depth + 1)
      else
        throw .fails
  /-- Every method of the service `ms2` is in `ms1`, with a subtype of its type. Methods are
  sorted by name. -/
  services (ms1 ms2 : Array Method) (depth : Nat) : EStateM Stop CheckState Unit := do
    let mut i := 0
    for m2 in ms2 do
      while i < ms1.size && ms1[i]!.name < m2.name do
        i := i + 1
      if i < ms1.size && ms1[i]!.name == m2.name then
        sub ms1[i]!.ty m2.ty (depth + 1)
      else
        throw .fails

/-- Whether `t1 <: t2`: a value of `t1` can be read as one of `t2` (spec: "Upgrading and
Subtyping"). A `var` refers to a definition in `env`, a `table` to an entry of `table`, the type
table of a message (see `decodeAny`). Fields must be sorted by id and methods by name, as
`Ty.recordOf`, `Ty.variantOf` and `Ty.serviceOf` sort them. -/
def isSubtype (env : TypeEnv) (t1 t2 : Ty) (table : Array Ty := #[]) : Bool :=
  match checkSubtype env table none {} t1 t2 with
  | .holds .. => true
  | _ => false

end Candid
