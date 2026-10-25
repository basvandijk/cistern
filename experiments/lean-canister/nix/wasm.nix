# Compiles the canister for wasm32 and links it, with WASI implemented on ic0.
#
# Interface (used by ../default.nix):
#   A derivation with $out/bin/canister.wasm, $out/bin/canister-opt.wasm (the same after
#   `wasm-opt -O`) and $out/share/canister.map (the linker's map of canister.wasm).
#
# The Lean runtime (`runtime`, ../../../nix/lean-runtime.nix), Init and Std.Async.Basic (`init`,
# `std`, ../../../nix/lean-libs.nix) are built for wasm32-wasip1, and the Candid library is
# `candidWasm`'s libCandid.a. Everything is compiled with the runtime's flags; the files in ../c
# also with warnings as errors.
{
  lib,
  binaryen,
  wabt,
  wasi,
  runtime,
  init,
  std,
  canisterC,
  candidWasm,
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
    for module in Hello Ic0 Probes Interface Ic Canister; do
      $CC ${cflags} -c ${canisterC}/$module.c -o lean/$module.o
    done
    for file in ic0 wasi canister; do
      $CC ${cflags} -Wall -Wextra -Werror -c ${../c}/$file.c -o c/$file.o
    done

    # Without crt1 (-nostartfiles), which would export _start, or _initialize with
    # -mexec-model=reactor: the IC calls neither. canister.c's canister_init runs the C++
    # constructors instead. --no-entry: the exports are those of canister.c (and the memory).
    # --fatal-warnings: wasm-ld only warns about a WASI function in wasi.c with the wrong type.
    $CC lean/{Hello,Ic0,Probes,Interface,Ic,Canister}.o c/*.o ${candidWasm}/lib/libCandid.a \
      ${std}/lib/libStd.a ${init}/lib/libInit.a ${runtime}/lib/libleanrt.a ${ldflags} \
      -nostartfiles -Wl,--no-entry -Wl,--fatal-warnings -Wl,-Map=canister.map -o canister.wasm

    # Interface.lean imports Candid.Derive, the deriving handler, with `meta import`, and the
    # handler imports Lean's own modules, which the link does not have. Only Interface's
    # initializers of the meta phase (meta_initialize_Interface) and of all phases
    # (initialize_Interface) refer to them, and nothing calls those: canister.c calls
    # runtime_initialize_Canister. So wasm-ld drops them, and the link needs no stub for Lean's
    # modules. Were one of them live, the link would already have failed, on Candid.Derive's
    # initializers, which no object defines (the library has no C for Candid.Derive); this check,
    # on the map, which lists the functions that the module has, says so explicitly.
    grep -q ' runtime_initialize_Canister$' canister.map
    if grep -E ' (meta_)?initialize_(Canister|Interface|Ic|Candid_Derive|Std_Async_Basic)$' canister.map; then
      echo "canister.wasm has an initializer of the meta phase, see above" >&2
      exit 1
    fi

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

    wasm-opt -O canister.wasm -o canister-opt.wasm
    install -Dm444 -t $out/bin canister.wasm canister-opt.wasm
    mkdir -p $out/share
    sed -E 's|${builtins.storeDir}/[0-9a-z]{32}-||g' canister.map > $out/share/canister.map
  ''
