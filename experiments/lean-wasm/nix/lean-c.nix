# Lean → C, using the native Lean compiler.
#
# Interface (used by ../default.nix):
#   initC  : derivation with one C file per module of Lean's `Init` library,
#            laid out by module name: $out/Init.c, $out/Init/Prelude.c, ...
#   stdC   : derivation with $out/Std/Async/Basic.c, the module Std.Async.Basic of Lean's `Std`
#            library
#   helloC : derivation with $out/Hello.c, generated from ../Hello.lean
#   tasksC : derivation with $out/Tasks.c, generated from ../Tasks.lean
#
# `lean -R <root> -c <file.c> <file.lean>` names the module after the path of the
# .lean file relative to <root>, e.g. Init/System/IO.lean is `Init.System.IO`.
# The C symbols are derived from that name (initialize_Init_System_IO, ...).
{
  lib,
  runCommand,
  lean4,
}:
let
  # The options Lean's own build uses for its libraries: LEAN_EXTRA_OPTS and WFAIL in
  # src/CMakeLists.txt, leanOptions in src/lakefile.toml.in. They don't change the
  # generated C, but with warnings as errors a divergence from that build fails loudly.
  coreFlags = [
    "-Dinterpreter.prefer_native=false"
    "-Dlinter.coreInternal=true"
    "-DwarningAsError=true"
  ];
in
{
  # lean4 ships the sources of Init next to the .olean files built from them. Imports
  # are read from those .olean files, so the modules don't depend on each other's
  # output and can be compiled in parallel, in any order.
  initC = runCommand "lean-init-c-${lean4.version}" { nativeBuildInputs = [ lean4 ]; } ''
    cd ${lean4}/src/lean
    find Init -type d -exec mkdir -p $out/{} \;

    # Each lean process runs a few threads and needs up to ~650 MB, so half the cores
    # keep the machine busy while bounding memory use.
    find Init.lean Init -name '*.lean' | sed 's/\.lean$//' | sort |
      xargs -P $(( NIX_BUILD_CORES > 1 ? NIX_BUILD_CORES / 2 : 1 )) -I{} \
        lean -R . ${lib.escapeShellArgs coreFlags} -c $out/{}.c {}.lean
  '';

  # Std.Async.Basic, the asynchronous programming monads of Lean's `Std` library, which
  # ../Tasks.lean and lean-canister use. It is a module that imports only Init, so it links with
  # Init and the runtime; the other Std.Async modules need libuv. lean4 ships Std's sources and
  # .olean files next to Init's.
  stdC = runCommand "lean-std-c-${lean4.version}" { nativeBuildInputs = [ lean4 ]; } ''
    cd ${lean4}/src/lean
    mkdir -p $out/Std/Async
    lean -R . ${lib.escapeShellArgs coreFlags} -c $out/Std/Async/Basic.c Std/Async/Basic.lean
  '';

  helloC =
    runCommand "lean-hello-c"
      {
        nativeBuildInputs = [ lean4 ];
        # Only Hello.lean, so that other edits in the repository don't cause a rebuild.
        src = lib.fileset.toSource {
          root = ../.;
          fileset = ../Hello.lean;
        };
      }
      ''
        mkdir $out
        cd $src
        lean -R . -c $out/Hello.c Hello.lean
      '';

  # ../Tasks.lean, which tries the task manager of the runtime (see ../README.md), as a program.
  tasksC =
    runCommand "lean-tasks-c"
      {
        nativeBuildInputs = [ lean4 ];
        src = lib.fileset.toSource {
          root = ../.;
          fileset = ../Tasks.lean;
        };
      }
      ''
        mkdir $out
        cd $src
        lean -R . -c $out/Tasks.c Tasks.lean
      '';
}
