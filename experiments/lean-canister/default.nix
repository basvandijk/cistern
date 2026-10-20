# Experiment: a Lean canister, with WASI replaced by the IC's System API, measured in PocketIC.
#
# Pipeline:
#
#   Hello, Ic0, Probes, Interface, Canister.lean ──lean -c──▶ *.c ──┐
#   c/*.c: WASI on ic0, the Lean bindings, entry points ────────────┼─clang (wasm32)──▶ canister.wasm
#   the Candid library (libCandid.a), Init and the Lean runtime ────┘
#
#   Probes.lean, RunProbe.lean, the same way, but a WASI program ──▶ run-probe.wasm
#
#   Interface.lean ──GenDid.lean──▶ canister.did, checked against the committed one
#
#   canister.wasm in PocketIC ──────────┐
#   run-probe.wasm under wasmtime ──────┼──measure.py, with canister.did──▶ report
#   RunProbe.lean natively (lean --run) ┘
#
# `leanWasm` is the lean-wasm experiment (../lean-wasm/default.nix), `candid` the Candid library
# (../../candid/default.nix). `pocket-ic` (../../nix/pocket-ic.nix) and `pocket-ic-py`
# (../../nix/pocket-ic-py.nix) are null where there is no PocketIC (aarch64-linux), and then there
# is no report.
{
  pkgs,
  leanWasm,
  candid,
  pocket-ic,
  pocket-ic-py,
}:
let
  inherit (pkgs) lib;

  # clang + wasi-libc + libc++ targeting wasm32-unknown-wasip1, as in lean-wasm.
  wasi = pkgs.pkgsCross.wasi32;

  candidC = candid.packages.candid-c;

  # Lean → C, and .olean files. Runs the native Lean compiler.
  canisterC = pkgs.callPackage ./nix/lean-c.nix { inherit candidC; };

  # The modules: canister.wasm, canister-opt.wasm after wasm-opt, and run-probe.wasm.
  canister = pkgs.callPackage ./nix/wasm.nix {
    inherit wasi canisterC;
    runtime = leanWasm.packages.lean-wasm-runtime;
    init = leanWasm.packages.lean-wasm-init;
    candidWasm = candid.packages.candid-wasm;
  };

  # canister.did, generated from Interface.lean, and the check of the committed one and of the
  # module's exports.
  interface = pkgs.callPackage ./nix/did.nix { inherit canisterC candidC canister; };

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
    inherit (interface) did;
  };
in
{
  packages = {
    lean-canister-c = canisterC;
    lean-canister-wasm = canister;
    lean-canister-did = interface.did;
  }
  // lib.optionalAttrs (pocket-ic != null) {
    lean-canister-report = report;
  };

  # The report fails to build if a module does not install or upgrade, or a reply, a probe's
  # result or the state is wrong. The interface check needs no PocketIC.
  checks = {
    lean-canister-interface = interface.check;
  }
  // lib.optionalAttrs (pocket-ic != null) {
    lean-canister-runs = report;
  };
}
