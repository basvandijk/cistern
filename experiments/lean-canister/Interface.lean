module

public import Candid
meta import Candid.Derive

/-!
The canister's interface: its methods, with the Lean types of their arguments and results.
Canister.lean's handlers get their types from it, and GenDid.lean the canister's Candid
interface, canister.did, so the two cannot disagree. The Lean types give the Candid types through
their `CandidType` instances (../../candid/Candid/Class.lean): `String` is `text`, `Nat` is
`nat`, `Array String` is `vec text`. Arguments and results are sequences, through the
`CandidArgs` instances: one type is a sequence of one, and a product, such as
`String × Nat × Option Nat`, is one of several, here `(text, nat, opt nat)`.

`meta import Candid.Derive` makes `deriving CandidType` available while Lean compiles this file;
the deriving handler, and the Lean modules that it imports, are not part of the canister. A file
can import a module this way only if it is a module itself (`module`, above), in which
definitions are private unless they are `public`, as everything in the `public section` below is.
-/

public section

namespace Interface

/-- The reply of `probe`: the probe's result, and the instructions that each run took, a
`record { result : nat; instructions : vec nat64 }`. `deriving CandidType` writes the instance,
which a hand-written one would spell out field by field. -/
structure ProbeResult where
  result : Nat
  instructions : Array UInt64
  deriving CandidType

/-- Whether a method is a query or an update. -/
inductive Kind where
  | query
  | update
  deriving BEq

/-- A method of the canister: its name, its kind, and the Lean types of its arguments and of its
results, each `()`, a type, or a product of types. A structure can have types as fields: `Args`
and `Rets` are types, and the fields in square brackets are instances that Lean finds when an
`Endpoint` is made, here the `CandidArgs` instances of those types. -/
structure Endpoint where
  name : String
  kind : Kind
  Args : Type
  Rets : Type
  [args : CandidArgs Args]
  [rets : CandidArgs Rets]

/-! The methods. They are `abbrev`s, definitions that Lean unfolds wherever it compares types,
also when it looks for an instance, so that in Canister.lean `greet.Args` is `String`, with
`String`'s instances. A `def` would not do: in a module, only the type of a `def` is visible to
the modules that import it, here `Endpoint`, unless it is marked `@[expose]`, and even then Lean
does not unfold it to look for instances. -/

abbrev greet : Endpoint :=
  { name := "greet", kind := .query, Args := String, Rets := String }

abbrev hello : Endpoint :=
  { name := "hello", kind := .query, Args := Array String, Rets := String }

abbrev probe : Endpoint :=
  { name := "probe", kind := .query, Args := String × Nat × Option Nat, Rets := ProbeResult }

abbrev add : Endpoint :=
  { name := "add", kind := .update, Args := String, Rets := Nat }

/-- `add` as a query, whose changes the IC discards. c/canister.c serves it with `add`'s code, so
it is `add` with another name and kind (`{ add with … }` copies `add` but for those fields). -/
abbrev addQuery : Endpoint :=
  { add with name := "add_query", kind := .query }

abbrev addThenExit : Endpoint :=
  { name := "add_then_exit", kind := .update, Args := String, Rets := Unit }

abbrev addThenThrow : Endpoint :=
  { name := "add_then_throw", kind := .update, Args := String, Rets := Unit }

/-- `notes` ignores its argument, but takes one, so that each call can differ from the previous
ones: the replica caches the replies of queries by their arguments. -/
abbrev notes : Endpoint :=
  { name := "notes", kind := .query, Args := String, Rets := Array String }

/-! The methods that call other canisters (see Ic.lean). They are updates: a query cannot call. -/

/-- 32 random bytes from the management canister's `raw_rand`. -/
abbrev random : Endpoint :=
  { name := "random", kind := .update, Args := Unit, Rets := ByteArray }

/-- Calls `greet` of the given canister, this one or another, and replies with its greeting. -/
abbrev greetVia : Endpoint :=
  { name := "greet_via", kind := .update, Args := Candid.Principal × String, Rets := String }

/-- Two calls to this canister's `add`, one after the other: the numbers of notes they reply. -/
abbrev addTwice : Endpoint :=
  { name := "add_twice", kind := .update, Args := String, Rets := Nat × Nat }

/-- Two calls to this canister's `add` at the same time, with each of the arguments. -/
abbrev addBoth : Endpoint :=
  { name := "add_both", kind := .update, Args := String × String, Rets := Nat × Nat }

/-- Calls the method of the canister with the argument, a Candid message, and replies with the
reply, as it is, or with the error. -/
abbrev callRaw : Endpoint :=
  { name := "call_raw", kind := .update, Args := Candid.Principal × String × ByteArray,
    Rets := Except String ByteArray }

/-- Calls this canister's `add`, and when the reply comes, adds another note and exits, which
traps: the IC discards what the callback changed, and runs the cleanup callback. -/
abbrev callThenExit : Endpoint :=
  { name := "call_then_exit", kind := .update, Args := String, Rets := Unit }

/-- Calls this canister's `add`, and when the reply comes, throws, which rejects the message from
the callback. -/
abbrev callThenThrow : Endpoint :=
  { name := "call_then_throw", kind := .update, Args := String, Rets := Unit }

/-- Calls this canister's `add` one-way, without waiting for the reply, and replies at once. -/
abbrev onewayAdd : Endpoint :=
  { name := "oneway_add", kind := .update, Args := String, Rets := Unit }

/-- A query that makes a call, which the System API does not allow: it traps. -/
abbrev callInQuery : Endpoint :=
  { name := "call_in_query", kind := .query, Args := String, Rets := String }

/-- All of the methods. -/
def endpoints : Array Endpoint :=
  #[greet, hello, probe, add, addQuery, addThenExit, addThenThrow, notes, random, greetVia,
    addTwice, addBoth, callRaw, callThenExit, callThenThrow, onewayAdd, callInQuery]

/-- A method's Candid type, a `func` type that is `query` for a query. `have := e.args` puts the
entry's instances in scope, where Lean finds them for `Candid.method`. -/
def Endpoint.method (e : Endpoint) : Candid.Method :=
  have := e.args
  have := e.rets
  Candid.method e.name e.Args e.Rets (mode := if e.kind == .query then some .query else none)

/-- The canister's Candid interface, the text of canister.did. -/
def toDid : String :=
  Candid.Interface.toDid { service := some (.serviceOf (endpoints.map (·.method))) }

/-- The names of the functions that canister.wasm must export for the IC: `canister_init`,
`canister_pre_upgrade`, `canister_post_upgrade`, and `canister_query <name>` or
`canister_update <name>` per method. c/canister.c defines them, by hand. -/
def exports : Array String :=
  #["canister_init", "canister_pre_upgrade", "canister_post_upgrade"] ++ endpoints.map fun e =>
    s!"canister_{if e.kind == .query then "query" else "update"} {e.name}"

end Interface
