# The Candid library: Lean → C, the C compiled for wasm32 as libCandid.a, and its tests.
#
# Pipeline:
#
#   Candid.lean, Candid/<Module>.lean ──lean -c──▶ *.c, *.olean ──clang (wasm32)──▶ libCandid.a
#     (Candid/Derive.lean to .olean only, for the compiler)
#   Candid/Tests/*.lean ──lean --run──▶ test results
#   dfinity/candid's test/*.test.did ──Candid/Conformance.lean──▶ conformance results
#
# `wasi` is the wasm32-wasip1 toolchain and `runtime` the Lean runtime built for it
# (../nix/lean-runtime.nix), with whose flags the wasm32 code is compiled. `candidSrc` is the flake
# input dfinity/candid, whose conformance suite and the Rust parser's test files the checks read.
{
  pkgs,
  wasi,
  runtime,
  candidSrc,
}:
let
  candidC = pkgs.callPackage ./nix/lean-c.nix { };
  candidWasm = pkgs.callPackage ./nix/wasm.nix { inherit wasi runtime candidC; };
  tests = pkgs.callPackage ./nix/tests.nix { inherit candidC candidSrc; };
  conformance = pkgs.callPackage ./nix/conformance.nix { inherit candidC candidSrc; };
in
{
  packages = {
    candid-c = candidC;
    candid-wasm = candidWasm;
  };

  checks = {
    candid-tests = tests;
    candid-conformance = conformance;
  };
}
