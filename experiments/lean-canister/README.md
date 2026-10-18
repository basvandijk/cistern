# Experiment: a Lean canister

**Question.** The [lean-wasm](../lean-wasm) experiment compiled Lean to WebAssembly, with WASI as
its system interface. What does it take to run that code as an Internet Computer (IC) canister,
and how many instructions does it use?

**Answer so far.** It runs, well within the IC's limits, except where the Lean code is quadratic
or recurses deeply. [Canister.lean](Canister.lean), which imports
lean-wasm's [Hello.lean](../lean-wasm/Hello.lean), compiles to a module that imports nothing but the
IC's System API (`ic0`). A small C file implements the 12 WASI functions that the code needs on
top of `ic0`. In PocketIC, a local IC replica, the module installs, upgrades and answers queries.
Its `hello` query replies exactly what `lean --run Hello.lean` prints. With the IC's production
limits:

- Installing takes 6.3 billion instructions of the 300 billion that an install may use, nearly
  all of them for compiling the module. Lean's initialization in `canister_init` takes 7.5 million.
- A query takes at least 0.4 million instructions of the 5 billion that it may use. Memory counts
  too: the IC charges 80,000 instructions for each 64 KiB page of memory that a message touches.
- The 5 MiB Wasm stack allows 16,378 to 109,198 levels of recursion for lean-wasm's probes. That is
  as much as wasmtime allows with the same stack and Cranelift's optimizations off, and up to 29%
  more than with its default optimizations, which lean-wasm's estimates used.
- On non-ASCII text, `String.toUpper` takes about 4n² instructions for n characters, as Lean's
  `String.map` is quadratic on such text. A query that builds a string of 34,965 such characters
  and upper-cases it exceeds the limit of a query. On ASCII text `toUpper` takes 177 instructions
  per character.

The measurements come from the report of `lean-canister-report`, built on x86_64-linux, the
depths in wasmtime included. The exceptions are the modules' imports and exports, which
wasm-objdump lists, the 12 WASI functions that the link keeps, which its map lists
(`share/canister.map`), and what is quoted from lean-wasm. The IC's costs and limits come from
its source (see [Sources](#sources)). Every step is a Nix derivation that builds in the sandbox.
PocketIC and wasmtime are deterministic, so `nix build --rebuild` reproduces the report bit for
bit, as it does the modules.

## Running it

```sh
nix build .#lean-canister-report && cat result/report.txt   # the measurements, see below
nix flake check                                             # also builds the report
```

By hand, in the dev shell, which has `pocket-ic`, `wasmtime`, `lean`, and `python3` with
pocketic-py:

```sh
nix develop
c=$(nix build .#lean-canister-c --no-link --print-out-paths)
wasm=$(nix build .#lean-canister-wasm --no-link --print-out-paths)/bin
lean --run experiments/lean-wasm/Hello.lean > hello.txt
lean --run experiments/lean-wasm/Hello.lean a b > hello-a-b.txt
LEAN_PATH=$c/olean python3 experiments/lean-canister/measure.py \
  --hello hello.txt --hello-a-b hello-a-b.txt --run-probe $wasm/run-probe.wasm \
  --native "lean --run experiments/lean-canister/RunProbe.lean" $wasm/canister.wasm
```

Each step is a flake package:

| Attribute              | Output                                                                     | Built by                                                   |
| ---------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `lean-canister-c`      | `Hello.c`, `Ic0.c`, `Probes.c`, `Canister.c` and `RunProbe.c`; `olean/`, the modules for `lean --run` | [nix/lean-c.nix](nix/lean-c.nix) |
| `lean-canister-wasm`   | `bin/canister.wasm`; `bin/canister-opt.wasm`, after `wasm-opt -O`; `bin/run-probe.wasm`; `share/canister.map`, the link map | [nix/wasm.nix](nix/wasm.nix) |
| `lean-canister-report` | `report.txt`; `measurements.json`, everything that was measured            | [nix/measure.nix](nix/measure.nix), [measure.py](measure.py) |

The check `lean-canister-runs` is the report. It fails to build if a module does not install, if
`greet` or `hello` replies wrongly, or if a probe's result is wrong. measure.py computes the
results, all but `repr`'s, which it takes from RunProbe.lean, run natively. The report and the
check exist on
x86_64-linux and aarch64-darwin, the systems for which ic-nix has PocketIC (see
[nix/pocket-ic.nix](../../nix/pocket-ic.nix)).

## How it works

```
Hello, Ic0, Probes, Canister.lean ──lean -c──▶ *.c ──┐
c/*.c: WASI on ic0, the Lean bindings, entry points ──┼─clang (wasm32)──▶ canister.wasm
Init and the Lean runtime, from lean-wasm ────────────┘

Probes.lean, RunProbe.lean, the same way, but a WASI program ──▶ run-probe.wasm

canister.wasm in PocketIC ──────────┐
run-probe.wasm under wasmtime ──────┼──measure.py──▶ report
RunProbe.lean natively (lean --run) ┘
```

- [Canister.lean](Canister.lean) is the canister's Lean code, with three query methods. `greet`
  replies `Hello, <argument>!`. `hello` runs Hello.lean's `main`, with the words of the argument as
  its command-line arguments, and replies with what it prints, which `IO.FS.withIsolatedStreams`
  captures. `probe` runs the probes of [Findings](#findings). Arguments and replies are UTF-8 text,
  not Candid.
- [Probes.lean](Probes.lean) has the probes. [RunProbe.lean](RunProbe.lean) runs them as a
  program, for comparison: compiled like lean-wasm's `hello.wasm` and run under wasmtime, and
  natively.
- [Ic0.lean](Ic0.lean) declares the System API functions that Canister.lean uses as `@[extern]`
  functions, which [c/ic0.c](c/ic0.c) implements. Where the System API takes an address and a
  size, they take a `ByteArray` or a `String`.
- [c/canister.c](c/canister.c) has the entry points that the module exports. `canister_init`, and
  `canister_post_upgrade`, as an upgrade starts with new memory, do what a Lean program does
  before its `main`. They run the C++ constructors (`__wasm_call_ctors`), as crt1's `_start`
  would, and then, as Lean's generated `main` does, `initialize_Canister(1)`, which calls
  `lean_initialize_runtime_module()` and the initializers of the imported modules, and
  `lean_io_mark_end_initialization()`. Each `canister_query <name>` calls a function that
  Canister.lean exports with `@[export]`. Those catch Lean's errors and reject the message with
  them, so a query replies or rejects.
- [c/wasi.c](c/wasi.c) implements WASI on top of the System API, see below.
- [nix/wasm.nix](nix/wasm.nix) compiles and links as lean-wasm does, with three more flags.
  `-nostartfiles` leaves out crt1, whose `_start` (or `_initialize`) the IC would not call;
  `canister_init` runs the constructors instead, and as it calls `__wasm_call_ctors`, wasm-ld does
  not make every export run them too ([Writer.cpp][lld-writer]). `-Wl,--no-entry` keeps just the
  exports, and `-Wl,--fatal-warnings` is explained below. After the link, the build fails if the
  module imports anything that is not from `ic0`. It also links `run-probe.wasm`.
- [measure.py](measure.py) creates the canisters, installs the modules and calls them with
  [pocketic-py][pocketic-py], PocketIC's Python library, whose Candid comes from
  [ic-py][ic-py] ([nix/pocket-ic-py.nix](../../nix/pocket-ic-py.nix)). It starts the PocketIC
  server itself, with its output, which has the canisters' logs and the replica's, in files;
  pocketic-py finds that server by its port file. pocketic-py's `install_code` only installs, so
  measure.py makes both `install_code` calls, the install and the upgrade, itself: it encodes the
  argument with ic-py, and sends it with pocketic-py's `update_call_with_effective_principal`. It
  also runs `run-probe.wasm` under wasmtime, and RunProbe.lean natively.

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
| `proc_exit`                             | `ic0.trap`, with `exit(<code>)` and the last line of stderr that is not empty     |
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

### Measuring

- `ic0.performance_counter(0)` is the number of instructions that the current message has
  executed, as the IC counts them for its limits ([interface specification][spec]). It includes
  what the IC charges for the System API, for example 500 instructions for each `ic0.time`
  ([system_api_complexity.rs][complexity]), and for memory. The first access of a message to a
  64 KiB page costs 80,000 instructions, 5,000 for each of its 16 OS pages, and in an update or
  `canister_init` the first write to it as much again ([deterministic.rs][tracker],
  [subnet_config.rs][subnet-config]). canbench, DFINITY's tool for benchmarking canisters, also
  counts this way, in PocketIC queries.
- `Ic0.countInstructions f a` reads the counter before and after it applies `f` to `a`. It is
  written in C because Lean's compiler moves pure code, and could have moved `f a` past the
  second read. For the same reason a probe gets its input as a value. Lean's compiler turned
  `fun n => let xs := List.range n; fun _ => ...` into one function of two arguments, which built
  the input in the measured part.
- Each entry point ends by logging its instructions, as in `canister_query greet: 409614
  instructions, 0 ic0.time calls`. PocketIC prints the canister's log on its standard error,
  where measure.py reads it. The count cannot include the logging itself: for `canister_init`,
  the replica counts 12,812 instructions more. The replica logs what each `install_code` took.
- The replica answers a query that it has answered before from a cache, without running it
  ([query_cache.rs][query-cache]). So each query has an argument of its own.
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
| `canister.wasm`     | 2,077,066 | 281,864 |
| `canister-opt.wasm` | 1,405,756 | 221,085 |

The modules import 9 functions, all from `ic0`. They export `canister_init`,
`canister_post_upgrade`, `canister_query greet`, `canister_query hello`, `canister_query probe` and
their memory. An ingress message may have at most 2 MiB ([resource limits][limits]). The
`install_code` message with canister.wasm would just fit; gzipped, which the IC accepts
([interface specification][spec]), the module fits with room to spare, and so measure.py installs
both. In PocketIC:

- `greet "world"` replies `Hello, world!`, and its `IO.println` reaches the canister's log.
- `hello` and `hello "a b"` reply the six lines that `lean --run Hello.lean` prints, with
  `2^102` and `2^33 + 1` for the latter. Bignums work as natively.
- An argument that is not UTF-8, and an unknown probe, are rejected with the error that Lean
  throws: `the argument is not UTF-8`, `there is no probe nosuch`.
- After an upgrade to the same module, which runs `canister_post_upgrade`, `greet` still works.

### Installation

| Instructions                        | canister.wasm | canister-opt.wasm |
| ----------------------------------- | ------------: | ----------------: |
| `install_code`                      | 6,331,322,797 |     5,812,513,427 |
| `canister_init`                     |     7,529,985 |         7,126,746 |
| of which C++ constructors           |       413,842 |           412,854 |
| of which the Lean runtime           |        11,854 |            11,280 |
| of which the modules' initializers  |     7,017,672 |         6,616,208 |
| `install_code` of an upgrade        |    90,581,030 |        84,993,602 |

`install_code` is the replica's count for the whole message. `canister_init` is the counter at
the end of `canister_init`, and `canister_post_upgrade` takes as many instructions.

- Compiling takes most of the install. The IC charges 20 million instructions for it, plus 6,000
  for each instruction of the module after it has instrumented the module for counting
  ([embedders.rs][embedders], [instrumentation.rs][instrumentation]). For canister.wasm that is
  (6,331,322,797 - 7,542,797 - 20,000,000) / 6,000 = 1,050,630 instructions, where 7,542,797 is
  the replica's count of `canister_init`. For a module that the subnet has installed since its
  last checkpoint, the 6,000 drop to 60 ([execution_environment.rs][compiled]), but the 20
  million remain ([hypervisor.rs][hypervisor]). A successful `install_code` records its module
  ([execution_environment.rs][compiled-wasms-insert]), which the next one looks up
  ([execution_environment.rs][compiled-wasms]), and a checkpoint forgets them
  ([scheduler.rs][checkpoint]). So the upgrade took 7,543,230 for `canister_post_upgrade` +
  20,000,000 + 60 × 1,050,630 = 90,581,030. An install may use 300
  billion instructions ([subnet_config.rs][subnet-config]), so this one uses 2%.
- The IC charges the instructions of an `install_code` to the canister, and refuses the next one
  (`CanisterInstallCodeRateLimited`) until the rounds have paid them off, at 2 billion at the
  end of every round, the install's own round included ([install_code.rs][install-code],
  [subnet_config.rs][subnet-config]). The credit comes at the end of the round
  ([round_schedule.rs][round-end], [round_schedule.rs][round-schedule]) to the canisters in the
  subnet's schedule. `install_code` puts the canister there when it puts it back with its debit
  ([replicated_state.rs][subnet-schedule]), and it stays there as long as it has a debit, also in
  a round in which it has nothing to execute ([canister_state.rs][must-be-in-schedule],
  [round_schedule.rs][schedule-retain]). So the IC refused the upgrade in the 3 rounds after
  the install, and accepted it in the 4th (canister-opt.wasm: in 2 rounds, and in the 3rd). In
  PocketIC, each try took a round, and so did the upgrade.
- `canister_init` made 2,691 `ic0.time` calls, which cost at least 2,691 × 500 = 1,345,500
  instructions, 18% of it. They come from Lean's lazily initialized constants (closed terms). The
  first use of one takes a lock with `std::atomic<int>::wait` ([object.cpp][lean-once]), and
  libc++'s wait reads the clock before it first looks at the lock ([poll_with_backoff.h][libcxx]).
  That is `clock_time_get`, which c/wasi.c answers with `ic0.time`. A runtime without threads
  does not need the wait.

### Queries

| Instructions of the query                 | canister.wasm | canister-opt.wasm |
| ----------------------------------------- | ------------: | ----------------: |
| `greet "world"`                           |       409,614 |           409,254 |
| `hello ""`                                |       915,871 |           889,241 |
| `hello "a b"`                             |       967,287 |           937,760 |
| `probe "noop 0"`: no work, 286 measured   |       428,012 |           426,623 |

These are the counts that the entry point logs, so they leave out the logging (see
[Measuring](#measuring)). The measured work of the `noop` probe takes 286 instructions. The rest
of its query goes to the entry point, to reading and parsing the argument, to the reply, and to
the charges for the memory that these touch. How it divides was not measured;
[Memory pages](#memory-pages) shows the charges in the probes. Each `hello` query also makes 12
`ic0.time` calls: it initializes 12 closed terms, which the next query initializes again, as the
IC discards the changes that a query makes to memory ([abstract behavior][abstract]).

### Recursion depth

The largest depth that worked, for the probes of lean-wasm (see
[its README](../lean-wasm/README.md#recursion-depth)), with a 5 MiB Wasm stack:

| Probe                                   | lean-wasm | wasmtime | wasmtime, opt-level 0 | PocketIC | PocketIC, canister-opt.wasm |
| --------------------------------------- | ------: | ------: | ------: | ------: | ------: |
| `deep n`                                | 100,000 | 109,203 | 109,205 | 109,198 | 109,203 |
| `(countM n).run 0`                      |  50,000 |  65,519 |  81,902 |  81,896 |  81,899 |
| `toString (repr (List.range n))`        |  10,000 |  18,196 |  23,396 |  23,394 |  23,396 |
| `xs.zip xs`, where `xs := List.range n` |  20,000 |  46,800 |  54,602 |  54,598 |  46,800 |
| `deepK n id`                            |  10,000 |  15,599 |  16,379 |  16,378 |  16,379 |
| `deepKB n id`                           |  10,000 |  15,599 |  16,379 |  16,378 |  16,379 |

lean-wasm tried only the depths 1,000, 2,000, 5,000, 10,000, and so on, under wasmtime with its
default optimizations. The other columns come from the report, by bisection. In PocketIC, the
next depth failed with "Canister trapped: stack overflow"; under wasmtime, `run-probe.wasm` ran
out of stack ("call stack exhausted"). The IC compiles canisters with Cranelift's optimizations
off ([validation.rs][validation], [wasmtime_embedder.rs][execution-config]), and PocketIC's
depths come within 7 levels of wasmtime's then.
So the code that the IC adds to count instructions hardly costs depth. With its default
optimizations, which lean-wasm used, wasmtime allows up to 22% less (`repr`; `countM` 20%). After
`wasm-opt -O`, the depth of `zip` drops to 46,800, as much as wasmtime allows with its
optimizations.

### Instructions of Lean code

The work of each probe, in a query of its own, at the largest size that worked of those that
measure.py tries: the 1-2-5 series, and for `toUpper` 10,000, 20,000, 40,000 and so on up to
1,280,000, where ASCII text did not fail (canister.wasm):

| Probe                           | Size          |    Instructions | Per level or element |
| ------------------------------- | ------------- | --------------: | -------------------: |
| `deep n`                        | 100,000       |       5,800,307 |                   58 |
| `(countM n).run 0`              | 50,000        |       4,450,650 |                   89 |
| `deepK n id`                    | 10,000        |       5,991,717 |                  599 |
| `xs.zip xs`                     | 50,000        |      48,345,824 |                  967 |
| `deepKB n id`                   | 10,000        |      33,836,033 |                3,384 |
| `toString (repr xs)`            | 20,000        |     391,666,350 |               19,583 |
| `s.toUpper`, ASCII              | 1,280,000     |     226,561,682 |                  177 |
| `s.toUpper`, U+0100–U+01FF      | 20,000        |   1,634,480,250 |               81,724 |

Preparing the input is not counted: `List.range n` for `repr` and `zip`, and the string for
`toUpper`. Building the string costs more than upper-casing it in ASCII: its query takes
1,942,442,305 instructions in all.

### `String.map` exceeds the limit of a query

On non-ASCII text, Lean's `String.map`, and with it `toUpper`, copies the whole string for every
character (see [lean-wasm's README](../lean-wasm/README.md#stringmap-is-quadratic-on-non-ascii-text)),
twice ([object.cpp][lean-utf8-set]). With 2 bytes per character in UTF-8 and an instruction per
byte that `memory.copy` copies ([instrumentation.rs][instrumentation]), that is about 4n²
instructions for n characters: 1.6 billion for 20,000, as measured (1,634,480,250). By 4n², the
limit of 5 billion instructions for a query would allow about 35,000 characters (35,355).
Bisection found that `toUpper` worked at 34,964 and failed at 34,965: the query does more that
grows with the string, such as building it. lean-wasm timed 40,000 characters at 100 ms under
wasmtime. An update may use 40 billion instructions ([subnet_config.rs][subnet-config]),
which by 4n² would allow about 100,000 characters (not measured).

### Memory pages

Each probe also ran twice in one query. The second run costs less where the first touched new
memory pages or initialized closed terms, which the second finds ready (canister.wasm):

| Probe                   |  First run | Second run | Difference |
| ----------------------- | ---------: | ---------: | ---------: |
| `deep 1,000`            |     58,307 |     58,307 |          0 |
| `zip 1,000`             |    968,864 |    888,344 |     80,520 |
| `repr 1,000`            | 18,896,168 | 18,645,244 |    250,924 |
| `deepKB 1,000`          |  3,271,357 |  3,164,851 |    106,506 |
| `toUpper 10,000`        |  1,771,682 |  1,771,682 |          0 |

`deep` uses only the Wasm stack, which is not memory that the IC charges for. For `zip`, the
difference is about the charge for one page. The counts of a first run therefore depend on where
in memory the allocator places objects: `deepKB 1,000` took 3,369,313 instructions in a query of
its own, and 3,271,357 here.

### wasm-opt

`wasm-opt -O` makes the module 32% smaller, and 22% gzipped. The install takes 8% fewer
instructions, as there are fewer to compile; `canister_init` 5% fewer, the queries up to 3% and
the probes up to 6% fewer. The depth of `zip` drops by 14%.

## Open questions and next steps

1. **Candid.** Arguments and replies are text. Canisters speak Candid, so the CDK needs a Candid
   library in Lean, and a way to generate a method's decoding and encoding from its type.
2. **Updates and state.** This canister has only queries. A value that `canister_init` stores in
   an `IO.Ref` (`initialize` in Lean) should persist across update calls, as the IC keeps a
   canister's memory between messages, but not across upgrades, which start with new memory. That
   is untested, as is stable memory, which upgrades keep.
3. **Closed terms in queries.** A closed term that a query initializes is initialized again in every
   query (see [Queries](#queries)). One that `canister_init` or an update initializes stays. So
   it could pay to initialize them early, for example by running the code of each query once in
   `canister_init`, without replying.
4. **The clock reads.** 18% of `canister_init` goes to reading the clock for locks that a runtime
   without threads does not need (see [Installation](#installation)). Patching the runtime's
   `lock_simple_atomic`, or caching `ic0.time` per message in c/wasi.c, would save that.
5. **Randomness and asynchronous calls.** `random_get` gives the same bytes in every canister. Real
   randomness comes from `raw_rand`, which, like any call to another canister, replies in a
   later message. As lean-wasm found, `IO.Promise` does not work without a task manager.
6. **Memory charges.** A query that does nothing takes 0.4 million instructions. How much of
   that is the charge for memory pages was not measured; reading `ic0.performance_counter` at
   points within a query would show it. The counts of Lean code depend on where objects lie. The
   runtime allocates every object with wasi-libc's `malloc`; an allocator that keeps a message's
   objects on fewer pages could take fewer instructions.
7. **Compilation.** Compiling takes 6,000 instructions per instruction of the module, 6.3 billion
   for this one. Init accounts for most of the code (see lean-wasm), and a module that imports
   less of it would install for less. Installing the module again, in an upgrade, a reinstall or
   another canister, costs 20 million plus a hundredth of the rest, 83 million, but only until
   the subnet's next checkpoint.
8. **Mainnet.** On the IC, `ic0.debug_print` adds to the canister's log, which keeps 4 KiB by
   default, and the replica prints nothing. A non-replicated query's log is discarded. So the
   instruction counts that the entry points log are a PocketIC convenience.
9. **macOS.** The report on aarch64-darwin is untested, and its page charges would differ (see
   [Measuring](#measuring)), as may its depths under wasmtime.

## Sources

The IC's code is that of PocketIC 16.0.0: commit 0ec627118654351acff526328b01c8395d7de414, the
tag `release-2026-09-25_03-28--all-in-one`, from which ic-nix's release 20261009 builds it. The
limits, costs and rules cited here are the same in `release-2026-10-08_03-33-base`, which
lean-wasm cites.

1. [Resource limits][limits]
2. [The canister interface][spec]
3. [The abstract behavior][abstract]: a query's changes are discarded
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
11. [deterministic.rs][tracker]: the charge for memory pages
12. [system_api_complexity.rs][complexity]: the charges for System API functions
13. [validation.rs][validation] and [wasmtime_embedder.rs][execution-config]: wasmtime's
    configuration
14. [lib.rs][embedders-lib]: the Wasm stack
15. [Cargo.toml][ic-cargo]: the IC's wasmtime
16. [query_cache.rs][query-cache]: the query cache
17. [rs/sys][sys]: the OS page size
18. [__wasilibc_real.c][wasilibc]: wasi-libc's WASI imports (wasi-sdk-32)
19. [Writer.cpp][lld-writer], [Relocations.cpp][lld-relocations] and
    [SymbolTable.cpp][lld-symboltable]: wasm-ld (LLVM 21.1.8)
20. [object.cpp][lean-once]: Lean's closed terms (Lean 4.34.1)
21. [poll_with_backoff.h][libcxx]: libc++'s waiting (LLVM 21.1.8)
22. [pocketic-py][pocketic-py] 3.1.2 and [ic-py][ic-py] 1.0.1: PocketIC's Python library, and the
    Candid that it uses

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
[tracker]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/memory_tracker/src/deterministic.rs#L317-L362
[complexity]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasmtime_embedder/system_api_complexity.rs
[validation]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasm_utils/validation.rs#L1733-L1786
[execution-config]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/wasmtime_embedder.rs#L265-L296
[embedders-lib]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/embedders/src/lib.rs#L28-L29
[ic-cargo]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/Cargo.toml#L1024
[query-cache]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/execution_environment/src/query_handler/query_cache.rs
[sys]: https://github.com/dfinity/ic/blob/0ec627118654351acff526328b01c8395d7de414/rs/sys/src/lib.rs#L30-L37
[wasilibc]: https://github.com/WebAssembly/wasi-libc/blob/wasi-sdk-32/libc-bottom-half/sources/__wasilibc_real.c
[lld-writer]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/lld/wasm/Writer.cpp
[lld-relocations]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/lld/wasm/Relocations.cpp
[lld-symboltable]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/lld/wasm/SymbolTable.cpp
[lean-once]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L2892-L2916
[lean-utf8-set]: https://github.com/leanprover/lean4/blob/v4.34.1/src/runtime/object.cpp#L2488-L2513
[libcxx]: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/libcxx/include/__thread/poll_with_backoff.h#L36-L41
[pocketic-py]: https://github.com/dfinity/pocketic-py
[ic-py]: https://github.com/rocklabs-io/ic-py
