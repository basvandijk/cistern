# Compiles the canister for wasm32 and links it, with WASI implemented on ic0. Also links the
# probes as a WASI program, run-probe.wasm, for wasmtime.
#
# Interface (used by ../default.nix):
#   A derivation with $out/bin/canister.wasm, $out/bin/canister-opt.wasm (the same after
#   `wasm-opt -O`), $out/bin/run-probe.wasm and $out/share/canister.map (the linker's map of
#   canister.wasm).
#
# The Lean runtime and Init are those of the lean-wasm experiment, which are built for
# wasm32-wasip1. Everything is compiled with the runtime's flags; the files in ../c also with
# warnings as errors.
{
  lib,
  binaryen,
  wabt,
  wasi,
  runtime,
  init,
  canisterC,
}:
let
  cflags = lib.escapeShellArgs runtime.cflags;
  ldflags = lib.escapeShellArgs runtime.ldflags;
in
wasi.runCommandCC "lean-canister"
  {
    nativeBuildInputs = [
      binaryen
      wabt
    ];
  }
  ''
    # Two directories, as Ic0.c and Canister.c differ from ic0.c and canister.c only in case.
    mkdir lean c
    for module in Hello Ic0 Probes Canister RunProbe; do
      $CC ${cflags} -c ${canisterC}/$module.c -o lean/$module.o
    done
    for file in ic0 wasi canister; do
      $CC ${cflags} -Wall -Wextra -Werror -c ${../c}/$file.c -o c/$file.o
    done

    # Without crt1 (-nostartfiles), which would export _start, or _initialize with
    # -mexec-model=reactor: the IC calls neither. canister.c's canister_init runs the C++
    # constructors instead. --no-entry: the exports are those of canister.c (and the memory).
    # --fatal-warnings: wasm-ld only warns about a WASI function in wasi.c with the wrong type.
    $CC lean/{Hello,Ic0,Probes,Canister}.o c/*.o ${init}/lib/libInit.a ${runtime}/lib/libleanrt.a \
      ${ldflags} -nostartfiles -Wl,--no-entry -Wl,--fatal-warnings -Wl,-Map=canister.map \
      -o canister.wasm

    # A function that is declared as a Wasm import, such as a WASI function that wasi.c lacks,
    # becomes an import if no object file defines it, without an error from wasm-ld. The IC
    # installs a module only if all its imports are from ic0. wasm-objdump runs on its own line,
    # so that the build fails if it does, and the grep -q fails it if the listing has no ic0
    # imports at all, as when its format changes.
    wasm-objdump -x -j Import canister.wasm > imports.txt
    grep -q ' <- ic0\.' imports.txt
    if grep '^ - ' imports.txt | grep -v ' <- ic0\.'; then
      echo "canister.wasm has imports that are not from ic0, see above" >&2
      exit 1
    fi

    # The probes as a WASI command, linked like lean-wasm's hello.wasm.
    $CC lean/{Probes,RunProbe}.o ${init}/lib/libInit.a ${runtime}/lib/libleanrt.a ${ldflags} \
      -o run-probe.wasm

    wasm-opt -O canister.wasm -o canister-opt.wasm
    install -Dm444 -t $out/bin canister.wasm canister-opt.wasm run-probe.wasm
    mkdir -p $out/share
    sed -E 's|${builtins.storeDir}/[0-9a-z]{32}-||g' canister.map > $out/share/canister.map
  ''
