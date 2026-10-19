# Experiment: Lean on WebAssembly

**Question.** How far is a Lean 4 program from running as an Internet Computer (IC) canister?
As a first step, this experiment compiles a small Lean program, [Hello.lean](Hello.lean), to
WebAssembly (`wasm32-wasip1`), runs it under wasmtime, and compares the module with what the IC
accepts.

**Answer so far.** The module is well within every structural limit that the IC checks: size,
number of functions, per-function size and complexity, and Wasm features. It does not have the
canister interface yet. Its 14 imports are all WASI, and the IC accepts only `ic0` imports. It
exports `_start`, but no `canister_*` entry points. The [lean-canister](../lean-canister)
experiment takes the next steps: it replaces WASI with `ic0`, adds the entry points, and measures
the module in PocketIC, a local IC replica.

All numbers below come from the build outputs, mostly from `report.txt`, except the recursion
depths and the `String.map` timings, which were measured by hand (see [Recursion
depth](#recursion-depth)). Every step is a
Nix derivation that builds in the sandbox, and `nix build --rebuild` reproduces each output bit
for bit.

## Running it

```sh
nix build .#lean-wasm-report && cat result/report.txt   # the inspection, see below
nix flake check                                         # hello.wasm must print what native Lean prints
```

By hand, in the dev shell (it provides `lean`, `wasmtime` and `wasm-objdump`):

```sh
nix develop
hello=$(nix build .#lean-wasm-hello --no-link --print-out-paths)
wasmtime run $hello/bin/hello.wasm
wasmtime run $hello/bin/hello.wasm a b              # prints 2^102 and 2^33 + 1 instead
lean --run experiments/lean-wasm/Hello.lean         # the same, natively
wasm-objdump -x -j Import $hello/bin/hello.wasm
```

`wasm-tools` and `wasm-opt` (binaryen) are not in the dev shell. Use
`nix shell --inputs-from . nixpkgs#wasm-tools nixpkgs#binaryen` for them.

Each step is a flake package:

| Attribute           | Output                                                                  | Built by                           |
| ------------------- | ----------------------------------------------------------------------- | ---------------------------------- |
| `lean-wasm-init-c`  | C for the 649 modules of Lean's `Init` library (32,209,233 bytes)       | [nix/lean-c.nix](nix/lean-c.nix)   |
| `lean-wasm-hello-c` | `Hello.c`                                                               | [nix/lean-c.nix](nix/lean-c.nix)   |
| `lean-wasm-runtime` | Lean's C++ runtime for wasm32: `lib/libleanrt.a`, `include/lean/*.h`    | [nix/runtime.nix](nix/runtime.nix) |
| `lean-wasm-init`    | `lib/libInit.a`: the Init C, compiled for wasm32                        | [nix/wasm.nix](nix/wasm.nix)       |
| `lean-wasm-hello`   | `bin/hello.wasm`; `bin/hello-opt.wasm`, after `wasm-opt -O`; `share/hello.map`, the link map | [nix/wasm.nix](nix/wasm.nix) |
| `lean-wasm-report`  | `report.txt`; the raw `wasm-objdump` output in `sections.txt`, `imports.txt`, `exports.txt` | [report.py](report.py) |

The check `lean-wasm-hello-runs` runs `hello.wasm` and `hello-opt.wasm` under wasmtime and
`lean --run Hello.lean` natively, and fails unless all three print the same.

## Pipeline

```
Hello.lean ──lean -c──▶ Hello.c ─┐
Init/*.lean ─lean -c──▶ Init/*.c ┼─clang (wasm32-wasip1)──▶ hello.wasm ──▶ report
Lean runtime (C++) ──────────────┘
```

Some Lean background:

- `lean -c` compiles a Lean module (one file) to C. The C needs Lean's runtime (`lean.h` and a
  C++ library) for reference-counted objects, arbitrary-precision numbers, IO and so on.
- `Init` is Lean's core library, which every Lean file imports implicitly (`Nat`, `List`,
  `String`, `IO`, ...). lean4 ships it compiled: `.olean` files, which the compiler reads for
  imports, and native libraries for the host. It does not ship Init's C, so
  [nix/lean-c.nix](nix/lean-c.nix) regenerates that from the Init sources that lean4 does ship.
  The generated C works for any target; it writes sizes as `sizeof(void*)` expressions, for
  example.
- Each module has an initializer, `initialize_<Module>`, which computes the module's top-level
  constants and calls the initializers of its imports. The `main` that Lean generates calls
  `initialize_Hello`, which first calls `lean_initialize_runtime_module()`.
- Lean evaluates closed terms such as `2 ^ 100` at compile time, so `Hello.c` would only contain
  the resulting string. That is why Hello.lean makes its numbers depend on the number of
  command-line arguments: this way the runtime computes them on WebAssembly.

The C compiler is the clang 21.1.8 of nixpkgs' `pkgsCross.wasi32`, with wasi-libc and libc++.
nixpkgs has no wasi-sdk, and this is its counterpart. [nix/wasm.nix](nix/wasm.nix) compiles the
Init C with the runtime's flags (`-O3`), archives it, and links:

```sh
$CC Hello.o libInit.a libleanrt.a -Wl,-z,stack-size=8388608 -Wl,--stack-first -lc++ -lc++abi \
  -Wl,-Map=hello.map -o hello.wasm
```

The link has to be complete: there is no `--allow-undefined`. wasm-ld drops unreferenced
functions and data by default (`--gc-sections` is on unless `-r` is given, see
[Driver.cpp](https://github.com/llvm/llvm-project/blob/main/lld/wasm/Driver.cpp)). Relinking the
same inputs by hand (in `nix develop .#lean-wasm-hello`) with `-Wl,--gc-sections` gave a
byte-identical module, and with `-Wl,--no-gc-sections` one of 8,617,485 bytes.

## Findings

### It runs

Under wasmtime, `hello.wasm` and `hello-opt.wasm` print exactly what `lean --run Hello.lean`
prints, including the bignums. On a 32-bit target, a `Nat` above 2^31 - 1 does not fit in a
pointer-sized scalar, so these go through the runtime's arbitrary-precision arithmetic.

### Recursion depth

Lean code keeps its locals in Wasm locals: none of the functions from Hello.lean or Init is a
stack user in the report. So its frames are on the engine's native stack, whose size the engine
sets: 512 KiB by default in wasmtime, and 5 MiB on the IC [6], which
`wasmtime run -W max-wasm-stack=5242880` sets as well. Native Lean has much more, as
`lean_run_main` runs `main` on a thread with a 1 GB stack on 64-bit platforms
([thread.cpp](https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/thread.cpp)). The
single-threaded runtime calls it on the stack it already has. So deep recursion fails much
sooner on WebAssembly. Of the depths 1,000, 2,000, 5,000, 10,000, ... up to 10,000,000, these
are the largest that worked:

| Probe                                   | 512 KiB |               5 MiB | 5 MiB, 64 KiB C stack | native     |
| --------------------------------------- | ------: | ------------------: | --------------------: | ---------: |
| `deep n`                                |  10,000 |             100,000 |               100,000 | 10,000,000 |
| `(countM n).run 0`                      |   5,000 |              50,000 |                50,000 | 10,000,000 |
| `toString (repr (List.range n))`        |   1,000 |              10,000 |                10,000 |  2,000,000 |
| `xs.zip xs`, where `xs := List.range n` |   2,000 |              20,000 |                20,000 | 10,000,000 |
| `deepK n id`                            |   1,000 |              10,000 |                10,000 | 10,000,000 |
| `deepKB n id`                           |   1,000 |              10,000 |                 2,000 |  5,000,000 |

```lean
def deep : Nat → Nat                -- plain recursion
  | 0 => 0
  | n + 1 => 1 + deep n

def countM : Nat → StateM Nat Unit  -- recursion in a monad
  | 0 => pure ()
  | n + 1 => do countM n; modify (· + 1)

def deepK : Nat → (Nat → Nat) → Nat -- recursion through closures
  | 0, k => k 0
  | n + 1, k => deepK n (fun r => k (r + 1))

-- deepKB is deepK with `k (2 ^ 70)` instead of `k 0`, so that every level adds bignums.
```

On WebAssembly, the next depth trapped with "call stack exhausted", except in the 64 KiB column
(see Stack under [Porting the runtime](#porting-the-runtime)). Natively, `repr` and `deepKB` ran
out of stack at the next depth ("Stack overflow detected. Aborting."). The other probes were
not tried deeper. The probes are one program, linked like `hello.wasm` (for the 64 KiB column,
without `-z stack-size`), and compiled natively with `leanc`. It is not part of the flake.

These are wasmtime's depths, with Cranelift's default optimizations. The IC compiles canisters
with them off, which allows more: in PocketIC, `repr` reached 20,000 and `zip` 50,000 of these
depths. lean-canister measures the exact depths in a derivation, in PocketIC and in wasmtime (see
[its Recursion depth](../lean-canister/README.md#recursion-depth)).

For a canister, this means that non-tail recursion can trap after some ten thousand levels,
also in Init functions such as `List.zip` and `repr`.

### `String.map` is quadratic on non-ASCII text

This is upstream Lean's behaviour, natively too, but it matters more under the IC's
instruction limits. `String.map`, and with it `String.toUpper` and `String.toLower`, writes
every character back with `String.Pos.set`. The runtime does that in place only if the string
is not shared and both the old and the new character are ASCII. Otherwise it copies the whole
string ([object.cpp](https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L2488),
which has a TODO about it). So on non-ASCII text, every character costs a copy of the string.
`toUpper`, measured by hand under wasmtime:

| Characters | ASCII (`a`–`z`) | non-ASCII (U+0100–U+01FF) |
| ---------: | --------------: | ------------------------: |
|     10,000 |            1 ms |                     12 ms |
|     20,000 |            1 ms |                     30 ms |
|     40,000 |            2 ms |                    100 ms |
|     80,000 |            3 ms |                    398 ms |

Natively (`lean --run`), the last case took 420 ms.

### The module, compared with the IC's limits

The report checks the limits that the IC checks when a module is installed (in
[validation.rs][validation]). These are the most relevant ones:

| hello.wasm                       | Value                                 | IC limit                                             |
| -------------------------------- | ------------------------------------- | ---------------------------------------------------- |
| module size                      | 1,999,514 bytes                       | 100 MiB [1]                                          |
| gzipped (the IC accepts gzip)    | 263,036 bytes                         | 2 MiB per `install_code` message; larger modules are uploaded in chunks [1, 3] |
| Code section                     | 1,519,291 bytes                       | 12 MiB [1, 4]                                        |
| defined functions                | 5,834                                 | 50,000 [1]                                           |
| most instructions in a function  | 5,399 (`lean_apply_1`)                | 1,000,000 [1, 4]                                     |
| highest complexity of a function | 55,513 (`lean_apply_1`)               | 1,000,000, with validation.rs's weights [4]          |
| most locals in a function        | 38                                    | 10,000 [4]                                           |
| initial memory                   | 131 pages, 8,585,216 bytes            | 4 GiB of Wasm heap on wasm32 [1]                     |
| imports                          | 14, all from `wasi_snapshot_preview1` | only functions of `ic0` [2, 4]                       |
| exports                          | `memory`, `_start`                    | the IC calls only `canister_*` entry points [2]      |

Everything is fine except the last two rows. The imports are `args_get`, `args_sizes_get`,
`environ_get`, `environ_sizes_get`, `clock_time_get`, `fd_close`, `fd_fdstat_get`,
`fd_prestat_get`, `fd_prestat_dir_name`, `fd_read`, `fd_seek`, `fd_write`, `proc_exit` and
`random_get`. The IC rejects any other import at install time [2, 4].

### Where the size comes from

From the link map (`share/hello.map`), as summarised in the report:

| Origin               | Code bytes | Functions | Object files |
| -------------------- | ---------: | --------: | -----------: |
| Lean's Init library  |  1,147,791 |     4,872 |          649 |
| libc++ and libc++abi |    161,183 |       535 |           21 |
| Lean runtime         |    146,418 |       250 |           16 |
| wasi-libc            |     55,349 |       154 |          111 |
| Hello.lean           |      8,421 |        21 |            1 |

Init accounts for 76% of the code. Code from every one of its 649 modules ends up in the
module, because `initialize_Init` runs the initializer of each one. Most of the libc++ code is
locale support (`locale.cpp`), which the runtime's use of iostreams pulls in. The name section
takes another 360,518 bytes. `wasm-opt -O` makes the module 1,343,969 bytes (204,270 gzipped),
partly by dropping that section. The optimized module has the same imports and exports.

### Wasm features

The module needs these proposals beyond the MVP: sign-extension, non-trapping float-to-int,
`memory.copy`/`memory.fill` (bulk-memory-opt) and the `call_indirect` encoding of reference
types (call-indirect-overlong). The IC accepts all of them. The module uses no SIMD, threads,
exception handling or tail calls, and `wasm-tools validate` accepts it with only the proposals
the IC accepts ([validation.rs][validation], [wasmtime's defaults][wasmtime-config], and the
replica's [wasmtime without threads][ic-cargo]).

These results come from validation, not from the `target_features` section. That section lists
what clang was allowed to use, which also includes multivalue, mutable-globals and all of
reference-types and bulk-memory. binaryen's `wasm-opt --print-features` only repeats that
section, and `--detect-features` does nothing in binaryen 132. So [report.py](report.py) finds
the proposals the module needs by validating it with `wasm-tools`, leaving out one proposal at a
time.

### Porting the runtime

Lean's runtime is C++. Its CMake build also builds Lean itself, so
[nix/runtime.nix](nix/runtime.nix) compiles the files directly, with the flags of upstream's
release build. The headers that compiled Lean code needs (`lean.h` and the generated `config.h`
and `version.h`) are a derivation of their own, `lean-wasm-runtime.headers`, so that a change to
the rest of the runtime does not recompile Init. The configuration is minimal:

- **Single-threaded**: no `LEAN_MULTI_THREAD`, as the IC has no threads ([wasmtime without
  threads][ic-cargo], [wasmtime's defaults][wasmtime-config]). So there is no task manager.
  Tasks (`Task.spawn`, `IO.asTask`) run synchronously, when they are created. `IO.Promise.new`,
  and with it `IO.CancelToken.new`, needs the task manager: it ends the program with exit code 1
  and "INTERNAL PANIC: `IO.Promise.new` called before the task manager is running", a message
  that goes on to blame an `initialize` block. `IO.sleep` returns at once, without an error, as
  the single-threaded `sleep_for` does nothing (`thread.h`).
- **No GMP**: Lean's own bignum code (`mpz.cpp`, `mpn.cpp`) is used instead.
- **No mimalloc, no mmap**: `config.h` is lean4's, minus `LEAN_MIMALLOC`, so Lean objects come
  from wasi-libc's `malloc`.
- **Left out**: `process.cpp` (WASI has no processes), `stack_overflow.cpp` (no signals),
  `libuv.cpp` and `uv/*.cpp` (no libuv), `openssl.cpp` (no OpenSSL) and `compact.cpp` (needs
  mmap; Init does not use it). The other 21 runtime files are built.
- **[runtime/wasi-stubs.cpp](runtime/wasi-stubs.cpp)** defines what Init needs from the left-out
  files. Spawning a process returns an "unsupported operation" IO error, the process ID is 0,
  `flock` fails with `ENOSYS`, and getting and setting the current directory work.
- **[runtime/uv.h](runtime/uv.h)** stands in for libuv's header, which `io.cpp` includes. It
  provides libuv's error codes and a few synchronous file system calls. Temporary files and
  directories are unsupported.
- **[runtime/lean.h.patch](runtime/lean.h.patch)**: `lean.h` uses the 32-bit form of
  `LEAN_SCALAR_PTR_LITERAL` only on Emscripten, but every 32-bit target needs it. The 64-bit form
  puts the 8 bytes of a scalar field of a static object into a single pointer, which has only 4
  bytes on wasm32. So the object comes out a slot short and the field loses half its bytes,
  without a warning from clang, even with `-Wall -Wextra`. This corrupts, for example, the
  hashes in name literals. It is worth reporting upstream.
- **[runtime/wasi.patch](runtime/wasi.patch)** has 16 small hunks. Two of them matter beyond
  making the build work:
  - `IO.getRandomBytes` uses `getentropy` (WASI's `random_get`). WASI has no `/dev/urandom`,
    and Init calls this function at startup.
  - `createTempFile` and `createTempDir` lose a parameter that Lean's declarations do not have.
    On WebAssembly such a signature mismatch makes wasm-ld substitute a stub that traps.
- **C++ exceptions**: the runtime throws in a few places, for example when the stack or heap
  runs out. The IC rejects Wasm exception handling [4], so the runtime is compiled with
  `-fexceptions` but without `-fwasm-exceptions`, and LLVM drops all `catch` blocks. nixpkgs'
  libc++abi for WASI has no exception support, so the stubs define `__cxa_throw`. It prints the
  exception and aborts, which traps. On the IC a trap discards the changes of the message [2].
  Lean's IO errors are ordinary values, not C++ exceptions, so they are not affected.
- **Stack**: the C stack in linear memory only holds the frames of stack users, 268 functions
  in the report. Among them are the runtime's bignum functions and `lean_apply_1` to
  `lean_apply_16`, through which Lean calls closures, with 16 to 64 bytes per call. So recursion
  through closures uses this stack a little at every level. wasm-ld's default of 64 KiB is too
  small for that: in the 64 KiB column above, `deepKB` trapped with "out of bounds memory access"
  at depth 5,000. The link uses 8 MiB, which is what Lean gives threads on 32-bit targets. With
  it, and also with 1 MiB, the engine's stack ran out first. `--stack-first` puts the stack at
  the bottom of memory, so that an overflow traps instead of overwriting data. The stack is 128
  of the 131 initial pages.

## Open questions and next steps

[lean-canister](../lean-canister) has since taken steps 1, 2, 3 and 5. Of step 9, it tried the
Wasm memory between messages and across an upgrade, but not stable memory or `opt keep`.

1. **Replace WASI with `ic0`.** The usual route for C and C++ is
   [ic-wasi-polyfill](https://github.com/wasm-forge/ic-wasi-polyfill), which implements WASI on
   top of the System API, plus [wasi2ic](https://github.com/wasm-forge/wasi2ic), which rewrites
   the imports. [icpp-pro](https://github.com/icppWorld/icpp-pro) and
   [llama_cpp_canister](https://github.com/onicai/llama_cpp_canister) work that way. The
   polyfill supports only wasm32. With only 14 imports, a small shim of our own would also
   work: `fd_write` would map to `ic0.debug_print`, `clock_time_get` to `ic0.time`, `proc_exit`
   to `ic0.trap` [2], and `random_get` to a seeded generator, while the arguments and the
   environment would be empty. A runtime without WASI at all would be a third option.
   lean-canister has such a shim: 12 WASI functions on top of `ic0`.
2. **Canister entry points.** Lean's `@[export name]` gives a function a fixed C name. A small C
   file can export it under the name the IC expects, for example with
   `__attribute__((export_name("canister_query greet")))`. In the other direction, `@[extern]`
   declares C functions to Lean, so it can declare `ic0` functions that are imported with
   `import_module("ic0")` [2]. lean-canister does both.
3. **Link as a reactor, initialize in `canister_init`.** `hello.wasm` is a WASI command: its
   `_start` runs the C++ constructors, `main` and the destructors, and the IC never calls it.
   Linked with `-mexec-model=reactor` there is no `main`, and `_initialize` runs the
   constructors; [wasi2ic](https://github.com/wasm-forge/wasi2ic) makes that the Wasm start
   function. Lean's own initialization (`lean_initialize_runtime_module()`,
   `initialize_<Module>(1)`, `lean_io_mark_end_initialization()`) then belongs in
   `canister_init` and `canister_post_upgrade`, not in the start function, where most of the
   System API traps [2]. Init reads random bytes during initialization, so a polyfill's
   generator must be seeded before that. lean-canister links without crt1 (`-nostartfiles`)
   instead, and runs the constructors and Lean's initialization in `canister_init` and
   `canister_post_upgrade`.
4. **Asynchronous calls.** A canister calls other canisters asynchronously: the reply arrives in
   a later message, through a callback [2]. `IO.Promise` would be the obvious way to model that
   in Lean, but this runtime has no task manager, so it panics (see [Porting the
   runtime](#porting-the-runtime)). The CDK needs another mechanism, or a task manager that does
   not need threads.
5. **Measure execution.** How many instructions does initialization take? An install may use
   300 billion and an update call 40 billion [1].
   [PocketIC](https://docs.internetcomputer.org/guides/testing/pocket-ic.md) runs an IC replica
   locally, which makes it the place to measure, and to confirm the recursion depths above,
   which come from wasmtime with the IC's stack size. In lean-canister, `canister_init` takes
   7.5 million instructions and the install 6.3 billion, and PocketIC allows more depth than
   the table above (see [Recursion depth](#recursion-depth)).
6. **Size.** Size is not a blocker, but Init's initializers keep 1.1 MB of Init in even a hello
   world. A file that starts with `prelude` does not import Init implicitly, and can import just
   the Init modules it needs; whether that helps is untested. Std and Lean code that needs libuv
   (timers, sockets), OpenSSL or compacted regions does not link yet.
7. **Traps.** Any C++ `throw` traps, including ones that native Lean reports gracefully. So does
   running out of stack, at depths that native Lean handles easily (see [Recursion
   depth](#recursion-depth)). On a trap, output still buffered in stdout is lost.
8. **32 bits.** A WASI-based canister is wasm32-only. wasi-sdk has no wasm64 target
   ([wasi-sdk](https://github.com/WebAssembly/wasi-sdk)) and the polyfill supports only wasm32,
   although the IC supports wasm64 with a 6 GiB heap [1]. On wasm32, `USize` is 32 bits and
   naturals above 2^31 - 1 are bignums.
9. **State.** The Lean heap lives in Wasm memory. The IC keeps that memory between messages but
   discards it on upgrade, unless `wasm_memory_persistence` is `opt keep` [2]. Anything that has
   to survive upgrades needs stable memory. lean-canister keeps state in an `IO.Ref`: an update's
   changes stay, unless it traps, and a query's are discarded
   ([State across updates](../lean-canister/README.md#state-across-updates)). `opt keep` needs a
   module with the custom section `icp:private enhanced-orthogonal-persistence`
   ([its next steps](../lean-canister/README.md#open-questions-and-next-steps)).

## Sources

The IC's limits are those of replica `release-2026-10-08_03-33-base`. On 2026-10-17 the cited
code on `master` was the same. `report.txt` uses the same numbering.

1. https://docs.internetcomputer.org/references/resource-limits.md
2. https://docs.internetcomputer.org/references/ic-interface-spec/canister-interface.md
3. https://docs.internetcomputer.org/guides/canister-management/large-wasm.md
4. https://github.com/dfinity/ic/blob/master/rs/embedders/src/wasm_utils/validation.rs
5. https://github.com/dfinity/ic/blob/master/rs/config/src/embedders.rs
6. https://github.com/dfinity/ic/blob/master/rs/embedders/src/lib.rs
7. https://github.com/dfinity/ic/blob/master/rs/limits/src/lib.rs
8. https://github.com/dfinity/ic/blob/master/rs/types/types/src/lib.rs
9. https://github.com/dfinity/ic/blob/master/Cargo.toml
10. https://github.com/bytecodealliance/wasmtime/blob/v48.0.1/crates/wasmtime/src/config.rs

[validation]: https://github.com/dfinity/ic/blob/master/rs/embedders/src/wasm_utils/validation.rs
[ic-cargo]: https://github.com/dfinity/ic/blob/master/Cargo.toml
[wasmtime-config]: https://github.com/bytecodealliance/wasmtime/blob/v48.0.1/crates/wasmtime/src/config.rs
