# Lean's `Init` library and `Std.Async.Basic`, for wasm32-wasip1: their Lean compiled to C by the
# native `lean`, and the C compiled with the runtime's flags.
#
# Interface (used by ../flake.nix):
#   initC : derivation with one C file per module of `Init`, laid out by module name:
#           $out/Init.c, $out/Init/Prelude.c, ...
#   stdC  : derivation with $out/Std/Async/Basic.c, the module Std.Async.Basic of Lean's `Std`
#           library
#   init  : derivation with $out/lib/libInit.a (wasm32)
#   std   : derivation with $out/lib/libStd.a (wasm32)
#
# `lean -R <root> -c <file.c> <file.lean>` names the module after the path of the .lean file
# relative to <root>, e.g. Init/System/IO.lean is `Init.System.IO`. The C symbols are derived from
# that name (initialize_Init_System_IO, ...). lean4 ships the sources of Init and Std next to the
# .olean files built from them, and reads imports from those .olean files, so the modules don't
# depend on each other's output and can be compiled in parallel, in any order. The generated C
# does not depend on the target.
{
  lib,
  runCommand,
  lean4,
  wasi,
  runtime,
}:
let
  # The options Lean's own build uses for its libraries: LEAN_EXTRA_OPTS and WFAIL in
  # src/CMakeLists.txt, leanOptions in src/lakefile.toml.in. They don't change the
  # generated C, but with warnings as errors a divergence from that build fails loudly.
  #
  # Every `lean` here gets `-j`: by default it starts as many worker threads as the host has
  # cores, each with a 1 GB stack reservation, while a sandbox allows only NIX_BUILD_CORES cores and
  # may limit threads or address space (on a many-core builder, compiling a file whose
  # declarations elaborate in parallel then fails with "failed to create thread").
  coreFlags = [
    "-Dinterpreter.prefer_native=false"
    "-Dlinter.coreInternal=true"
    "-DwarningAsError=true"
  ];

  cflags = lib.escapeShellArgs runtime.cflags;
in
rec {
  initC = runCommand "lean-init-c-${lean4.version}" { nativeBuildInputs = [ lean4 ]; } ''
    cd ${lean4}/src/lean
    find Init -type d -exec mkdir -p $out/{} \;

    # Each lean process runs a few threads and needs up to ~650 MB, so half the cores
    # keep the machine busy while bounding memory use.
    find Init.lean Init -name '*.lean' | sed 's/\.lean$//' | sort |
      xargs -P $(( NIX_BUILD_CORES > 1 ? NIX_BUILD_CORES / 2 : 1 )) -I{} \
        lean -j 2 -R . ${lib.escapeShellArgs coreFlags} -c $out/{}.c {}.lean
  '';

  # Std.Async.Basic, the asynchronous programming monads of Lean's `Std` library, which the canister
  # uses. It is a module that imports only Init, so it links with Init and the runtime; the other
  # Std.Async modules need libuv.
  stdC = runCommand "lean-std-c-${lean4.version}" { nativeBuildInputs = [ lean4 ]; } ''
    cd ${lean4}/src/lean
    mkdir -p $out/Std/Async
    lean -j "$NIX_BUILD_CORES" -R . ${lib.escapeShellArgs coreFlags} -c $out/Std/Async/Basic.c Std/Async/Basic.lean
  '';

  # Archive members are named after their file, and many modules share a file name
  # (Init/Data/List/Basic.c, Init/Data/Array/Basic.c, ...). So each object is named
  # after its module instead: Init.Data.List.Basic.o.
  init = wasi.runCommandCC "lean-init-${lean4.version}" { } ''
    compile() { $CC ${cflags} -c "${initC}/$1" -o "$(echo "''${1%.c}" | tr / .).o"; }
    export -f compile
    (cd ${initC} && find . -name '*.c' -printf '%P\n') | sort |
      xargs -P "$NIX_BUILD_CORES" -n 1 bash -c 'compile "$0"'
    $AR rcs libInit.a *.o
    install -Dm444 -t $out/lib libInit.a
  '';

  std = wasi.runCommandCC "lean-std-${lean4.version}" { } ''
    $CC ${cflags} -c ${stdC}/Std/Async/Basic.c -o Std.Async.Basic.o
    $AR rcs libStd.a Std.Async.Basic.o
    install -Dm444 -t $out/lib libStd.a
  '';
}
