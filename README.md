# cistern

A Canister Development Kit (CDK) for Lean 4: Lean programs as canisters of the Internet Computer
(IC). It is work in progress, in three parts on one Nix flake:

- [candid/](candid): a Lean library for Candid, the IC's interface description language and
  binary format: types and values, the binary and the text format, subtyping, and
  `deriving CandidType` ([its README](candid/README.md)).
- [experiments/lean-canister/](experiments/lean-canister): a canister written in Lean, measured in
  PocketIC, a local IC replica: the entry points, WASI on top of the System API, Candid methods,
  state, calls to other canisters, and what each costs in instructions
  ([its README](experiments/lean-canister/README.md)).
- [nix/](nix): what both share. The Lean toolchain ([nix/lean4.nix](nix/lean4.nix)), the Lean
  runtime and the libraries `Init` and `Std.Async.Basic` built for wasm32
  ([nix/lean-runtime.nix](nix/lean-runtime.nix), [nix/lean-libs.nix](nix/lean-libs.nix)),
  PocketIC and its Python library ([nix/pocket-ic.nix](nix/pocket-ic.nix),
  [nix/pocket-ic-py.nix](nix/pocket-ic-py.nix)), and the check that every `.lean` file opens in
  an editor without errors ([nix/lean-files-open.nix](nix/lean-files-open.nix)).

## Running it

```sh
nix flake check                                             # every check, see below
nix build .#lean-canister-report && cat result/report.txt   # the canister's measurements
nix develop                                                 # lean, lake, wasm-objdump, pocket-ic
```

The checks are the Candid library's tests and its conformance run, the canister's interface and
its report in PocketIC, PocketIC itself, and `lean-files-open`; the dev shell also has `python3`
with pocketic-py. The packages that both parts share (the Candid library's and the canister's are
in their READMEs):

| Attribute                   | Output                                                                              | Built by                                     |
| --------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------- |
| `lean4`                     | the native Lean: `lean`, `lake`, the sources and `.olean` files of `Init` and `Std` | [nix/lean4.nix](nix/lean4.nix)               |
| `lean-runtime`              | Lean's C++ runtime for wasm32-wasip1: `lib/libleanrt.a`, `include/lean/*.h`         | [nix/lean-runtime.nix](nix/lean-runtime.nix) |
| `lean-init-c`, `lean-std-c` | the C that `lean -c` generates for the modules of `Init`, and for `Std.Async.Basic` | [nix/lean-libs.nix](nix/lean-libs.nix)       |
| `lean-init`, `lean-std`     | `lib/libInit.a`, `lib/libStd.a`: that C, compiled for wasm32                        | [nix/lean-libs.nix](nix/lean-libs.nix)       |
| `pocket-ic`, `pocket-ic-py` | PocketIC, and `python3` with pocketic-py; not on aarch64-linux, which ic-nix lacks  | [nix/pocket-ic.nix](nix/pocket-ic.nix), [nix/pocket-ic-py.nix](nix/pocket-ic-py.nix) |

## The Lean toolchain

One Lean does everything: `lean -c` compiles the Lean code to C natively, its `Init` and `Std`
sources are compiled for wasm32, and so is its runtime. It is the flake input `lean4`: the branch
[`cistern`][cistern-branch] of a fork of lean4, [basvandijk/lean4][fork]. The branch is the commit
of upstream `master` from which the nightly named in [lean-toolchain](lean-toolchain) was built,
today `nightly-2026-10-24`, commit [f68d6e9826][nightly-commit], plus four commits:

1. The fix of `LEAN_SCALAR_PTR_LITERAL` for 32-bit targets (cb7dd11f4c, on the branch
   `fix-scalar-ptr-literal-32bit`; upstream issue [lean4#15814][issue-15814]). `lean.h` used the
   32-bit form only on Emscripten; with the 64-bit one, a scalar field of a static object came out
   a slot short on wasm32, without a warning from clang, which corrupted the hashes in name
   literals, among other things.
2. The cooperative task manager (on the branch `cooperative-task-manager`): without worker threads
   the manager queues tasks and runs them on the calling thread (see
   [The runtime for wasm32](#the-runtime-for-wasm32)).
3. The signatures of `lean_io_create_tempfile` and `lean_io_create_tempdir`, which took a world
   parameter that Lean's declarations do not have: harmless natively, a trap on WebAssembly, where
   wasm-ld substitutes a stub for a function whose type differs from its declaration.
4. The wasm32-wasip1 support: `__wasi__` guards in the runtime, and `src/runtime/wasi/`, the
   stubs for what the WASI build leaves out and the stand-in for libuv's header (see below).

The first two are on branches of their own, meant for upstream pull requests; a change to one of
them is made there, and `cistern` is re-created from this recipe. The `String.toList` bug that the
Candid tests found on wasm32 ([lean4#15530][issue-15530]) is fixed on upstream `master` since
2026-10-07 ([153e0118][string-to-list]), so the branch needs no commit for it.

The native compiler is built from the branch with nixpkgs' recipe for lean4, overridden in
[nix/lean4.nix](nix/lean4.nix): the fork as its source, nixpkgs' CaDiCaL, which Lean links over
FFI, and the version `4.37.0-pre`, what `lean --version` prints for a build that is not a release.
No public binary cache has it: a first `nix build .#lean4` compiles stage 0 and stage 1, tens of
minutes on a large machine. CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) builds the
Linux checks on nixbuild.net, whose store keeps what it built, the compiler included, for CI and
for a developer's Nix.

The editor does not use the flake's Lean. Lean's VS Code extension runs `lake serve` with the
toolchain that lean-toolchain names, the official nightly, which elan installs; it elaborates the
same library, as the fork changes only the runtime, and docstrings. The dev shell's `lean` and
`lake` are the flake's, so the two rebuild each other's output in `.lake` (see the comment in
[lakefile.toml](lakefile.toml)). The check `lean-files-open` requires lean-toolchain to name the
nightly that [flake.nix](flake.nix) records (`nightly`, which nix/lean4.nix passes on); that the
branch is based on that nightly's commit is the invariant that Nix cannot check.

To move to a newer nightly: in a clone of the fork, `git rebase --onto <the new nightly's commit>
<the old base> cistern`, build and run the tests, `git push -f basvandijk cistern`; then here
`nix flake update lean4`, and set `nightly` in flake.nix and lean-toolchain to the new name. A
nightly is a commit of upstream `master`, released by [leanprover/lean4-nightly][nightly-releases].

## The runtime for wasm32

Lean compiles to C, and the C needs Lean's runtime: `lean.h`, and a C++ library for
reference-counted objects, bignums, strings, IO, tasks and so on. Lean's CMake build does not build
the runtime on its own, nor for WebAssembly, so [nix/lean-runtime.nix](nix/lean-runtime.nix)
compiles the runtime's files directly, for `wasm32-wasip1`, with the clang, wasi-libc and libc++ of
nixpkgs' `pkgsCross.wasi32` (nixpkgs has no wasi-sdk; this is its counterpart) and the flags of
upstream's release build; the recipe is the header comment of the fork's [stubs.cpp][stubs].
[nix/lean-libs.nix](nix/lean-libs.nix) compiles `Init`, the library that every Lean file imports,
and `Std.Async.Basic`, which the canister's calls use, to C with the native `lean`, and that C for
wasm32, into `libInit.a` and `libStd.a`: lean4 ships Init compiled for the host only, as `.olean`
files and native libraries, so the C is regenerated from the sources it ships; it is the same for
every target, with sizes as `sizeof(void*)` expressions, for example. A canister links the C of its
own modules with these, with the Candid library, and with
[c/wasi.c](experiments/lean-canister/c/wasi.c), which implements the WASI functions that the code
needs on top of the IC's System API
([WASI on ic0](experiments/lean-canister/README.md#wasi-on-ic0)).

The configuration is the smallest one:

- **No threads**: `LEAN_MULTI_THREAD` is off, as the IC has none (the replica builds its Wasm
  engine without the threads proposal, [Cargo.toml][ic-cargo]). The task manager, which runs the
  tasks of `Task` and `IO.Promise`, is then in its cooperative mode (which
  `lean_init_task_manager_using(0)` also selects in a build with threads): a spawned task
  (`Task.spawn`, `IO.asTask`), a continuation that a resolve readies (`Task.map`, `Task.bind`,
  `BaseIO.bindTask`) and a dropped promise only queue work; nothing runs inside a spawn or
  `IO.Promise.resolve`. Queued tasks run on the calling thread when it waits (`Task.get`,
  `IO.wait`, `IO.waitAny`: the awaited task first, then by priority), sleeps (`IO.sleep`, which
  then returns at once, as the thread-less `sleep_for` does nothing), at exit, or when the host
  calls `lean_run_pending_tasks()`, which runs every queued task until the queue is empty, those
  queued meanwhile included. Only a `(sync := true)` continuation runs inline, in whatever
  finishes its task. A wait that nothing queued can finish is a fatal internal panic, where a
  threaded runtime would block forever; so is `Promise.result!` on a dropped promise, where
  `Promise.result?` gives `none`. `lean_io_promise_discard(promise)` resolves a promise with
  `none` without running the tasks that wait for it: it frees their closures and the reference
  that keeps a task alive for its effects, transitively; a task that something else still
  references is orphaned, never finishes, and is freed with its last reference; resolving the
  promise afterwards does nothing. The docstrings of `Task`, `IO.wait` and `IO.sleep`
  ([Init/Core.lean][core-lean], [Init/System/IO.lean][io-lean]), the declarations in
  [lean.h][lean-h] and the comment of `task_manager` in [object.cpp][lean-task-manager] say the
  rest. The canister runs the queue at the end of every entry point and callback, so that a
  handler that awaited a call goes on in the callback's message
  ([Calls](experiments/lean-canister/README.md#calls)).
- **No GMP**: Lean's own bignum code (`mpz.cpp`, `mpn.cpp`).
- **No mimalloc, no mmap**: `config.h` is lean4's minus `LEAN_MIMALLOC`, so Lean objects come from
  wasi-libc's `malloc`.
- **Left out**: `process.cpp` (WASI has no processes), `stack_overflow.cpp` (no signals),
  `libuv.cpp` and `uv/*.cpp` (no libuv), `openssl.cpp`, `mimalloc.cpp`, and `compact.cpp`
  (compacted regions need mmap, and Init does not use them); `cadical.cpp` is compiled without
  `LEAN_CADICAL`, to stubs. The other 21 files of `src/runtime` are built, with the two of
  [src/runtime/wasi/][wasi-dir]: [stubs.cpp][stubs] defines what the rest refers to in the
  left-out files (spawning a process is an "unsupported operation" error, the process id is 0,
  `flock` fails with `ENOSYS`, `lean_setup_args` returns its argument, the current directory
  works), and [uv.h][uv-h] stands in for libuv's header, which `io.cpp` includes, with libuv's
  error codes and a few synchronous file system calls; temporary files and directories are
  unsupported. `IO.getRandomBytes` reads `getentropy`, WASI's `random_get`, as there is no
  `/dev/urandom`; Init calls it at startup.
- **C++ exceptions**: the runtime throws in a few places, when the stack or the heap runs out, for
  example. The IC rejects Wasm exception handling [3], so the runtime is compiled with
  `-fexceptions` but without `-fwasm-exceptions`, and LLVM drops every `catch`. nixpkgs' libc++abi
  for WASI has no exception support, so stubs.cpp defines `__cxa_throw`: it prints the exception
  and aborts, which traps, and on the IC a trap discards the message's changes [2]. Lean's IO
  errors are values, not C++ exceptions, and are not affected.

### The stacks

Lean code keeps its locals in Wasm locals: its frames are on the engine's stack, whose size the
engine sets, 5 MiB on the IC [4]. Native Lean runs `main` on a thread with a 1 GB stack on 64-bit
platforms ([thread.cpp][thread-cpp]); the runtime without threads runs it on the stack it has. The
C stack in linear memory holds only the frames of the runtime's stack users, among them the bignum
functions and `lean_apply_1` to `lean_apply_16`, through which Lean calls closures, with 16 to 64
bytes per call: recursion through closures uses it a little at every level, and wasm-ld's default
of 64 KiB ran out long before the engine's stack did (a probe that recursed through closures over
bignums trapped with "out of bounds memory access" at depth 5,000). So the link uses 8 MiB, what
Lean gives threads on its 32-bit target, and `--stack-first`, which puts the stack at the bottom of
memory, so that an overflow traps instead of overwriting the static data; the stack is the first
128 pages. With it, the engine's stack runs out first: non-tail recursion traps after some ten
thousand levels, in Init functions such as `List.zip` and `repr` too, where native Lean goes to
millions. The canister's README has the depths
([Recursion depth](experiments/lean-canister/README.md#recursion-depth)).

### `String.map` is quadratic on non-ASCII text

This is upstream Lean's behaviour, natively too, but it matters more under the IC's instruction
limits. `String.map`, and with it `String.toUpper` and `String.toLower`, writes every character
back with `String.Pos.set`. The runtime does that in place only if the string is not shared and
both the old and the new character are ASCII; otherwise it copies the whole string
([object.cpp][lean-utf8-set], which has a TODO about it). So on non-ASCII text every character
costs a copy of the string: a query that upper-cases 35,000 such characters exceeds the IC's limit
for a query ([`String.map` exceeds the limit of a
query](experiments/lean-canister/README.md#stringmap-exceeds-the-limit-of-a-query)).

### Wasm features

A module needs these proposals beyond the MVP: sign-extension, non-trapping float-to-int,
`memory.copy`/`memory.fill` (bulk-memory-opt) and the `call_indirect` encoding of reference types
(call-indirect-overlong); it uses no SIMD, threads, exception handling or tail calls. The IC accepts
all of them ([validation.rs][validation], which configures the engine's features, and
[Cargo.toml][ic-cargo]). This comes from validation with `wasm-tools`, leaving out one proposal at
a time, not from the module's `target_features` section, which lists what clang was allowed to
use: also multivalue, mutable-globals and all of reference-types and bulk-memory. binaryen's
`wasm-opt --print-features` only repeats that section.

### Where the size comes from

A hello world, Hello.lean with Init and the runtime as a WASI command, was 934,973 bytes (148,096
gzipped) with Lean 4.34.1, and its link map divided the code so:

| Origin               | Code bytes | Functions | Object files |
| -------------------- | ---------: | --------: | -----------: |
| Lean's Init library  |    394,092 |     1,323 |          649 |
| libc++ and libc++abi |    161,183 |       535 |           21 |
| Lean runtime         |    148,011 |       234 |           15 |
| wasi-libc            |     55,349 |       154 |          111 |
| Hello.lean           |      8,814 |        22 |            1 |

Init is half of the code (51%). Code from every one of its modules is in the module, as
`runtime_initialize_Init` runs the runtime initializer of each one, and the 649 initializers alone
are 82% of Init's code (324,324 bytes). Most of the libc++ code is locale support (`locale.cpp`),
which the runtime's use of iostreams pulls in. The name section is another 144,426 bytes;
`wasm-opt -O` made the module 632,405 bytes, partly by dropping it, with the same imports and
exports.

Only the runtime phase is linked. Each module has an initializer, `initialize_<Module>`, which
computes the module's top-level constants and calls those of its imports. A module file, one that
starts with `module`, has a second one, `runtime_initialize_<Module>`, which does only what the
program needs when it runs; `initialize_<Module>` also runs the meta phase,
`meta_initialize_<Module>`, what the compiler needs when it compiles a file that imports the
module, such as the descriptors of the syntax that the module declares. The generated `main`, and
the canister's `canister_init`, call the runtime one, and wasm-ld drops the rest. Before Hello.lean
was a module file, `main` called `initialize_Hello`, and the hello world had 1,999,514 bytes, with
1,147,791 bytes of Init code in 4,872 functions and 87,942 bytes of Init data: 66% of that code and
98% of that data were there for the meta phase only, nearly all of it initialization: the 649
`initialize_` functions, the meta initializers, and 2,499 functions that compute constants, 1,992
of them the tactic scripts of auto-params (arguments that a tactic proves when the caller leaves
them out) and 507 the descriptors of Init's syntax.

## Open questions

Those of the runtime; the canister has
[its own](experiments/lean-canister/README.md#open-questions-and-next-steps).

1. **Size.** Init's runtime initializers keep 0.39 MB of Init in even a hello world, 0.32 MB of it
   the initializers themselves, and the IC charges 6,000 instructions per instruction of the
   module when it installs it ([Installation](experiments/lean-canister/README.md#installation)).
   A file that starts with `prelude` does not import Init implicitly, and can import just the Init
   modules it needs; whether that helps is untested. Std and Lean code that needs libuv (timers,
   sockets), OpenSSL or compacted regions does not link.
2. **Traps.** Any C++ `throw` traps, including ones that native Lean reports gracefully. So does
   running out of stack, at depths that native Lean handles easily. On a trap, output still
   buffered in stdout is lost.
3. **32 bits.** A WASI-based canister is wasm32-only, as the toolchain has no wasm64 target
   ([wasi-sdk][wasi-sdk]), although the IC supports wasm64 with a 6 GiB heap [1]. On wasm32,
   `USize` is 32 bits and naturals above 2^31 - 1 are bignums ([Numbers](candid/README.md#numbers)).
4. **State.** The Lean heap lives in Wasm memory. The IC keeps that memory between messages but
   discards it on upgrade, unless `wasm_memory_persistence` is `opt keep` [2]. Anything that has
   to survive upgrades needs stable memory. The canister keeps state in an `IO.Ref`: an update's
   changes stay, unless it traps, and a query's are discarded
   ([State across updates](experiments/lean-canister/README.md#state-across-updates)). `opt keep`
   needs a module with the custom section `icp:private enhanced-orthogonal-persistence`
   ([its next steps](experiments/lean-canister/README.md#open-questions-and-next-steps)).

## Sources

The IC's limits are those of replica `release-2026-10-08_03-33-base`; on 2026-10-17 the cited code
on `master` was the same. Lean's code is that of the `cistern` branch, with the line numbers of
2026-10-24.

1. https://docs.internetcomputer.org/references/resource-limits.md
2. https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md
3. https://github.com/dfinity/ic/blob/master/rs/embedders/src/wasm_utils/validation.rs
4. https://github.com/dfinity/ic/blob/master/rs/embedders/src/lib.rs

[fork]: https://github.com/basvandijk/lean4
[cistern-branch]: https://github.com/basvandijk/lean4/tree/cistern
[nightly-commit]: https://github.com/leanprover/lean4/commit/f68d6e982657e2a8bb8c2280d886b2d36cb2180f
[nightly-releases]: https://github.com/leanprover/lean4-nightly/releases
[issue-15814]: https://github.com/leanprover/lean4/issues/15814
[issue-15530]: https://github.com/leanprover/lean4/issues/15530
[string-to-list]: https://github.com/leanprover/lean4/commit/153e01180e59305df575e24b803cf7416a251bcf
[wasi-dir]: https://github.com/basvandijk/lean4/tree/cistern/src/runtime/wasi
[stubs]: https://github.com/basvandijk/lean4/blob/cistern/src/runtime/wasi/stubs.cpp
[uv-h]: https://github.com/basvandijk/lean4/blob/cistern/src/runtime/wasi/uv.h
[lean-h]: https://github.com/basvandijk/lean4/blob/cistern/src/include/lean/lean.h#L1612-L1629
[core-lean]: https://github.com/basvandijk/lean4/blob/cistern/src/Init/Core.lean#L616-L651
[io-lean]: https://github.com/basvandijk/lean4/blob/cistern/src/Init/System/IO.lean#L568-L586
[lean-task-manager]: https://github.com/basvandijk/lean4/blob/cistern/src/runtime/object.cpp#L772-L1449
[thread-cpp]: https://github.com/basvandijk/lean4/blob/cistern/src/runtime/thread.cpp#L24-L30
[lean-utf8-set]: https://github.com/basvandijk/lean4/blob/cistern/src/runtime/object.cpp#L2886-L2914
[validation]: https://github.com/dfinity/ic/blob/master/rs/embedders/src/wasm_utils/validation.rs
[ic-cargo]: https://github.com/dfinity/ic/blob/master/Cargo.toml
[wasi-sdk]: https://github.com/WebAssembly/wasi-sdk
