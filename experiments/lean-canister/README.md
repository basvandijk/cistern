# Experiment: a Lean canister

**Question.** The [lean-wasm](../lean-wasm) experiment compiled Lean to WebAssembly, with WASI as
its system interface. What does it take to run that code as an Internet Computer (IC) canister,
and how many instructions does it use?

**Answer so far.** It runs, well within the IC's limits, except where the Lean code is quadratic
or recurses deeply. [Canister.lean](Canister.lean), which imports
lean-wasm's [Hello.lean](../lean-wasm/Hello.lean), compiles to a module that imports nothing but the
IC's System API (`ic0`). A small C file implements the 12 WASI functions that the code needs on
top of `ic0`. In PocketIC, a local IC replica, the module installs, upgrades, and answers queries
and updates. Its methods speak Candid, through this repository's [Candid library](../../candid),
at the types of a [canister.did](canister.did) that is generated from the Lean types of their
arguments and results. Its `hello` query replies exactly what `lean --run Hello.lean` prints.
What its updates store in an `IO.Ref` stays from one message to the next, unless the update
traps; a query's changes are discarded, and an upgrade starts afresh. Its updates call other
canisters, this one, another, and the management canister's `raw_rand`, with Lean's
`IO.Promise` and `Std.Async`, on a task manager that lean-wasm gave the runtime without
threads: the response comes in a later message, in which the handler goes on, and replies. With
the IC's production limits:

- Installing takes 5.6 billion instructions of the 300 billion that an install may use, nearly
  all of them for compiling the module. Lean's initialization in `canister_init` takes 4.3 million.
- A query takes at least 0.26 million instructions of the 5 billion that it may use. Memory counts
  too: the IC charges 80,000 instructions for each 64 KiB page of memory that a message touches.
- Candid doubled the instructions of `greet`: it takes 0.35 million, where it took 0.17 million
  with text arguments and replies. Part of that goes to the closed terms of the Candid code,
  constants that are computed when first used, 23 in `greet`, which each `greet` computes anew,
  as the IC discards what a query changes.
- An update that adds a note to the `IO.Ref` takes 0.53 million instructions of the 40 billion
  that it may use, 0.24 million more than the same code as a query. That is the charge for the
  3 pages that it writes: an update pays as much again for the first write to a page. The first
  such update takes 0.58 million, as it also computes closed terms, which then stay.
- A call to another canister is at least two messages: `greet_via`, which calls `greet`, takes
  0.64 million instructions for the message that makes the call and 0.55 million for the
  callback that replies, and the callee's `greet` 0.30 million in between when it is this
  canister. `random`, which calls `raw_rand`, takes 0.59 + 0.59 million. Calls added 5% to the
  module and 28% to `canister_init`.
- The 5 MiB Wasm stack allows 16,374 to 109,171 levels of recursion for lean-wasm's probes. That is
  nearly as much as wasmtime allows with the same stack and Cranelift's optimizations off, and up
  to 29% more than with its default optimizations, which lean-wasm's estimates used.
- On non-ASCII text, `String.toUpper` takes about 4n² instructions for n characters, as Lean's
  `String.map` is quadratic on such text. A query that builds a string of 34,957 such characters
  and upper-cases it exceeds the limit of a query. On ASCII text `toUpper` takes 177 instructions
  per character.

The measurements come from the report of `lean-canister-report`, built on x86_64-linux, the
depths in wasmtime included. The exceptions are the modules' imports and exports, which
wasm-objdump lists, the 12 WASI functions that the link keeps, where it places the data and how
much code the Candid library has, which its map lists (`share/canister.map`), what is quoted from
lean-wasm, and the figures from earlier versions, from their reports: from before the methods
could call other canisters, from before they spoke Candid, and from before Canister.lean and its
imports were module files. The IC's costs and limits come from its source (see [Sources](#sources)). Every step is a Nix
derivation that builds in the sandbox. PocketIC and wasmtime are deterministic, so
`nix build --rebuild` reproduces the report bit for bit, as it does the modules.

## Running it

```sh
nix build .#lean-canister-report && cat result/report.txt   # the measurements, see below
nix flake check                                             # also builds the report
```

Calls to other canisters are in the report too: see [Calls](#calls) for how they work, and
[Calls to other canisters](#calls-to-other-canisters) for what they cost.

By hand, in the dev shell, which has `pocket-ic`, `wasmtime`, `lean`, and `python3` with
pocketic-py:

```sh
nix develop
c=$(nix build .#lean-canister-c --no-link --print-out-paths)
wasm=$(nix build .#lean-canister-wasm --no-link --print-out-paths)/bin
did=$(nix build .#lean-canister-did --no-link --print-out-paths)
lean --run experiments/lean-wasm/Hello.lean > hello.txt
lean --run experiments/lean-wasm/Hello.lean a b > hello-a-b.txt
LEAN_PATH=$c/olean python3 experiments/lean-canister/measure.py --did $did/canister.did \
  --hello hello.txt --hello-a-b hello-a-b.txt --run-probe $wasm/run-probe.wasm \
  --native "lean --run experiments/lean-canister/RunProbe.lean" $wasm/canister.wasm
```

Each step is a flake package:

| Attribute              | Output                                                                     | Built by                                                   |
| ---------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `lean-canister-c`      | `Hello.c`, `Ic0.c`, `Probes.c`, `Interface.c`, `Ic.c`, `Canister.c` and `RunProbe.c`; `olean/`, the modules for `lean --run` | [nix/lean-c.nix](nix/lean-c.nix) |
| `lean-canister-wasm`   | `bin/canister.wasm`; `bin/canister-opt.wasm`, after `wasm-opt -O`; `bin/run-probe.wasm`; `share/canister.map`, the link map | [nix/wasm.nix](nix/wasm.nix) |
| `lean-canister-did`    | `canister.did`, the canister's Candid interface; `exports.txt`, the functions that canister.wasm must export | [nix/did.nix](nix/did.nix), [GenDid.lean](GenDid.lean) |
| `lean-canister-report` | `report.txt`; `measurements.json`, everything that was measured            | [nix/measure.nix](nix/measure.nix), [measure.py](measure.py) |

`lean-canister-c` and `lean-canister-did` need the Candid library's `.olean` files, its package
`candid-c`, and `lean-canister-wasm` its `libCandid.a`, `candid-wasm` (see
[candid/README.md](../../candid/README.md#building-and-testing)), and lean-wasm's `libStd.a`,
`lean-wasm-std`, the module `Std.Async.Basic` of Lean's `Std` library, for the calls.

The check `lean-canister-runs` is the report. It fails to build if a module does not install or
upgrade, if `greet` or `hello` replies wrongly, if `greet` does not reject the arguments that it
does not take with the decoder's messages, if a probe's result is wrong, if the notes that the
updates keep are not as the IC's rules predict, if `add ("b")` as an update does not take a
whole number of page charges more than as a query (see
[State across updates](#state-across-updates)), or if a call to another canister does not reply,
reject, log or leave the notes as it should (see
[Calls to other canisters](#calls-to-other-canisters)). measure.py computes the
results, all but `repr`'s, which it takes from RunProbe.lean, run natively. The report and the
check exist on
x86_64-linux and aarch64-darwin, the systems for which ic-nix has PocketIC (see
[nix/pocket-ic.nix](../../nix/pocket-ic.nix)). The check `lean-canister-interface` fails to build
if the committed [canister.did](canister.did) is not the one that is generated from
Interface.lean, or if the exports of canister.wasm whose names start with `canister_`, the IC's
entry points, are not exactly those that Interface.lean gives: `canister_init`,
`canister_post_upgrade`, and one for each method. It needs no PocketIC, so it exists on every
system.

## How it works

```
Hello, Ic0, Probes, Interface, Ic, Canister.lean ──lean -c──▶ *.c ──┐
c/*.c: WASI on ic0, the Lean bindings, entry points, callbacks ─────┼─clang (wasm32)──▶ canister.wasm
Candid (libCandid.a), Std.Async.Basic (libStd.a), Init, the runtime ┘

Probes.lean, RunProbe.lean, the same way, but a WASI program ──▶ run-probe.wasm

Interface.lean ──GenDid.lean──▶ canister.did, checked against the committed one

canister.wasm in PocketIC ──────────┐
run-probe.wasm under wasmtime ──────┼──measure.py, with canister.did──▶ report
RunProbe.lean natively (lean --run) ┘
```

- [Canister.lean](Canister.lean) is the canister's Lean code, with five query and three update
  methods. `greet : (text) -> (text)` replies `Hello, <argument>!`.
  `hello : (vec text) -> (text)` runs Hello.lean's `main`, with the argument as its command-line
  arguments, and replies with what it prints, which `IO.FS.withIsolatedStreams` captures.
  `probe : (text, nat, opt nat) -> (record { result : nat; instructions : vec nat64 })` runs the
  probe of that name, of [Findings](#findings), on an input of the size that the `nat` gives, as
  many times as the `opt nat` says, once if it is `null`, and replies with the probe's result and
  the instructions of each run. The others keep notes, the canister's state, in an
  `IO.Ref (Array String)` that an `initialize` declaration creates: the update
  `add : (text) -> (nat)` adds its argument and replies with how many notes there are, the query
  `add_query` does the same, `add_then_exit` and `add_then_throw`, `(text) -> ()`, add and then
  exit or throw, and the query `notes : (text) -> (vec text)` replies with the notes. `serve`
  runs each method's handler: it decodes the message's argument with `Candid.decode` at the
  method's argument types, calls the handler with the Lean values, encodes what the handler
  returns with `Candid.encode` at the method's result types, and replies; if decoding fails or
  the handler throws, it rejects the message with the error (see
  [Candid in the canister](#candid-in-the-canister)). So the handlers have the types of the
  methods: `greet`'s is a `String → IO String`, `probe`'s takes a `String × Nat × Option Nat`.
  An update's handler is an `Ic.Async` action, in which it can call other canisters, as
  `random`, `greet_via`, `add_twice`, `add_both`, `call_raw`, `call_then_exit`,
  `call_then_throw` and `oneway_add` do, and the query `call_in_query` tries to (see
  [Calls](#calls)).
- `add` adds in place: `modifyGet` takes the array out of the reference while `push` runs, so
  that nothing else refers to it. That `push` does not copy the array relies on this runtime
  being built without threads. Lean takes a reference that `initialize` creates for one that
  threads may share, and marks what it stores in it as shared ([io.cpp][lean-ref]), which would
  make `push` copy the array; without `LEAN_MULTI_THREAD`, marking does nothing
  ([object.cpp][lean-mark-mt]). A full array still moves to one with room for (c + 1) × 2 notes
  ([object.cpp][lean-push]). This is from the code, and not measured.
- [Interface.lean](Interface.lean) has the methods as a table of `Endpoint` values: a method's name,
  whether it is a query or an update, and the Lean types of its arguments and results, such as
  `String × Nat × Option Nat` for `probe`'s `(text, nat, opt nat)`. Their `CandidType` and
  `CandidArgs` instances give the Candid types; `ProbeResult`, `probe`'s reply, derives its instance
  (`deriving CandidType`), with the library's deriving handler, which Interface.lean imports with
  `meta import Candid.Derive`, for the meta phase only (see c/canister.c below). The entries are
  `abbrev`s, which Lean unfolds where Canister.lean looks for instances, so that there `greet.Args`
  is `String`, with `String`'s instances, and `greet.kind` is `.query`, which decides the handler's
  monad (see [Calls](#calls)). [GenDid.lean](GenDid.lean), a plain program, which
  nix/did.nix runs with `lean --run`, prints from the table the canister's Candid interface,
  [canister.did](canister.did), which is committed, and the names of the functions that
  canister.wasm must export, which c/canister.c defines by hand. The check `lean-canister-interface`
  ([nix/did.nix](nix/did.nix)) compares the committed canister.did with the printed one, and
  canister.wasm's exports, as wasm-objdump lists them, with the printed names.
- [Ic.lean](Ic.lean) is what a handler calls other canisters with: `Ic.call`, `Ic.oneway`, the
  errors, and `Ic.Async`, the monad of an update's handler, which is `Std.Async`'s `EAsync` with
  those errors (see [Calls](#calls)).
- [Probes.lean](Probes.lean) has the probes. [RunProbe.lean](RunProbe.lean) runs them as a
  program, for comparison: compiled like lean-wasm's `hello.wasm` and run under wasmtime, and
  natively.
- [Ic0.lean](Ic0.lean) declares the System API functions that Canister.lean and Ic.lean use as
  `@[extern]` functions, which [c/ic0.c](c/ic0.c) implements. Where the System API takes an
  address and a size, they take a `ByteArray` or a `String`, and a 128-bit value is a pair of
  `UInt64`. `Ic0.call` makes a call to another canister with the `ic0.call_*` functions; c/ic0.c
  also has the callbacks that the IC runs with the response (see [Calls](#calls)).
- [c/canister.c](c/canister.c) has the entry points that the module exports. `canister_init`, and
  `canister_post_upgrade`, as an upgrade starts with new memory, do what a Lean program does
  before its `main`. They run the C++ constructors (`__wasm_call_ctors`), as crt1's `_start`
  would, and then, as Lean's generated `main` does, `runtime_initialize_Canister(1)`, which calls
  `lean_initialize_runtime_module()`, the runtime initializers of the imported modules and
  Canister.lean's own, which creates the notes. Then they call
  `lean_io_mark_end_initialization()`, and `lean_init_task_manager_using(1)`, which creates the
  task manager that the calls need (see [Calls](#calls)); `canister_pre_upgrade` refuses an
  upgrade while calls are outstanding. Canister.lean and its imports are module files (`module`),
  as Init's and the Candid library's are, and for a module Lean generates
  `runtime_initialize_<Module>`, which initializes what the program needs when it runs, besides
  `initialize_<Module>`, which also initializes, through `meta_initialize_<Module>`, what Lean
  needs when it compiles a file that imports the module, the meta phase, such as the syntax and
  elaborators that the module defines. Only the first is called, so wasm-ld leaves out the others,
  and with them the code that only they reach (see [Installation](#installation)), among it every
  reference to the Candid library's deriving handler, which Interface.lean imports for its meta
  phase. The link does not have the handler: it imports Lean's own modules, which a canister does
  not link, so `candid-c` compiles Candid.Derive to an `.olean` file only, without C. Each
  `canister_query <name>` and `canister_update <name>` calls a function that Canister.lean exports
  with `@[export]`; `canister_query add_query` calls the same one as `canister_update add`, under a
  name of its own, as the IC refuses a module that exports a name as a query and as an update
  ([validation.rs][duplicate-export]). Those functions catch Lean's errors and reject the message
  with them, so a method replies or rejects, unless it traps: `add_then_exit` does, as it exits,
  and so does a probe that runs out of stack or instructions. A method that calls another
  canister returns after making the call, and replies, or rejects, from the callback that brings
  the response, in a later message.
- [c/wasi.c](c/wasi.c) implements WASI on top of the System API, see below.
- [nix/wasm.nix](nix/wasm.nix) compiles and links as lean-wasm does, with the Candid library's
  `libCandid.a` (`candid-wasm`) besides Init's and the runtime's libraries, and with three more
  flags. `-nostartfiles` leaves out crt1, whose `_start` (or `_initialize`) the IC would not call;
  `canister_init` runs the constructors instead, and as it calls `__wasm_call_ctors`, wasm-ld does
  not make every export run them too ([Writer.cpp][lld-writer]). `-Wl,--no-entry` keeps just the
  exports, and `-Wl,--fatal-warnings` is explained below. After the link, the build fails if the
  module imports anything that is not from `ic0`, or if the link map lists an initializer of the
  meta phase of Canister, Interface, Ic, Candid.Derive or Std.Async.Basic
  (`meta_initialize_<Module>` or `initialize_<Module>`), so that the deriving handler, which
  imports Lean, is not linked. It also links `run-probe.wasm`, without the Candid library.
- [measure.py](measure.py) creates the canisters, installs the modules and calls them with
  [pocketic-py][pocketic-py], PocketIC's Python library, whose Candid comes from [ic-py][ic-py]
  ([nix/pocket-ic-py.nix](../../nix/pocket-ic-py.nix)). It reads the methods' types from
  canister.did (`--did`) with ic-py's parser of `.did` files ([DIDEmitter.py][ic-py-parser]),
  encodes the arguments and decodes the replies with ic-py at those types, and checks that a method
  is a query in canister.did if and only if it calls it as one. It also sends arguments that are not
  of a method's types, as bytes that ic-py encodes at other types or that measure.py writes itself:
  to `greet` bytes that are not Candid, a `nat`, a `text` that is not UTF-8 and no argument, which
  the canister must reject with the decoder's messages, and an extra argument, which it must ignore;
  and to `probe` no `opt nat`, which the decoder must make `null` (see [Queries](#queries)). It
  starts the PocketIC server itself, with its output, which has the canisters' logs and the
  replica's, in files; pocketic-py finds that server by its port file. pocketic-py's `install_code`
  only installs, so measure.py makes its `install_code` calls, the install and two upgrades, itself:
  it encodes the argument with ic-py, and sends it with pocketic-py's
  `update_call_with_effective_principal`. Its `arg`, the canister's own argument, is the empty
  Candid sequence, `ic.encode([])`, which `canister_init` does not decode. It calls the canister's
  updates with pocketic-py's `update_call`, which submits the message and then executes rounds until
  it is done, at most 100: for a method that calls another canister, until its callbacks have run
  ([pocket_ic.py][pocketic-update-call]). After both canisters are installed, it tries the
  methods that call (see [Calls to other canisters](#calls-to-other-canisters)): from each
  canister's log it takes the lines of each message of a call, the entry point's, the callee's
  methods' if the callee is the canister itself, and the callbacks'. It also runs
  `run-probe.wasm` under wasmtime, and RunProbe.lean natively.

### WASI on ic0

wasi-libc calls each WASI function through one that it declares as a Wasm import but does not
define, such as `__imported_wasi_snapshot_preview1_fd_write` ([__wasilibc_real.c][wasilibc]).
wasm-ld makes such a function an import only if no object file defines it. So c/wasi.c defines
them, and the module imports no WASI. Two properties of wasm-ld make the build check this:

- It does not report a WASI function that c/wasi.c lacks: the function becomes an import, as
  declared ([Relocations.cpp][lld-relocations]). The IC then refuses the module at install with
  "Module imports function 'fd_write' from 'wasi_snapshot_preview1' that is not exported by the
  runtime", so nix/wasm.nix checks the imports instead.
- For a definition whose Wasm type differs from the declaration, it only warns, and calls a stub
  that traps ([SymbolTable.cpp][lld-symboltable]). Hence `--fatal-warnings`.

The link needs 12 WASI functions, two fewer than lean-wasm's `hello.wasm`: without crt1, nothing
reads the command line.

| WASI function                           | In the canister                                                                   |
| --------------------------------------- | --------------------------------------------------------------------------------- |
| `fd_write`                              | stdout and stderr: each line to `ic0.debug_print`, the canister's log, as one record, or, if it is longer, as records of at most 4 KiB, cut between UTF-8 characters |
| `fd_fdstat_get`                         | stdin, stdout and stderr are character devices that cannot seek, which makes `isatty()` true, so that stdout is line buffered |
| `clock_time_get`                        | `ic0.time`, the time of the block, which stays the same during a message          |
| `random_get`                            | a fixed sequence of bytes, the same in every canister (splitmix64 from 0)         |
| `proc_exit`                             | `ic0.trap`, with `exit(<code>)` and the last line of stderr that is not empty; `add_then_exit` traps so, with nothing on stderr |
| `environ_get`, `environ_sizes_get`      | an empty environment                                                              |
| `fd_read`                               | stdin is at its end                                                               |
| `fd_seek`, `fd_close`                   | stdin, stdout and stderr cannot seek, and closing them does nothing               |
| `fd_prestat_get`, `fd_prestat_dir_name` | there are no preopened directories, so that opening a file fails with ENOENT      |

c/wasi.c also defines `abort()`. wasi-libc's executes `unreachable`; this one flushes stdout and
calls `ic0.trap` with the last line of stderr, for example the uncaught C++ exception that
lean-wasm's `__cxa_throw` prints before it aborts. The entry points flush stdout and the rest of
a line at their end. A trap of the IC's own, such as a stack overflow, loses that rest.
`IO.getRandomBytes`, and `IO.rand` with it, is not random. A canister gets randomness from the
management canister's `raw_rand`, which takes a call to another canister.

### Candid in the canister

A Candid message is the magic `DIDL`, a table of the compound types that its values need, the
types of its values, and the values: `greet`'s argument `("world")` is the 13 bytes
`44 49 44 4c 00 01 71 05 77 6f 72 6c 64`, `DIDL`, an empty table, one value of type `text`
(`71`), and `"world"`, as its length and its UTF-8 ([specification][candid-spec]). The receiver
decodes the values at the types that it expects, which may differ from the message's where
Candid's subtyping allows it: an extra value is ignored, and a missing one of an `opt` type is
`null`.

`serve` in Canister.lean uses two functions of the Candid library: `Candid.decode`, which decodes
the message's argument (`Ic0.msgArgData`) into Lean values of the method's argument types, and
`Candid.encode`, which encodes the handler's result at the method's result types. They find the
Candid types in the `CandidArgs` instances that the method's entry in Interface.lean holds. Both
return an `Except`, which `IO.ofExcept` turns into an `IO` action that throws the error; `serve`
catches it, as it catches the handler's errors, and rejects the message with it. So an argument
that does not decode is rejected before the handler runs, with the decoder's error, which reads
`Candid: <message> at byte <offset>`, such as `Candid: wrong magic at byte 0` for an argument
that does not start with `DIDL`. The messages are in the Rust crate's words where it has them
([candid][candid-crate]), as the one for no argument is (see [Queries](#queries)).
[candid/README.md](../../candid/README.md) describes the library: its types and functions, the
decoder's limits, and how it is tested.

### Calls

A canister calls another with the System API: `ic0.call_new` names the callee, the method and
two callbacks, `call_data_append` adds the argument, `call_perform` sends the call, and the
response, the reply or a reject, comes in a later message, to the reply or the reject callback
([interface specification][spec-call]). A callback is a function in the module's function table,
given by its index, with an `env` value that the IC passes back; the original message is
answered from whichever message finishes the work, with `ic0.msg_reply` in the callback as well
as in the entry point, exactly once per call ([abstract behavior][abstract-callbacks]). If a
callback traps, the IC discards what it changed, runs the cleanup callback, if one was given, on
the memory as it was before, in a context in which it can neither reply nor call, and, once no
call is outstanding and nothing has replied, rejects the original message with `CANISTER_ERROR`
([abstract behavior][abstract-starvation]). Other messages run between a call and its callback:
the canister's state may have changed. ic_cdk, the Rust CDK, resumes a Rust future in the
callback, with a pointer to it as `env`, and on cleanup drops the futures without running them
([call.rs][cdk-call]).

Lean's idiom for a value that arrives later is a `Task`, and for one that something else
provides an `IO.Promise`, and Lean's `Std.Async` library chains what follows an `await` onto the
task, with `BaseIO.bindTask`, without blocking: its `EAsync` monad runs a computation up to its
first await of a task that has not finished, and the rest when the task finishes
([Std/Async/Basic.lean][std-async]; it imports only `Init`, and lean-wasm compiles it to
`libStd.a`). So a call is a promise, and the callback resolves it:

- [Ic.lean](Ic.lean): `Ic.Async α` is `EAsync Ic.Error α`, the monad of an update's handler;
  `IO` lifts into it. `Ic.call canister "greet" name : Ic.Async String` encodes the arguments at
  their Candid types, checks the canister's liquid cycles against `ic0.cost_call`, as ic_cdk does,
  creates a promise, makes the call with `Ic0.call`, awaits the promise, and decodes the reply at
  the expected type. A call is made when the action runs; `Std.Async.EAsync.concurrently` runs
  two before awaiting either. The errors, `Ic.Error`: a reject, with its code (1 to 6, as the
  specification numbers them) and message, `call_perform`'s refusal, too few cycles, a Candid
  error, and an `IO` error; `Ic.oneway` makes a call whose response is dropped, and
  `Ic.rawRand` calls the management canister's `raw_rand`. Calls wait for the response 300
  seconds by default (`ic0.call_with_best_effort_response`, which may end in `SYS_UNKNOWN`), as
  ic_cdk recommends for a callee one does not control; `Ic.Wait.unbounded` waits forever, which
  keeps the canister from stopping.
- `Ic.Handler e.kind` is the monad of the handler of the method `e`: `IO` for a query, in which
  `Ic.call` does not typecheck, as a query cannot call, and `Ic.Async` for an update. So the
  types of Canister.lean's handlers follow from Interface.lean, as before.
- Canister.lean's `serve` starts the handler as an `Ic.Async` action, which runs it up to its
  first pending await, and chains the reply, or the reject with the error, onto its task with
  `BaseIO.chainTask`: at once, in the same message, if the handler did not await, as the methods
  that do not call never do, and in the callback's message otherwise. The chain is kept alive by
  the runtime (`BaseIO.chainTask` is `keep_alive`), not by `serve`, which returns to the IC.
- [c/ic0.c](c/ic0.c): `cistern_ic0_call` assembles the call with the promise's address as `env`,
  and the table indices of two functions of its own as the callbacks, `on_response` for the
  reply and for a reject alike, which `ic0.msg_reject_code` tells apart, and `on_cleanup`. A
  function's address is its table index on wasm32 (clang emits the index, and wasm-ld fills the
  table, which the IC exports itself when it instruments the module;
  [instrumentation.rs][export-table]). `on_response` makes an `Ic0.Response` of the code and
  the reply or the reject message, with a function that Ic0.lean exports, and resolves the
  promise, which runs the handler's continuation, up to its reply or its next call, before
  `resolve` returns; then it releases the promise and logs the message's instructions, as the
  entry points do. `on_cleanup` discards the promise, with `IO.Promise.discard`, which the
  runtime patch adds: that resolves it with `none` and frees the continuation, and what it
  captured, without running it, as resolving or releasing the promise would, and the
  continuation can neither reply nor call there (ic_cdk drops its futures the same way). Then
  it logs. c/ic0.c counts the calls whose callback has not run, which `canister_pre_upgrade`
  checks.
- The runtime: `IO.Promise` and `Task.bind` on a task that has not finished need a task manager,
  which upstream's runtime without threads does not have, so lean-wasm's
  [runtime/task-manager.patch](../lean-wasm/runtime/task-manager.patch) gives it one that runs
  tasks on the one thread, from a queue, when they are made or when what they wait for is
  resolved; `IO.wait` on a task that nothing resolves traps (see lean-wasm's
  [Tasks and promises](../lean-wasm/README.md#tasks-and-promises)). `canister_init` creates it
  after the initializers, as Lean's `main` does.

What a handler that calls has to know:

- Nothing after an await runs in the message that made the call: other messages run in between.
  What a message changes stays when it returns, also when a later message of the handler throws or
  traps: `call_then_throw`'s note stays, and so does `call_then_exit`'s first note, while the one
  its callback adds is discarded with the trap. `IO.Ref`s are read anew after an await; a value
  that a continuation captured is a snapshot.
- Reply data that a message appended is discarded if it ends without `ic0.msg_reply`; `serve`
  appends and replies in one message.
- A trap in the callback leaves the original message without a reply: the IC rejects it, as
  `call_then_exit` shows, with the trap's message.
- `IO.wait`, `Task.get` and `EAsync.block` on a task that has not finished trap, with the
  message of the runtime's internal panic. A promise that nothing resolves leaves the message
  without a reply until the IC rejects it: the only way to suspend is to make a call.
- A task made in one message and awaited by another method's handler would run that handler's
  continuation in the first one's callback, and reply from it: a second reply, which traps. A
  response belongs to the call context that made the call.
- Upgrading while calls are outstanding delivers their responses to the new module, as calls to
  table indices with `env`s in the memory that the upgrade discarded, which would corrupt the
  canister; stopping the canister first, as `dfx deploy` does, waits for the responses
  ([abstract behavior][abstract-stopping]). `canister_pre_upgrade` traps while calls are
  outstanding, so that an upgrade without stopping fails instead.

### Measuring

- `ic0.performance_counter(0)` is the number of instructions that the current message has
  executed, as the IC counts them for its limits ([interface specification][spec]). It includes
  what the IC charges for the System API, for example 500 instructions for each `ic0.time`
  ([system_api_complexity.rs][complexity]), and for memory. The first access of a message to a
  64 KiB page costs 80,000 instructions, 5,000 for each of its 16 OS pages, and in an update or
  `canister_init` the first write to it as much again ([deterministic.rs][tracker],
  [system_api.rs][modification-tracking], [subnet_config.rs][subnet-config]), which
  [State across updates](#state-across-updates) agrees with.
  canbench, DFINITY's tool for benchmarking canisters, also counts this way, in PocketIC
  queries.
- `Ic0.countInstructions f a` reads the counter before and after it applies `f` to `a`. It is
  written in C because Lean's compiler moves pure code, and could have moved `f a` past the
  second read. For the same reason a probe gets its input as a value. Lean's compiler turned
  `fun n => let xs := List.range n; fun _ => ...` into one function of two arguments, which built
  the input in the measured part.
- Each entry point that returns ends by logging its instructions, as in `canister_query greet:
  342649 instructions, 23 ic0.time calls`; one that traps logs none. So does each callback, as in
  `reply callback: 123456 instructions, 0 ic0.time calls (call context 234567, outstanding calls
  0)`, where the call context is `ic0.performance_counter(1)`, the instructions of all of the
  call's messages so far. PocketIC prints the canister's log on its standard error, where
  measure.py reads it. The count cannot include the logging itself: for `canister_init`, the
  replica counts 13,730 instructions more. The replica logs what each `install_code` took, but
  not what an update took.
- The replica answers a query that it has answered before from a cache, without running it,
  unless the entry has expired, the canister's version has changed, or the query read the time or
  the cycle balance and that has changed ([query_cache.rs][query-cache]). An update that traps
  leaves the version as it was ([system_api.rs][trap-log]). So each query has an argument of its
  own, also `notes`, which ignores it.
- measure.py also finds the depths of the recursion probes in `run-probe.wasm` under wasmtime
  49.0.2, by bisection as in PocketIC, with the IC's 5 MiB stack (`-W max-wasm-stack=5242880`,
  [lib.rs][embedders-lib]): with Cranelift's default optimizations, and with
  `-O opt-level=0`, as the IC compiles them ([validation.rs][validation], which the
  configuration that runs canisters extends, [wasmtime_embedder.rs][execution-config]). The IC
  itself embeds wasmtime 48.0.1 ([Cargo.toml][ic-cargo]).
- On macOS, PocketIC's OS pages are 16 KiB, which would make a page cost 20,000 instructions
  instead of 80,000 ([rs/sys][sys]). The report differs there; it is untested.

## Findings

### It runs

| Module              |     Bytes | Gzipped |
| ------------------- | --------: | ------: |
| `canister.wasm`     | 1,545,038 | 260,650 |
| `canister-opt.wasm` | 1,093,691 | 207,023 |

With text arguments and replies, canister.wasm had 1,017,382 bytes (166,549 gzipped). Speaking
Candid made it 448,375 bytes larger, 44% (gzipped 48%), most of that the Candid library's code:
359,453 bytes in 402 functions (`share/canister.map`). Calling other canisters, with
Std.Async.Basic, Ic.lean, the nine methods and their C, makes it 79,281 bytes larger, 5%
(gzipped 13,711, 6%).

The modules import 22 functions, all from `ic0`: 9 for the methods, and 13 for the calls (see
[Calls](#calls)); the bindings that no method uses, such as `msg_caller`, are left out by the
link. They export `canister_init`, `canister_pre_upgrade`, `canister_post_upgrade`,
`canister_query greet`, `canister_query hello`, `canister_query probe`, `canister_update add`,
`canister_query add_query`, `canister_update add_then_exit`, `canister_update add_then_throw`,
`canister_query notes`, `canister_update random`, `canister_update greet_via`,
`canister_update add_twice`, `canister_update add_both`, `canister_update call_raw`,
`canister_update call_then_exit`, `canister_update call_then_throw`,
`canister_update oneway_add`, `canister_query call_in_query` and their memory. An ingress message
may have at most 2 MiB ([resource limits][limits]). The
`install_code` message with canister.wasm would fit, as the module is less than three quarters of
that size; gzipped, which the IC accepts ([interface specification][spec]), it is less than an
eighth, and measure.py installs both so. In PocketIC:

- `greet ("world")` replies `("Hello, world!")`, and its `IO.println` reaches the canister's log.
- `hello (vec {})` and `hello (vec { "a"; "b" })` reply, as a `text`, the six lines that
  `lean --run Hello.lean` prints, with `2^102` and `2^33 + 1` for the latter. Bignums work as
  natively.
- An argument that the decoder cannot decode at the method's types is rejected with the
  decoder's error, such as `Candid: wrong magic at byte 0` for one that is not Candid, and an
  unknown probe with the error that the handler throws, `there is no probe nosuch`. An extra
  argument is ignored, and a missing one of an `opt` type is `null` (see [Queries](#queries)).
- After an upgrade to the same module, which runs `canister_post_upgrade`, `greet` still works.
- The notes that an update adds stay, unless the update traps or an upgrade comes between, and
  the queries see them (see [State across updates](#state-across-updates)).
- The methods that call other canisters reply what the callee replied, in a later message, and
  the errors as they should: a reject by the callee, a method or a canister that does not exist,
  a callback that throws, and one that traps, after which the IC rejects the call and the
  cleanup callback runs (see [Calls to other canisters](#calls-to-other-canisters)).

### Installation

| Instructions                        | canister.wasm | canister-opt.wasm |
| ----------------------------------- | ------------: | ----------------: |
| `install_code`                      | 5,634,658,436 |     5,006,345,802 |
| `canister_init`                     |     4,308,706 |         4,070,198 |
| of which C++ constructors           |       253,842 |           252,854 |
| of which the Lean runtime           |        11,854 |            11,306 |
| of which the modules' initializers  |     3,954,191 |         3,717,586 |
| of which the task manager           |           685 |               555 |
| `install_code` of an upgrade        |    80,755,476 |        74,235,974 |

`install_code` is the replica's count for the whole message. `canister_init` is the counter at
the end of `canister_init`, and `canister_post_upgrade` takes as many instructions, which
measure.py checks. There are two upgrades, one before and one after the updates of
[State across updates](#state-across-updates), and they took the same.

- `canister_init` runs only the runtime phase of the initializers, as c/canister.c calls
  `runtime_initialize_Canister` (see [How it works](#how-it-works)). The meta phase, which
  computes what only the compiler uses, such as the syntax that Init defines, does not run, and
  wasm-ld leaves out its code and data. Before Canister.lean and its imports were module files,
  with text arguments and replies, c/canister.c called `initialize_Canister`, which runs both
  phases: then `canister_init` took 7,530,732 instructions, 7,018,419 of them in the modules'
  initializers, with 2,691 `ic0.time` calls, and canister.wasm had 2,080,316 bytes, whose install
  took 6,338,385,483 instructions. As module files, still with text, `canister_init` took
  2,239,940 instructions, 1,887,627 of them in the modules' initializers, with 192 `ic0.time`
  calls, and the install 3,496,678,603.
- With the Candid library, `canister_init` took 1,133,315 instructions more than with text, all
  of them in the modules' initializers (canister-opt.wasm: 1,074,261 more, 1,074,241 of them
  there and 20 in the Lean runtime), and made 249 `ic0.time` calls instead of 192. The runtime
  initializers of the library's modules and of Interface.lean compute their constants, and with
  them 57 more closed terms (see below). How the instructions divide among them was not measured.
  Of Interface.lean's constants, Canister.lean's code uses only `ProbeResult`'s instance. The
  others, the methods, the text of canister.did and the names of the exports, only GenDid.lean
  uses, but `runtime_initialize_Interface` computes them in the canister as well (`Interface.c`
  and `Canister.c` of `lean-canister-c`).
- With the calls, `canister_init` takes 935,451 instructions more, 28% (canister-opt.wasm:
  878,887), 933,249 of them in the modules' initializers, now also those of Std.Async.Basic and
  Ic.lean, and of an Interface.lean with 17 methods instead of 8, and 685 for creating the task
  manager; it makes 267 `ic0.time` calls instead of 249. Not divided further.
- Compiling takes most of the install. The IC charges 20 million instructions for it, plus 6,000
  for each instruction of the module after it has instrumented the module for counting
  ([embedders.rs][embedders], [instrumentation.rs][instrumentation]). For canister.wasm that is
  (5,634,658,436 - 4,322,436 - 20,000,000) / 6,000 = 935,056 instructions, where 4,322,436 is
  the replica's count of `canister_init`. For a module that the subnet has installed since its
  last checkpoint, the 6,000 drop to 60 ([execution_environment.rs][compiled]), but the 20
  million remain ([hypervisor.rs][hypervisor]). A successful `install_code` records its module
  ([execution_environment.rs][compiled-wasms-insert]), which the next one looks up
  ([execution_environment.rs][compiled-wasms]), and a checkpoint forgets them
  ([scheduler.rs][checkpoint]). So each upgrade took 329,186 for `canister_pre_upgrade` +
  4,322,930 for `canister_post_upgrade`, the replica's counts (the canister's own count of
  `canister_pre_upgrade` is 160,379: the replica charges it about twice that, for what was not
  measured), + 20,000,000 + 60 × 935,056 = 80,755,476. An install may use 300
  billion instructions ([subnet_config.rs][subnet-config]), so this one uses 2%.
- The IC charges the instructions of an `install_code` to the canister, and refuses the next one
  (`CanisterInstallCodeRateLimited`) until the rounds have paid them off, at 2 billion at the
  end of every round, the install's own round included ([install_code.rs][install-code],
  [subnet_config.rs][subnet-config]). The credit comes at the end of the round
  ([round_schedule.rs][round-end], [round_schedule.rs][round-schedule]) to the canisters in the
  subnet's schedule. `install_code` puts the canister there when it puts it back with its debit
  ([replicated_state.rs][subnet-schedule]), and it stays there as long as it has a debit, also in
  a round in which it has nothing to execute ([canister_state.rs][must-be-in-schedule],
  [round_schedule.rs][schedule-retain]). So the IC refused the first upgrade in the 2 rounds after
  the install, and accepted it in the 3rd, on both modules. In PocketIC, each try took a round,
  and so did the upgrade. It accepted the second upgrade at once: the first's 81 million
  instructions (canister-opt.wasm: 74 million) were paid off at the end of its own round.
- `canister_init` made 267 `ic0.time` calls, which cost at least 267 × 500 = 133,500
  instructions, 3% of it. They come from Lean's lazily initialized constants (closed terms). The
  first use of one takes a lock with `std::atomic<int>::wait` ([object.cpp][lean-once]), and
  libc++'s wait reads the clock before it first looks at the lock ([poll_with_backoff.h][libcxx]).
  That is `clock_time_get`, which c/wasi.c answers with `ic0.time`. A runtime without threads
  does not need the wait.

### Queries

| Instructions of the query                            | canister.wasm | canister-opt.wasm |
| ---------------------------------------------------- | ------------: | ----------------: |
| `greet ("world")`                                    |       348,840 |           342,645 |
| `greet ("extra", 1)`: an extra argument              |       355,437 |           348,832 |
| `hello (vec {})`                                     |       865,141 |           832,566 |
| `hello (vec { "a"; "b" })`                           |       927,018 |           890,896 |
| `probe ("noop", 0, null)`: no work, 286 measured     |       447,554 |           435,947 |
| `probe ("noop", 0)`: no third argument               |       436,701 |           425,718 |
| `greet` with the byte `0xff`: rejected, not Candid   |       259,794 |           258,740 |
| `greet (1)`: rejected, a `nat`, not a `text`         |       295,216 |           291,990 |
| `greet` with a `text` `0xff`: rejected, not UTF-8    |       284,828 |           282,185 |
| `greet ()`: rejected, no argument                    |       280,593 |           278,462 |
| `probe ("nosuch", 1, null)`: rejected, no such probe |       322,399 |           317,676 |

These are the counts that the entry point logs, so they leave out the logging (see
[Measuring](#measuring)). The calls are in Candid's text format. measure.py encodes the
arguments with ic-py at the types of canister.did, except those that are not of the method's
types, which it sends as bytes that ic-py encodes at other types or that it writes itself
(`DIDL 00 01 71 01 ff` for the `text` `0xff`). The canister rejects the four arguments that
`greet` does not take with the decoder's messages, which measure.py checks exactly:

- the byte `0xff`: `Candid: wrong magic at byte 0`,
- `(1)`: `Candid: nat cannot be deserialized to text at byte 7`,
- the `text` `0xff`: `Candid: invalid utf8 at byte 7`,
- `()`: `Candid: No more values on the wire, the expected type text is not opt, null, or reserved
  at byte 6`.

`probe ("nosuch", 1, null)` decodes, and the handler rejects it, with `there is no probe
nosuch`. `greet ("extra", 1)` replies `("Hello, extra!")`: the extra argument is ignored.
`probe ("noop", 0)` runs the probe once, as the decoder makes the missing `opt nat` `null`.

Candid doubled the instructions of `greet`. With text arguments and replies, `greet "world"` took
169,607 (canister-opt.wasm: 169,247); `greet ("world")` took 173,042 more, 102% (canister-opt.wasm:
167,720, 99%). The difference goes to decoding the argument and encoding the reply, where the
text protocol only converted between bytes and a `String`, and to the charges for the memory
that these touch; how it divides was not measured. `hello` took 102,555 more without arguments,
and 119,603 more with `a` and `b`. Since the handlers run through `Std.Async`'s monad (see
[Calls](#calls)), `greet ("world")` takes 6,191 more, 2% (canister-opt.wasm: 5,678), and `hello`
6,195 more. These queries also make `ic0.time` calls, which cost at least
500 instructions each: `greet ("world")` 23, where `greet` made none with text, and `hello` 37,
where it made 12. Each comes from a closed term that the query initializes (see
[Installation](#installation)), now also of the code that decodes and encodes, and that the next
query initializes again, as the IC discards the changes that a query makes to memory
([abstract behavior][abstract]; see [Open questions](#open-questions-and-next-steps), 4). So at
least 11,500 instructions of `greet`'s difference are the IC's charges for `ic0.time`.

The measured work of the `noop` probe takes 286 instructions. The rest of its query goes to the
entry point, to decoding the argument and encoding the reply, and to the charges for the memory
that these touch. How it divides was not measured; [Memory pages](#memory-pages) shows the
charges in the probes. With text arguments, this query took 188,012 instructions, 259,542 fewer.
Before Canister.lean and its imports were module files (see [Installation](#installation)), it
took 428,012, exactly 240,000 more, the charge for 3 more pages that it touched. Without the meta
phase, the initializers create fewer objects, and the module's data (`.rodata`, `.data` and
`.bss`), which the link places at 8 MiB, after the C stack, lies on 1 page instead of 3
(`share/canister.map`). It still does with the Candid library.

### State across updates

The notes are an `IO.Ref (Array String)` that `initialize` creates when `canister_init` or
`canister_post_upgrade` initializes Lean. measure.py tries them after the first upgrade, as
updates execute rounds, which would have paid off the install before it (see
[Installation](#installation)), and then upgrades the canister again. Each `notes` has an
argument of its own, `"1"` to `"5"`, which it ignores (see [Measuring](#measuring)). In PocketIC:

| Call, in this order                         | Reply or outcome                | canister.wasm | canister-opt.wasm | `ic0.time` calls |
| ------------------------------------------- | ------------------------------- | ------------: | ----------------: | ---------------: |
| `add ("a")` (update)                        | `1`                             |       584,225 |           578,210 |               24 |
| `add_query ("b")` (query)                   | `2`                             |       292,834 |           289,531 |                0 |
| `notes ("1")` (query)                       | `vec { "a" }`                   |       321,458 |           316,569 |                7 |
| `add ("b")` (update)                        | `2`                             |       532,834 |           529,531 |                0 |
| `notes ("2")` (query)                       | `vec { "a"; "b" }`              |       327,847 |           322,644 |                7 |
| `add_then_exit ("c")` (update)              | trap: `exit(3)`                 |               |                   |                  |
| `notes ("3")` (query)                       | `vec { "a"; "b" }`              |       327,847 |           322,644 |                7 |
| `add_then_throw ("d")` (update)             | reject: `added d, then threw`   |       519,565 |           517,147 |                1 |
| `notes ("4")` (query)                       | `vec { "a"; "b"; "d" }`         |       334,453 |           328,936 |                7 |
| second upgrade: `canister_post_upgrade`     | accepted at once                |     4,308,706 |         4,070,198 |              267 |
| `notes ("5")` (query)                       | `vec {}`                        |       360,126 |           353,227 |               26 |

The `ic0.time` calls were the same on both modules.

- The notes stay from one update to the next, and the queries in between see them: the IC keeps
  what an update that does not trap changed in memory.
- `add_query ("b")` replies `2`, as `add` would, but the next `notes` does not have its note: the
  IC discards what a query changes ([abstract behavior][abstract]).
- `add_then_exit ("c")` adds a note and then calls `IO.Process.exit` with the number of notes.
  `exit()` ends in c/wasi.c's `proc_exit`, which traps with the message `exit(<code>)`. `exit(3)`
  shows that the note was added, and the next `notes` that the IC discarded it, as it discards
  all that a message that traps changed in memory ([interface specification][spec]).
- `add_then_throw ("d")` adds a note and then throws, which `serve` turns into a reject. The note
  stays: rejecting does not trap, and the IC keeps what an update that returns changed, whether
  it replied, rejected or neither ([abstract behavior][abstract]).
- After the second upgrade there are no notes: an upgrade starts with new memory
  ([interface specification][spec]), in which `canister_post_upgrade` creates the notes anew. A
  `canister_post_upgrade` that skipped Canister.lean's initializer would leave no notes either:
  the reference would be a null pointer, which reads as an empty array, as the address 0 is in
  the C stack, and readable. So measure.py checks that each `canister_post_upgrade` took as many
  instructions as `canister_init`, part by part, as both run the same initializers in new
  memory.

An update costs more than a query. `add ("b")` took 240,000 instructions more than
`add_query ("b")`, on both modules, which runs the same code with the same argument from the same
memory, as the IC discards what the queries between them changed. That is 3 pages at 80,000,
and measure.py checks that the difference is a multiple of 80,000: an update pays as much again
for its first write to a 64 KiB page as for its first access, which a query pays as well
([deterministic.rs][tracker], [system_api.rs][modification-tracking]). The 3 pages are all that
`add` wrote before c/canister.c read the counter. Which they are was not measured; from the
code, the objects that `add` allocates, the notes among them, and also the C stack, which lies in
memory, unlike the Wasm stack, the allocator's state and buffers, which lie in the module's data
(see [Queries](#queries)). With text arguments, `add "b"` took 324,714 instructions and
`add_query "b"` 164,714, 2 pages apart. So Candid and `Std.Async` add 208,120 to the update and
128,120 to the query, and the 80,000 between them are the third page that the update writes.

The first `add` took 51,391 instructions more than the second (canister-opt.wasm: 48,679). With
text arguments, when the first copied the empty array but initialized no closed terms, the
difference was 157 (canister-opt.wasm: 139). Now the first made 24 `ic0.time` calls, and the
second none: the first initialized 24 closed terms, of the code that decodes and encodes, and
these stayed, as the IC keeps what an update changes in memory. `add_query ("b")` found them
ready as well. Each `notes` query made 7 calls, for closed terms that `add` had not initialized,
which each query initializes anew; after the second upgrade, which starts with new memory,
`notes ("5")` made 26. `add_then_throw ("d")` made 1.

### Calls to other canisters

The methods that call (see [Calls](#calls)), tried after the second upgrade, with no notes, from
each canister, with the other one installed. A call is several messages: the entry point's,
which makes the call and returns, the callee's method, which is a message of this canister's
own when it calls itself, and the callback's, which runs the rest of the handler and replies.
The instructions of each, as c/canister.c and c/ic0.c log them, in the messages' order
(canister.wasm; canister-opt.wasm's are up to 2% less, and are in the report), and the
`ic0.time` calls of the first ones:

| Call, in this order                        | Reply or outcome                                             | Messages                                                  | Instructions                                    |
| ------------------------------------------ | ------------------------------------------------------------ | --------------------------------------------------------- | ----------------------------------------------- |
| `random ()`                                | 32 bytes                                                     | `random`, reply callback                                  | 590,013 / 591,292 (8 and 20 `ic0.time` calls)   |
| `random ()` again                          | 32 other bytes                                               | `random`, reply callback                                  | 537,869 / 561,964                               |
| `greet_via (self, "self")`                 | `"Hello, self!"`                                             | `greet_via`, `greet`, reply callback                      | 644,401 / 299,680 / 547,628                     |
| `greet_via (other, "other")`               | `"Hello, other!"`                                            | `greet_via`, reply callback                               | 634,348 / 548,498                               |
| `add_twice ("e")`                          | `(1, 2)`                                                     | `add_twice`, `add`, reply callback, `add`, reply callback | 575,632 / 536,941 / 575,087 / 532,719 / 556,371 |
| `add_both ("f", "g")`                      | `(3, 4)`                                                     | `add_both`, `add`, `add`, reply callback, reply callback  | 644,669 / 532,705 / 532,583 / 521,036 / 556,377 |
| `call_raw (self, "add_then_throw", ("h"))` | `Err "call rejected: 4 - added h, then threw"`               | `call_raw`, `add_then_throw`, reject callback             | 598,462 / 519,022 / 586,121                     |
| `call_raw (self, "nosuch", ())`            | `Err "call rejected: 5 - IC0536: … no update method 'nosuch'…"` | `call_raw`, reject callback                            | 580,050 / 616,952                               |
| `call_raw (2vxsx-fae, "greet", ("x"))`     | `Err "call rejected: 3 - No route to canister 2vxsx-fae"`    | `call_raw`, reject callback                               | 579,925 / 587,705                               |
| `call_then_exit ("i")`                     | rejected by the IC: `ic0.trap: exit(6)`                      | `call_then_exit`, `add`, cleanup callback                 | 570,976 / 532,673 / 492,456                     |
| `call_then_throw ("j")`                    | reject: `added j as note 7, then threw`                      | `call_then_throw`, `add`, reply callback                  | 570,274 / 533,326 / 529,732                     |
| `oneway_add ("k")`                         | `()`                                                         | `oneway_add`, `add`                                       | 569,246 / 533,346                               |
| `call_in_query ("x")` (query)              | trap: `"ic0_call_new" cannot be executed in non replicated query mode` | | |
| third upgrade                              | `canister_pre_upgrade`, then `canister_post_upgrade`         |                                                           | 160,379, then 4,308,706                         |

- `random` replies 32 bytes, which differ between the two calls: PocketIC's randomness is the
  round's. The first call initializes closed terms, 8 in the entry point and 20 in the callback,
  which stay, as an update's changes do: the second call makes no `ic0.time` call. Nor do the
  calls after it, except where a method runs for the first time.
- `greet_via` of this canister runs `greet` as a message of its own, 299,680 instructions, which
  logs its `greeting self` as any `greet` does (as a replicated query: its changes are
  discarded). Of the other canister, the callee's message is in that canister's log, and does
  not count here.
- `add_twice` makes its second call in the first callback: five messages. `add_both` makes both
  in the first: both `add`s run before either callback, and the replies come in the order of the
  calls here, `(3, 4)`. The notes have `e/1`, `e/2`, `f` and `g` afterwards.
- `call_raw` with a method that rejects, with one that does not exist, and with a principal that
  is no canister gets the reject codes 4, 5 and 3 (see [Calls](#calls)), with the IC's messages,
  and replies them as an `Err`; `h`'s note stays, as a reject keeps the callee's changes. The
  reject callback of the `nosuch` call takes 616,952 instructions, more than a reply callback:
  the message is long.
- `call_then_exit` adds `i`, then in the callback adds `i/callback` and exits: the IC discards
  the second note with the trap, runs the cleanup callback, 492,456 instructions, which discards
  the handler's continuation and logs (without the discarding, in an earlier version, it took
  323,595), and rejects the call, with `CANISTER_ERROR` and the trap's message, `exit(6)`, 6
  being `add`'s reply. The next `notes` has `i`, but not `i/callback`.
- `call_then_throw` adds `j` and throws in the callback: `serve` rejects from there, with the
  error's message, and the note stays.
- `oneway_add` replies at once, and `add` runs after it, in the same round: `k` is there at the
  next query. The response's callback, an index that the table does not have, traps where the IC
  would run it, which the canister does not see.
- `call_in_query` traps, as the System API refuses `call_new` in a query, with that message,
  which the IC passes on as the query's reject.
- Each callback found no call outstanding at its end, which the last one logs, and the third
  upgrade's `canister_pre_upgrade`, which would trap otherwise, took 160,379 instructions.

A message that makes a call costs about as much as `add` without a call, 0.53 million, plus
what the call's data takes; the callback, which decodes the reply, encodes the handler's reply
and replies, about as much as an update: 0.52 to 0.62 million. Of the callback's instructions,
the page charges are not separated out; `ic0.performance_counter(1)` counts the whole call
context, 1.2 million for `greet_via` of this canister, and 1.7 million for `add_twice` and
`add_both`. Nothing here was measured for a call across subnets, or with a response that times
out.

### Recursion depth

The largest depth that worked, for the probes of lean-wasm (see
[its README](../lean-wasm/README.md#recursion-depth)), with a 5 MiB Wasm stack:

| Probe                                   | lean-wasm | wasmtime | wasmtime, opt-level 0 | PocketIC | PocketIC, canister-opt.wasm |
| --------------------------------------- | ------: | ------: | ------: | ------: | ------: |
| `deep n`                                | 100,000 | 109,203 | 109,205 | 109,171 | 109,182 |
| `(countM n).run 0`                      |  50,000 |  65,519 |  81,902 |  81,876 |  81,884 |
| `toString (repr (List.range n))`        |  10,000 |  18,196 |  23,396 |  23,388 |  23,391 |
| `xs.zip xs`, where `xs := List.range n` |  20,000 |  46,800 |  54,602 |  54,584 |  46,791 |
| `deepK n id`                            |  10,000 |  15,599 |  16,379 |  16,374 |  16,376 |
| `deepKB n id`                           |  10,000 |  15,599 |  16,379 |  16,374 |  16,376 |

lean-wasm tried only the depths 1,000, 2,000, 5,000, 10,000, and so on, under wasmtime with its
default optimizations. The other columns come from the report, by bisection. In PocketIC, the
next depth failed with "Canister trapped: stack overflow"; under wasmtime, `run-probe.wasm` ran
out of stack ("call stack exhausted"). The IC compiles canisters with Cranelift's optimizations
off ([validation.rs][validation], [wasmtime_embedder.rs][execution-config]), and PocketIC's
depths come within 34 levels of wasmtime's then (within 7, before the canister could call: the C
stack in linear memory has a little more on it now).
So the code that the IC adds to count instructions hardly costs depth. With its default
optimizations, which lean-wasm used, wasmtime allows up to 22% less (`repr`; `countM` 20%). After
`wasm-opt -O`, the depth of `zip` drops to 46,791, below the 46,800 that wasmtime allows with its
optimizations.

### Instructions of Lean code

The work of each probe, in a query of its own, at the largest size that worked of those that
measure.py tries: the 1-2-5 series, and for `toUpper` 10,000, 20,000, 40,000 and so on up to
1,280,000, where ASCII text did not fail (canister.wasm):

| Probe                           | Size          |    Instructions | Per level or element |
| ------------------------------- | ------------- | --------------: | -------------------: |
| `deep n`                        | 100,000       |       5,800,307 |                   58 |
| `(countM n).run 0`              | 50,000        |       4,450,769 |                   89 |
| `deepK n id`                    | 10,000        |       6,071,734 |                  607 |
| `xs.zip xs`                     | 50,000        |      48,345,834 |                  967 |
| `deepKB n id`                   | 10,000        |      32,855,503 |                3,286 |
| `toString (repr xs)`            | 20,000        |     391,585,956 |               19,579 |
| `s.toUpper`, ASCII              | 1,280,000     |     226,561,808 |                  177 |
| `s.toUpper`, U+0100–U+01FF      | 20,000        |   1,635,740,313 |               81,787 |

Preparing the input is not counted: `List.range n` for `repr` and `zip`, and the string for
`toUpper`. Building the string costs more than upper-casing it in ASCII: its query takes
1,942,455,523 instructions in all.

### `String.map` exceeds the limit of a query

On non-ASCII text, Lean's `String.map`, and with it `toUpper`, copies the whole string for every
character (see [lean-wasm's README](../lean-wasm/README.md#stringmap-is-quadratic-on-non-ascii-text)),
twice ([object.cpp][lean-utf8-set]). With 2 bytes per character in UTF-8 and an instruction per
byte that `memory.copy` copies ([instrumentation.rs][instrumentation]), that is about 4n²
instructions for n characters: 1.6 billion for 20,000, as measured (1,635,740,313). By 4n², the
limit of 5 billion instructions for a query would allow about 35,000 characters (35,355).
Bisection found that `toUpper` worked at 34,956 and failed at 34,957: the query does more that
grows with the string, such as building it. lean-wasm timed 40,000 characters at 100 ms under
wasmtime. An update may use 40 billion instructions ([subnet_config.rs][subnet-config]),
which by 4n² would allow about 100,000 characters (not measured).

### Memory pages

Each probe also ran twice in one query. The second run costs less where the first touched new
memory pages or initialized closed terms, which the second finds ready (canister.wasm):

| Probe                    |   First run |  Second run | Difference |
| ------------------------ | ----------: | ----------: | ---------: |
| `deep 1,000`             |      58,307 |      58,307 |          0 |
| `zip 1,000`              |     968,874 |     888,354 |     80,520 |
| `repr 1,000`             |  18,896,279 |  18,646,111 |    250,168 |
| `deepKB 1,000`           |   3,270,783 |   3,162,274 |    108,509 |
| `toUpper 10,000`         |   1,771,808 |   1,771,682 |        126 |
| `toUpperNonAscii 10,000` | 417,870,313 | 417,240,250 |    630,063 |

`deep` uses only the Wasm stack, which is not memory that the IC charges for. For `zip`, the
difference is about the charge for one page. The counts of a first run therefore depend on where
in memory the allocator places objects: before the canister could call, `toUpper 10,000` took
the same in both runs, and `toUpperNonAscii 10,000` took 417,240,250 instructions in a query of
its own, where it takes 417,870,313 now, as in its first run here.

### wasm-opt

`wasm-opt -O` makes the module 29% smaller, and 21% gzipped. The install takes 11% fewer
instructions, as there are fewer to compile; `canister_init` 5% fewer, the queries and updates
up to 4% and the probes up to 6% fewer. The depth of `zip` drops by 14%.

## Open questions and next steps

1. **Candid, what remains.** The methods speak Candid (see
   [Candid in the canister](#candid-in-the-canister)), but a CDK needs more of it. A `func` or
   `service` reference is a value, but not yet a thing to call: `Ic.call` takes a principal and
   a method name (see [Calls](#calls)). The generated
   canister.did inlines every type, as `deriving CandidType` makes no named type definitions,
   which also means that it cannot derive a recursive type yet. The module has no custom section
   `icp:public candid:service`, in which the specification recommends that a canister publish its
   Candid interface ([state tree][state-tree]). `canister_init` does not decode its argument; it
   could read one, but not reject it, only trap, which fails the install
   ([interface specification][spec]). And `serve` decodes with the decoder's default fuel, with
   which a message near the 2 MiB that an ingress message may have, of values that take no bytes,
   such as a long `vec null`, can make decoding reach a query's or an update's instruction limit,
   so that the canister traps where it should reject; a smaller fuel avoids that, for messages
   that need less
   ([candid/README.md](../../candid/README.md#design-notes-and-the-differences-from-the-rust-crate)).
2. **State across upgrades.** What the updates store in an `IO.Ref` stays from one update to the
   next, but not across an upgrade, which starts with new memory (see
   [State across updates](#state-across-updates)). Stable memory, which upgrades keep, is
   untested: `canister_pre_upgrade` would have to save the state there, and
   `canister_post_upgrade` restore it. The IC can also keep the Wasm memory across an upgrade
   (`wasm_memory_persistence = opt keep`), but only for a module with a custom section named
   `enhanced-orthogonal-persistence` ([upgrade.rs][keep-memory], [validation.rs][custom-sections]),
   which the specification requires to be private, `icp:private enhanced-orthogonal-persistence`
   ([abstract behavior][abstract]); what that would take of Lean's runtime is open.
3. **Errors in updates.** `serve` turns a Lean error into a reject, and the IC keeps what the
   update changed before it threw (`add_then_throw`); a trap discards all of it
   (`add_then_exit`). So a CDK has to choose: to reject, and keep a part of the changes, or to
   trap, and keep none. From the code, not measured: `panic!` itself does neither. It prints the
   panic and goes on with a default value ([object.cpp][lean-panic]). Where `panic!` stands for an
   `IO` action, that value is an action that throws `` (`Inhabited.default` for `IO.Error`) ``
   ([ST.lean][lean-default], [IOError.lean][lean-default-error]), so `serve` rejects the update,
   which keeps its changes. The runtime's own panics, such as running out of memory, call `exit`,
   which traps ([object.cpp][lean-internal-panic]). And no code that can throw may run between
   taking the array out of a reference and putting it back: `serve` would reject the message, and
   the IC would keep the reference empty. `modifyGet` takes a pure function, which cannot throw;
   if it traps, the IC discards the taking with the rest.
4. **Closed terms in queries.** A closed term that a query initializes is initialized again in every
   query (see [Queries](#queries)), and with Candid the queries initialize some: `greet` 23,
   `hello` 37. One that an update initializes stays: the first `add` initialized 24, and
   `add_query`, the same code as a query, none after it (see
   [State across updates](#state-across-updates)). One that `canister_init` initializes should
   stay as well. So it could pay to initialize them early, for example by running the code of
   each query once in `canister_init`, without replying.
5. **The clock reads.** 4% of `canister_init` goes to reading the clock for locks that a runtime
   without threads does not need (see [Installation](#installation)), and so do at least 500
   instructions for each closed term that a query initializes, 11,500 in `greet` (see
   [Queries](#queries)). Patching the runtime's `lock_simple_atomic`, or caching `ic0.time` per
   message in c/wasi.c, would save that.
6. **Randomness.** `random_get` gives the same bytes in every canister, so `IO.rand` is not
   random. `random` gets real randomness from the management canister's `raw_rand`, with a call
   (see [Calls](#calls)); a canister that wants `IO.rand` to be random would seed c/wasi.c's
   generator from it, in a message of its own, as `canister_init` cannot call.
7. **Memory charges.** A query that does nothing, `probe ("noop", 0, null)`, takes 0.45 million
   instructions. How much of that is the charge for memory pages was not measured; reading
   `ic0.performance_counter` at points within a query would show it. An update pays for the
   pages that it writes as well: `add` 240,000 instructions for 3 pages (see
   [State across updates](#state-across-updates)).
   The counts of Lean code depend on where objects lie. The
   runtime allocates every object with wasi-libc's `malloc`; an allocator that keeps a message's
   objects on fewer pages could take fewer instructions.
8. **Compilation.** Compiling takes 6,000 instructions per instruction of the module, 5.6 billion
   for this one. Init accounts for half of the code of a hello world (see lean-wasm), and the
   Candid library for about 30% of this module's (`share/canister.map`); a module that imports
   less of them would install for less. Installing the module again, in an upgrade, a reinstall
   or another canister, costs 20 million plus a hundredth of the rest, 76 million, but only until
   the subnet's next checkpoint.
9. **Mainnet.** On the IC, `ic0.debug_print` adds to the canister's log, which keeps 4 KiB by
   default, and the replica prints nothing. A non-replicated query's log is discarded. An
   update's stays, also when the update traps, which adds a `[TRAP]` record
   ([system_api.rs][trap-log]). So the instruction counts that the queries log are a PocketIC
   convenience, but those of the updates reach the canister's log.
10. **macOS.** The report on aarch64-darwin is untested, and its page charges would differ (see
    [Measuring](#measuring)), as may its depths under wasmtime.
11. **Calls, what remains.** After a callback trapped, the cleanup callback frees the
    continuation that waited on the call (see [Calls](#calls)), but a task of the chain that
    something else still refers to stays allocated, as a task that never finishes; what remains
    is small. The outstanding calls are a counter: a task that a handler made and another
    handler awaits is not detected (see [Calls](#calls)), as Motoko's scoped await and ic_cdk
    0.19 detect it.
    Nothing calls from a composite query, a timer or a heartbeat, which can call too, and whose
    callbacks must not reply; nothing attaches cycles to a call, though `Ic.Call.cycles` does,
    nor accepts them. A handler cannot reply before it awaits. `SYS_UNKNOWN`, the reject of a
    bounded-wait call that timed out, was not produced in PocketIC. And the `Ic.Async` monad
    comes from `Std.Async`, which Lean 4.34.1 marks internal: its names may change.

## Sources

The IC's code is that of PocketIC 16.0.0: commit 0ec627118654351acff526328b01c8395d7de414, the
tag `release-2026-09-25_03-28--all-in-one`, from which ic-nix's release 20261009 builds it. The
limits, costs and rules cited here are the same in `release-2026-10-08_03-33-base`, which
lean-wasm cites.

1. [Resource limits][limits]
2. [The canister interface][spec]: the performance counter, gzipped modules, what a trap and an
   upgrade discard, and that `canister_init` cannot reject
3. [The abstract behavior][abstract]: a query's changes are discarded, and an update's kept unless
   it traps; the custom section for keeping the Wasm memory
4. [subnet_config.rs][subnet-config]: limits on instructions, page charge, `install_code` rate
5. [embedders.rs][embedders]: the cost of compiling
6. [instrumentation.rs][instrumentation]: counting instructions, `memory.copy`
7. [execution_environment.rs][compiled-wasms-insert]: which modules count as compiled already
   ([the lookup][compiled-wasms]), and [what they cost][compiled]
8. [hypervisor.rs][hypervisor]: the 20 million of every compilation
9. [scheduler.rs][checkpoint]: a checkpoint forgets the modules that were compiled
10. [install_code.rs][install-code], [round_schedule.rs][round-end] ([the credit][round-schedule],
    [the schedule][schedule-retain]), [replicated_state.rs][subnet-schedule] and
    [canister_state.rs][must-be-in-schedule]: the rate of `install_code`
11. [deterministic.rs][tracker] and [system_api.rs][modification-tracking]: the charge for memory
    pages, and which messages pay for writes
12. [system_api_complexity.rs][complexity]: the charges for System API functions
13. [validation.rs][validation] and [wasmtime_embedder.rs][execution-config]: wasmtime's
    configuration
14. [lib.rs][embedders-lib]: the Wasm stack
15. [Cargo.toml][ic-cargo]: the IC's wasmtime
16. [query_cache.rs][query-cache]: the query cache
17. [rs/sys][sys]: the OS page size
18. [validation.rs][duplicate-export]: a name exported as a query and as an update, and
    [custom sections][custom-sections]
19. [upgrade.rs][keep-memory]: keeping the Wasm memory across an upgrade
20. [system_api.rs][trap-log]: what the IC keeps of an update that traps
21. [__wasilibc_real.c][wasilibc]: wasi-libc's WASI imports (wasi-sdk-32)
22. [Writer.cpp][lld-writer], [Relocations.cpp][lld-relocations] and
    [SymbolTable.cpp][lld-symboltable]: wasm-ld (LLVM 21.1.8)
23. [object.cpp][lean-once]: Lean's closed terms, and [object.cpp][lean-utf8-set]: `String.set`
    (Lean 4.34.1)
24. [io.cpp][lean-ref], [object.cpp][lean-mark-mt] and [object.cpp][lean-push]: references that
    `initialize` creates, and `Array.push` (Lean 4.34.1)
25. [object.cpp][lean-panic] ([internal panics][lean-internal-panic]), [ST.lean][lean-default] and
    [IOError.lean][lean-default-error]: `panic!` (Lean 4.34.1)
26. [poll_with_backoff.h][libcxx]: libc++'s waiting (LLVM 21.1.8)
27. [pocketic-py][pocketic-py] 3.1.2 and [ic-py][ic-py] 1.0.1: PocketIC's Python library, and the
    Candid that it uses; [DIDEmitter.py][ic-py-parser]: ic-py's parser of `.did` files
28. [The Candid specification][candid-spec], version 0.1.8: `spec/Candid.md` at commit 10423fae of
    dfinity/candid, the flake input `candid`; the binary format, and subtyping
29. [The Rust crate `candid`][candid-crate] 0.10.38, at the same commit: the decoder's error
    messages
30. [The system state tree][state-tree], a section of the IC interface specification's main page:
    the custom section `icp:public candid:service`
31. [The canister interface][spec-call], its section on inter-canister calls: `ic0.call_*`, the
    callbacks, `call_perform`'s codes, best-effort responses
32. [The abstract behavior][abstract-callbacks]: how a callback and its cleanup run;
    [starvation][abstract-starvation]: the reject when nothing can reply; [stopping][abstract-stopping]:
    a canister stops when it has no open call contexts
33. [call.rs][cdk-call] of cdk-rs, the Rust CDK (commit 070233b): the call builder, the
    callback and cleanup trampolines, and the errors that `Ic.Error` mirrors
34. [instrumentation.rs][export-table]: the IC exports the module's function table itself
35. [object.cpp][lean-task-manager]: Lean's task manager, which lean-wasm's patch makes work
    without threads, and [Std/Async/Basic.lean][std-async]: the `EAsync` monad (Lean 4.34.1)
36. [pocket_ic.py][pocketic-update-call] of pocketic-py: `update_call` executes at most 100 rounds

[limits]: https://docs.internetcomputer.org/references/resource-limits.md
[spec]: https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md
[abstract]: https://docs.internetcomputer.org/references/ic-interface-spec/abstract-behavior.md
[subnet-config]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/config/src/subnet_config.rs
[embedders]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/config/src/embedders.rs#L57-L63
[instrumentation]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasm_utils/instrumentation.rs
[compiled-wasms]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/execution_environment.rs#L4319-L4329
[compiled-wasms-insert]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/execution_environment.rs#L4400-L4407
[compiled]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/execution_environment.rs#L5055-L5068
[hypervisor]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/hypervisor.rs#L290-L291
[checkpoint]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/scheduler.rs#L1136-L1141
[install-code]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/execution/install_code.rs#L523-L578
[round-end]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/scheduler/round_schedule.rs#L530-L605
[round-schedule]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/scheduler/round_schedule.rs#L709-L746
[subnet-schedule]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/replicated_state/src/replicated_state.rs#L590-L602
[must-be-in-schedule]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/replicated_state/src/canister_state.rs#L279-L291
[schedule-retain]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/scheduler/round_schedule.rs#L292-L313
[tracker]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/memory_tracker/src/deterministic.rs#L317-L404
[modification-tracking]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasmtime_embedder/system_api.rs#L706-L726
[complexity]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasmtime_embedder/system_api_complexity.rs
[validation]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasm_utils/validation.rs#L1733-L1786
[execution-config]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasmtime_embedder.rs#L265-L296
[embedders-lib]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/lib.rs#L28-L29
[ic-cargo]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/Cargo.toml#L1024
[query-cache]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/query_handler/query_cache.rs
[duplicate-export]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasm_utils/validation.rs#L1150-L1166
[custom-sections]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasm_utils/validation.rs#L1395-L1428
[keep-memory]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/execution/upgrade.rs#L908-L983
[trap-log]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasmtime_embedder/system_api.rs#L1789-L1815
[sys]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/sys/src/lib.rs#L30-L37
[wasilibc]: https://github.com/WebAssembly/wasi-libc/blob/wasi-sdk-32/libc-bottom-half/sources/__wasilibc_real.c
[lld-writer]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/lld/wasm/Writer.cpp
[lld-relocations]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/lld/wasm/Relocations.cpp
[lld-symboltable]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/lld/wasm/SymbolTable.cpp
[lean-once]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L2892-L2916
[lean-ref]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/io.cpp#L1446-L1521
[lean-mark-mt]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L670-L673
[lean-push]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L2739-L2784
[lean-panic]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L175-L202
[lean-internal-panic]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L92-L100
[lean-default]: https://github.com/leanprover/lean4/blob/v4.34.1/src/Init/System/ST.lean#L129-L130
[lean-default-error]: https://github.com/leanprover/lean4/blob/v4.34.1/src/Init/System/IOError.lean#L142-L143
[lean-utf8-set]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L2488-L2513
[libcxx]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/libcxx/include/__thread/poll_with_backoff.h#L36-L41
[pocketic-py]: https://github.com/dfinity/pocketic-py
[ic-py]: https://github.com/rocklabs-io/ic-py
[ic-py-parser]: https://github.com/rocklabs-io/ic-py/blob/v1.0.1/ic/parser/DIDEmitter.py
[candid-spec]: https://github.com/dfinity/candid/blob/10423fae0c84f6a3f13abf1042f28f2ae40ac3af/spec/Candid.md
[candid-crate]: https://github.com/dfinity/candid/tree/10423fae0c84f6a3f13abf1042f28f2ae40ac3af/rust/candid
[state-tree]: https://docs.internetcomputer.org/references/ic-interface-spec/index.md
[spec-call]: https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md#system-api-call
[abstract-callbacks]: https://docs.internetcomputer.org/references/ic-interface-spec/abstract-behavior.md#the-concrete-callback
[abstract-starvation]: https://docs.internetcomputer.org/references/ic-interface-spec/abstract-behavior.md#rule-starvation
[abstract-stopping]: https://docs.internetcomputer.org/references/ic-interface-spec/abstract-behavior.md#ic-management-canister-stopping-a-canister
[cdk-call]: https://github.com/dfinity/cdk-rs/blob/070233b9c2820032b37ccf60ad9643eeb22b63a7/ic-cdk/src/call.rs
[export-table]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasm_utils/instrumentation.rs
[lean-task-manager]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L769-L1109
[std-async]: https://github.com/leanprover/lean4/blob/v4.34.1/src/Std/Async/Basic.lean
[pocketic-update-call]: https://github.com/dfinity/pocketic-py/blob/main/pocket_ic/pocket_ic.py
