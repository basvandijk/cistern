# The Candid library: Lean → C, the C compiled for wasm32 as libCandid.a, and its tests.
#
# Pipeline:
#
#   Candid.lean, Candid/<Module>.lean ──lean -c──▶ *.c, *.olean ──clang (wasm32)──▶ libCandid.a
#     (Candid/Derive.lean to .olean only, for the compiler)
#   Candid/Tests/*.lean ──lean --run──▶ test results
#   the same but Derive.lean ──lean -c, clang (wasm32), with libCandid.a──▶ wasmtime ──▶ the same
#   dfinity/candid's test/*.test.did ──Candid/Conformance.lean──▶ conformance results
#
# `leanWasm` is the lean-wasm experiment (../experiments/lean-wasm/default.nix), whose runtime and
# Init the wasm32 code links. `candidSrc` is the flake input dfinity/candid, whose conformance
# suite and the Rust parser's test files the checks read.
{
  pkgs,
  leanWasm,
  candidSrc,
}:
let
  # clang + wasi-libc + libc++ targeting wasm32-unknown-wasip1, as in lean-wasm.
  wasi = pkgs.pkgsCross.wasi32;
  runtime = leanWasm.packages.lean-wasm-runtime;
  init = leanWasm.packages.lean-wasm-init;

  candidC = pkgs.callPackage ./nix/lean-c.nix { };
  candidWasm = pkgs.callPackage ./nix/wasm.nix { inherit wasi runtime candidC; };
  tests = pkgs.callPackage ./nix/tests.nix {
    inherit
      wasi
      runtime
      init
      candidC
      candidWasm
      candidSrc
      ;
  };
  conformance = pkgs.callPackage ./nix/conformance.nix { inherit candidC candidSrc; };
in
{
  packages = {
    candid-c = candidC;
    candid-wasm = candidWasm;
  };

  checks = {
    candid-tests = tests.native;
    candid-tests-wasm = tests.wasm;
    candid-conformance = conformance;
  };
}
