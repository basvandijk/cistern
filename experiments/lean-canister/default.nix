# Experiment: a Lean canister, with WASI replaced by the IC's System API, measured in PocketIC.
#
# Pipeline:
#
#   Hello, Ic0, Probes, Canister.lean ──lean -c──▶ *.c ──┐
#   c/*.c: WASI on ic0, the Lean bindings, entry points ──┼─clang (wasm32)──▶ canister.wasm
#   Init and the Lean runtime, from lean-wasm ────────────┘
#
#   Probes.lean, RunProbe.lean, the same way, but a WASI program ──▶ run-probe.wasm
#
#   canister.wasm in PocketIC ──────────┐
#   run-probe.wasm under wasmtime ──────┼──measure.py──▶ report
#   RunProbe.lean natively (lean --run) ┘
#
# `leanWasm` is the lean-wasm experiment (../lean-wasm/default.nix). `pocket-ic` and
# `pocket-ic-py` (../../nix/pocket-ic-py.nix) are null where there is no PocketIC (aarch64-linux),
# and then there is no report.
{
  pkgs,
  leanWasm,
  pocket-ic,
  pocket-ic-py,
}:
let
  inherit (pkgs) lib;

  # clang + wasi-libc + libc++ targeting wasm32-unknown-wasip1, as in lean-wasm.
  wasi = pkgs.pkgsCross.wasi32;

  # Lean → C, and .olean files. Runs the native Lean compiler.
  canisterC = pkgs.callPackage ./nix/lean-c.nix { };

  # The modules: canister.wasm, canister-opt.wasm after wasm-opt, and run-probe.wasm.
  canister = pkgs.callPackage ./nix/wasm.nix {
    inherit wasi canisterC;
    runtime = leanWasm.packages.lean-wasm-runtime;
    init = leanWasm.packages.lean-wasm-init;
  };

  # Installs both canister modules in PocketIC, checks their replies and their state and
  # measures them, and run-probe.wasm under wasmtime.
  report = pkgs.callPackage ./nix/measure.nix {
    inherit
      wasi
      canister
      canisterC
      pocket-ic
      pocket-ic-py
      ;
  };
in
{
  packages = {
    lean-canister-c = canisterC;
    lean-canister-wasm = canister;
  }
  // lib.optionalAttrs (pocket-ic != null) {
    lean-canister-report = report;
  };

  # The report fails to build if a module does not install or upgrade, or a reply, a probe's
  # result or the state is wrong.
  checks = lib.optionalAttrs (pocket-ic != null) {
    lean-canister-runs = report;
  };
}
