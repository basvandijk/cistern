# Candid for Lean

A library for [Candid](https://github.com/dfinity/candid), the interface description language
and binary format of the Internet Computer, in Lean 4, for canisters written in Lean. It has the
types and values of Candid, the binary format in both directions, the subtype relation, the
text format of `.did` files, and type classes that map Lean types to Candid types, with
`deriving CandidType` for structures and inductive types.

It follows version 0.1.8 of the [specification][spec], and, where the specification leaves
room, the Rust crate `candid` 0.10.38, both at commit 10423fae of dfinity/candid. It passes all
467 assertions of the specification's conformance suite. It needs only Lean's `Init`,
which is what a canister links (see [lean-wasm](../experiments/lean-wasm)), and runs on wasm32
as on 64-bit platforms; the tests check that it gives the same results on both.

## Using it

```lean
import Candid

-- A message of the arguments ("world", 3), of type (text, nat).
def message : Except Candid.Error ByteArray := Candid.encode ("world", 3)

-- The arguments back, as Lean values: the types say what to decode.
def args : Except Candid.Error (String × Nat) := do Candid.decode (← message)
```

`message` is `.ok` of the 15 bytes `44 49 44 4c 00 02 71 7d 05 77 6f 72 6c 64 03`: `DIDL`, a
type table without entries, two arguments of the types `text` (`71`) and `nat` (`7d`), and
their values, `"world"` as its length and its UTF-8, and `3`. `args` is `.ok ("world", 3)`.

`Candid.encode` and `Candid.decode` take a method's arguments or results: `()` for none, a
value for one, and a product for more, as above. Each type in them needs a `CandidType`
instance, which says what its Candid type is and how its values convert to and from Candid
values. These types have one: `Bool`, `Nat` (`nat`), `Int` (`int`), `UInt8` to `UInt64` (`nat8`
to `nat64`), `Int8` to `Int64`, `Float32`, `Float` (`float64`), `String` (`text`), `Option`
(`opt`), `Array` and `List` (`vec`), `ByteArray` (`blob`),
`Except ε α` (`variant { Ok : α; Err : ε }`), `Unit` (`null`), `Empty` (`empty`),
`Candid.Principal`, and `Reserved` (`reserved`). `deriving CandidType` writes one for a
structure, as a record, and for an inductive type, as a variant:

```lean
module

public import Candid
meta import Candid.Derive

public section

structure ProbeResult where
  result : Nat
  instructions : Array UInt64
  deriving CandidType   -- record { result : nat; instructions : vec nat64 }

inductive Shape where
  | circle (radius : Float)
  | rect (w h : Float)
  | point
  deriving CandidType   -- variant { rect : record { h : float64; w : float64 }; circle : float64; point }
```

The comments are the Candid types as `Ty.toDid` writes them, with the fields and cases in the
order of their ids, the `idlHash` of their names, which is how Candid sorts them. For a
canister, a file that derives must be a *module*, a file that starts with `module`, and import
the deriving handler with `meta import`: the handler runs while Lean compiles the file, and
imports Lean's own modules, which a canister cannot link; `meta import` keeps them out of the
code that runs (see [The module system](#the-module-system) below). A program that runs with
`lean --run`, such as the tests, can be a plain file that writes `import Candid.Derive`.
[Candid/Derive.lean](Candid/Derive.lean) has the rules for the types that it derives.

Below the typed layer, `Candid.Ty` and `Candid.Value` are Candid's types and values as Lean
values, `Candid.encodeValues` and `Candid.decodeValues` the binary format at given types,
`Candid.decodeAny` a message at its own types, `Candid.isSubtype` the subtype relation, and
`Candid.parseInterface` and `Candid.Interface.toDid` the text of `.did` files. A decoder error
reads `Candid: <message> at byte <offset>`, in the Rust crate's words where it has them.
`Candid.decode` takes a `DecodeConfig`, with limits on what decoding a message may take: how
deeply values nest, how many values it decodes, skips or fills in for a missing field or
argument, how long the type table and the header are. The defaults reject the suite's attacks,
such as fourteen bytes that claim a billion values.

## The modules

In the order in which they import each other:

| Module | What |
| ------ | ---- |
| [Candid.Error](Candid/Error.lean) | `Candid.Error`, a message and a byte offset |
| [Candid.Hash](Candid/Hash.lean) | `idlHash`, the id of a field name |
| [Candid.Leb128](Candid/Leb128.lean) | LEB128 and SLEB128, the binary format's numbers |
| [Candid.Ty](Candid/Ty.lean) | `Label`, `FuncMode`, `Ty`, `Field`, `Method`, `TypeEnv`, `Interface`, and their `.did` text |
| [Candid.Principal](Candid/Principal.lean) | `Principal`, and its text form (CRC32, base32), which it reads in either case |
| [Candid.Value](Candid/Value.lean) | `Value`, and its text |
| [Candid.Subtype](Candid/Subtype.lean) | `isSubtype` |
| [Candid.Encode](Candid/Encode.lean) | `encodeValues`: the type table, then the values |
| [Candid.Decode](Candid/Decode.lean) | `decodeValues`, `decodeAny`, `DecodeConfig`: the header, coercion, skipping, limits |
| [Candid.Parse](Candid/Parse.lean) | `parseInterface`, `parseType`, `parseValues`, `annotate`, `annotateArgs`: the text format |
| [Candid.Class](Candid/Class.lean) | `CandidType`, `CandidArgs`, their instances, `Reserved`, `encode`, `decode`, `method` |
| [Candid](Candid.lean) | all of the above |
| [Candid.Derive](Candid/Derive.lean) | `deriving CandidType`; compile time only, not part of `Candid` |

The comments in each module say how it works. The programs [Candid/Tests/](Candid/Tests) and
[Candid/Conformance.lean](Candid/Conformance.lean) test them.

## Building and testing

The flake builds the library as:

| Package | What |
| ------- | ---- |
| `candid-c` | the C of the modules (`c/`), and their `.olean` files (`olean/`), for `LEAN_PATH`; Candid.Derive has an `.olean` file only |
| `candid-wasm` | `lib/libCandid.a`, the C compiled for wasm32-wasip1, to link with lean-wasm's `libInit.a` and `libleanrt.a` |

and checks it with:

| Check | What |
| ----- | ---- |
| `candid-tests` | the test programs in [Candid/Tests/](Candid/Tests), with `lean --run`: Encode (200 checks), Decode (592), Parse (9,960, of which 51 on the `.did` files of the Rust parser's tests), RoundTrip (2,783) and Derive (114) |
| `candid-tests-wasm` | the same programs but Derive.lean, and Parse without the Rust parser's files, compiled to wasm32 and run under wasmtime; the output must be that of a native run |
| `candid-conformance` | [Conformance.lean](Candid/Conformance.lean) on the conformance suite, `test/*.test.did` of dfinity/candid |

When a check fails, the end of its build log, which Nix shows, has the lines of the output that
are not passed checks, or how the wasm32 output differs from the native one. The 32-bit run
matters because the canister is 32-bit, where more numbers are bignums (see
[Numbers](#numbers)) and `USize` has 32 bits.

The conformance suite and the Rust parser's files come from the flake input `candid`,
dfinity/candid, at the commit that flake.lock pins. `nix flake update candid` moves it to the
latest one, after which the checks run on the new files. They also check how many there are:
Conformance.lean the assertions of each form in each file (its `expected`), and
Tests/Parse.lean the Rust parser's `.did` files, so a commit that adds or removes some needs
those numbers changed. Each assertion of the suite is a message, as a blob or in the text
format, at types, with what must come of it: that it decodes, that it does not, or that it
equals another. `candid-conformance`'s output has a line per assertion and the totals:

```
The conformance suite of dfinity/candid at 10423fa.
…
all: 467 assertions: blob : 21, blob !: 185, blob == text 247, blob != text 1, blob == blob 6, text only 7
the counts are the expected ones
467 passed, 0 failed, of 467
```

By hand, in the dev shell (`nix develop`), with the library's `.olean` files:

```sh
export LEAN_PATH=$(nix build .#candid-c --no-link --print-out-paths)/olean
lean --run candid/Candid/Tests/Decode.lean
suite=$(nix eval --raw .#checks.x86_64-linux.candid-conformance.suite)
lean --run candid/Candid/Conformance.lean $suite/*.test.did
```

Editors find the modules through [lakefile.toml](../lakefile.toml), whose `candid` library has
them all.

## The Lean idioms it uses

### Type classes and instances

`CandidType α` is a *type class*: an interface that a type implements with an `instance`, as a
Rust type implements a trait with an `impl`. It is to Candid what Lean's `ToJson` and `FromJson`
are to JSON. `[CandidType α]` among a definition's arguments is a constraint, like `T:
CandidType` in Rust, and Lean finds the instance where the definition is used. Instances can
depend on others: `Option α` has one if `α` has one. When several instances fit, Lean takes the
one of highest priority, and among those the one declared last. That is how `()` is no
arguments: the instance `CandidArgs Unit` says so, and the one that makes a value of any type
with a `CandidType` one argument, which would make `()` the argument `null`, has a low priority.
In a product, though, each part is one argument, a `()` too: `Nat × Unit` is `(nat, null)`. The
instance for any product `α × β` makes `α` one argument and `β` the rest, which for `Unit` would
be none; one for `α × Unit`, declared after it, takes precedence. In a definition for any
`α × β`, where `β` is a variable, only the first fits, so there a `()` is no more arguments.

`CandidType.ty Nat` is `Ty.nat`: the type is an explicit argument, as Lean cannot infer it from
the result.

### Deriving handlers

`deriving CandidType` runs a *deriving handler*, Lean code that writes the instance while Lean
compiles the type: it reads the declaration, writes the instance as syntax, as if it were source
text, and compiles that. [Candid/Derive.lean](Candid/Derive.lean) explains how. Lean's own
`deriving BEq`, `Repr` and `ToJson` work the same way.

### The module system

A file that starts with `module` is a *module*, in which a definition is private unless it is
`public` (or in a `public section`). An import says in which *phase* the imported module is
needed: `import Candid` for the code that runs, `meta import Candid.Derive` for the code that
runs while Lean compiles the file. A plain `import` is for what the module keeps private;
`public import` also for what it makes public, and passes the imported module on to the files
that import this one: a file that imports a module with `public import Candid` can call
`Candid.decode`. A module can import only modules, while a plain file can import both. Lean's
`Init` and this library are modules, so that a canister's files, which are modules for the
reason below, can import them.

For a module `X`, `lean -c` writes initializers into the C. `runtime_initialize_X` does what the
program needs when it runs, and calls the runtime initializers of `X`'s imports, except the
`meta` ones. `initialize_X` also runs the meta phase, what Lean needs when it compiles a file
that imports `X` (through `meta_initialize_X`, which initializes the `meta` imports), and calls
the all-phase initializers of all the imports. A program's `main`, and a canister's
`canister_init`, call the runtime one. As nothing calls the others, wasm-ld leaves them out, and
with them every reference to `Candid.Derive` and Lean: only they refer to the handler, which is
why the canister can derive. It also leaves out Init's meta phase, which is most of Init's code
(see lean-wasm's [Where the size comes from](../experiments/lean-wasm/README.md#where-the-size-comes-from)).

A definition's body is visible to other modules only if it is *exposed* (`@[expose]`), or an
`abbrev`, which Lean also unfolds wherever it compares types, as when it looks for an instance.

The test programs are not modules, but plain files that import modules: `lean --run` of a plain
file has the compiled code of all its imports, while that of a module could only run the code
that the module defines itself.

### `Except` and `EStateM`

Encoding, decoding and parsing return `Except Candid.Error α`, Lean's counterpart of Rust's
`Result`, with the error type first. In a `do` block, `(← x)` takes the value out of `x`, or ends
the block with its error, like `?` in Rust: in `do Candid.decode (← message)` above, `args` is
the error of `message` if encoding failed. `IO.ofExcept` turns an `Except` into an `IO` action
that throws the error.

The encoder, the decoder, the subtype check and the parser are computations in `EStateM`, a
monad of state and errors from `Init`: a function from a state to a result, which is a value and
a new state, or an error. `try x catch e => h` runs `h` in the state in which `x` failed, except
for the part of the state that the monad's `Backtrackable` instance gives back. The decoder's
gives back the position, so that a value that does not fit an `opt` type can be skipped, but not
the fuel, which the failed attempt has spent.

### Nested inductive types

`Ty` and `Value` are *nested* inductive types: their constructors hold `Array`s and `Option`s of
themselves. Lean derives `BEq` and `Inhabited` for both, and `Repr` and `Hashable` for `Ty`;
`Value`'s `Repr` is written by hand, as a `ByteArray`, which a `Value` can hold, has none. Lean
cannot derive `DecidableEq` for nested inductive types, so values of these are compared with
`==`, which returns a `Bool`, rather than with `=`, a proposition, which `if` can decide only
with a `DecidableEq` instance. `Ty`, `Field` and `Method` are *mutual*, defined together, as a
record's fields hold types.

### Recursion

Functions over types and values are recursive, and Lean accepts a recursive definition only if
it can see that the recursion ends. It can when each call is on a smaller number: the decoder
counts down the levels of nesting that `DecodeConfig.maxDepth` allows, and `TypeEnv.resolve`
the references that it may still follow. `termination_by` tells Lean what gets smaller where it
does not see that by itself, as in `Leb128.groupsValue`. Most of the others, in the encoder,
the printers, the subtype check and the parser, are `partial`: Lean compiles them without a
proof that they end, which would take more than the function, following the recursion through
the `Array`s in types and values, or, in the parser, through the tokens that each call reads. In
the decoder, which reads what anyone may send, the depth limit and the fuel, which each value
uses up, bound the stack and the work.

### Numbers

`Nat` and `Int` have arbitrary precision, as `nat` and `int` do. Small ones are stored unboxed,
in the pointer itself, without an allocation: a `Nat` below 2^63 on a 64-bit platform and below
2^31 on a 32-bit one, an `Int` from -2^31 to 2^31 - 1 on a 64-bit platform and from -2^30 to
2^30 - 1 on a 32-bit one. Others are bignums. `UInt8` to `UInt64` and `Int8` to `Int64` are
fixed-width and wrap around. LEB128 reads numbers of up to nine bytes, and writes those of up to
64 bits, with `UInt64` and `Int64` arithmetic, and splits longer ones in halves, so that a large
number in a message makes neither reading nor writing it quadratic.

## Design notes, and the differences from the Rust crate

- **One class, through `Value`.** `CandidType` converts to and from `Candid.Value`, and all
  coercion is in the decoder, where the conformance suite tests it; the Rust crate deserializes
  into Rust types directly, through serde. The cost is a `Value` per node, small next to what a
  message costs a canister in instructions.
- **The decoder** follows the specification's coercion rules, and the Rust crate where they are
  silent, so that the conformance suite passes: header limits as in Rust, the Rust crate's error
  messages where it has them, no `replace_empty` rewrite of records that contain themselves (the
  depth limit rejects their values instead), and counts, lengths and indices of at most 10
  bytes, as the Rust crate reads them as 64-bit numbers. Its metering is coarser: every value
  decoded, skipped or filled in for a missing field or argument, and every step of a subtype
  check, costs one unit of fuel (by default, a message has 16 units per byte, plus 10,000), where
  the Rust crate charges by size, and fifty times as much for skipped values. A unit takes from
  about 800 to 10,000 instructions on wasm32, so near the IC's limit of 2 MB per message, a
  message of values that take no bytes, such as a long `vec null`, can make decoding reach a
  query's or an update's instruction limit before the fuel ends: the canister then traps, where
  it should reject. A smaller `fuel` in `DecodeConfig` avoids that, for messages that need less.
- **Subtyping** is checked for `func` and `service` references, as the specification says; the
  results are kept for the rest of the message.
- **Generated `.did` files** inline every type: `deriving` makes no named definitions, so it does
  not support recursive types yet.
- **NaN.** Lean's runtime makes every NaN the canonical one when it converts bits to floats and
  back, so the encoder writes every NaN as `f64::NAN` writes it.

## Not yet

- Recursive and mutually recursive types in `deriving CandidType`.
- Calls with `func` and `service` references, and decoding the install argument in a canister.
- Opaque references (the flag byte 0), and values of future types beyond skipping them.
- Metering as fine as the Rust crate's, with a default that keeps decoding within a message's
  instruction limit.
- `import` in `.did` files.

DFINITY plans a Lean 4 reference model of Candid in dfinity/candid's `lean/` directory
(REWRITE.md and lean/README.md there: "executable first, proved second", `Ty`, `Value`,
subtyping, coercion and the wire format as plain Lean functions, a conformance binary, no
mathlib). This library has that shape, and could move there, or be checked against it.

## Sources

- [The Candid specification][spec], version 0.1.8, and its
  [conformance suite](https://github.com/dfinity/candid/tree/master/test).
- The Rust crates `candid` 0.10.38 (the decoder `de.rs` and `binary_parser.rs`, the encoder
  `ser.rs`, subtyping `types/subtype.rs`), `candid_derive` and `candid_parser` (the lexer
  `token.rs`, the grammar `grammar.lalrpop`, the conformance runner `test.rs`), at commit
  10423fae of [dfinity/candid](https://github.com/dfinity/candid).
- [The Lean reference manual](https://lean-lang.org/doc/reference/latest/), on the module system
  ("Source Files and Modules") and deriving handlers.

[spec]: https://github.com/dfinity/candid/blob/master/spec/Candid.md
