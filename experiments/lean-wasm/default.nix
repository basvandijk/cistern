# Experiment: compile a Lean program to WebAssembly (wasm32-wasip1).
#
# Pipeline:
#
#   Hello.lean ──lean -c──▶ Hello.c ─┐
#   Init/*.lean ─lean -c──▶ Init/*.c ┼─clang (wasm32-wasip1)──▶ hello.wasm ──▶ report
#   Lean runtime (C++) ──────────────┘
#
# Lean itself runs natively. Only the C it generates, and the C++ runtime that
# C links against, are compiled for WebAssembly.
{ pkgs }:
let
  # clang + wasi-libc + libc++ targeting wasm32-unknown-wasip1.
  # This is the nixpkgs counterpart of wasi-sdk.
  wasi = pkgs.pkgsCross.wasi32;

  # Lean → C. Runs the native Lean compiler.
  leanC = pkgs.callPackage ./nix/lean-c.nix { };

  # The Lean runtime (libleanrt) and headers, built for wasm32-wasip1.
  runtime = pkgs.callPackage ./nix/runtime.nix { inherit wasi; };

  # Compiles the generated C for wasm32-wasip1, links hello.wasm and inspects it.
  wasm = pkgs.callPackage ./nix/wasm.nix {
    inherit wasi runtime;
    inherit (leanC)
      initC
      stdC
      helloC
      tasksC
      ;
  };
in
{
  packages = {
    lean-wasm-init-c = leanC.initC;
    lean-wasm-std-c = leanC.stdC;
    lean-wasm-hello-c = leanC.helloC;
    lean-wasm-tasks-c = leanC.tasksC;
    lean-wasm-runtime = runtime;
    lean-wasm-init = wasm.init;
    lean-wasm-std = wasm.std;
    lean-wasm-hello = wasm.hello;
    lean-wasm-tasks = wasm.tasks;
    lean-wasm-report = wasm.report;
  };

  checks = {
    lean-wasm-hello-runs = wasm.check;
    lean-wasm-tasks-runs = wasm.tasksCheck;
  };
}
