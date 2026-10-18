# Installs the canister in PocketIC, in the sandbox, and measures it with ../measure.py. Also
# runs run-probe.wasm under wasmtime, and RunProbe.lean natively, for comparison.
#
# Interface (used by ../default.nix):
#   A derivation with $out/report.txt, and the measurements in $out/measurements.json. It fails
#   to build if a module does not install, or a reply or a probe's result is wrong.
{
  stdenv,
  runCommand,
  cacert,
  lean4,
  pocket-ic,
  pocket-ic-py,
  wasmtime,
  wasi,
  canister,
  canisterC,
}:
runCommand "lean-canister-report"
  {
    nativeBuildInputs = [
      # PocketIC fails to create an instance without CA certificates (see ../../../nix/pocket-ic.nix).
      cacert
      lean4
      pocket-ic
      # python3 with pocketic-py, for measure.py.
      pocket-ic-py
      wasmtime
    ];
    # measure.py talks to PocketIC on 127.0.0.1, which the macOS sandbox allows only with this.
    __darwinAllowLocalNetworking = true;
    about =
      "canister.wasm is Canister.lean, which imports Hello.lean, Ic0.lean and Probes.lean, "
      + "compiled to C by Lean ${lean4.version} and then by clang ${wasi.stdenv.cc.version} to "
      + "${wasi.stdenv.hostPlatform.config}, together with Lean's Init library and runtime and "
      + "the C of c/; canister-opt.wasm is the same after `wasm-opt -O`. Measured by measure.py "
      + "in PocketIC ${pocket-ic.version}, through pocketic-py ${pocket-ic-py.pocket-ic.version}, "
      + "on one application subnet with the IC's production limits, on "
      + "${stdenv.hostPlatform.system}. run-probe.wasm is RunProbe.lean, which "
      + "imports Probes.lean, compiled in the same way, but as a WASI program; measured under "
      + "wasmtime ${wasmtime.version}.";
  }
  ''
    # What Hello.lean prints natively, which the canister's hello query must reply.
    lean --run ${../../lean-wasm/Hello.lean} > $PWD/hello.txt
    lean --run ${../../lean-wasm/Hello.lean} a b > $PWD/hello-a-b.txt
    # For `lean --run RunProbe.lean`, which imports Probes.
    export LEAN_PATH=${canisterC}/olean
    mkdir $out
    hello=$PWD/hello.txt
    hello_a_b=$PWD/hello-a-b.txt
    cd ${canister}/bin # so that the report names the modules by their file names
    python3 ${../measure.py} --hello $hello --hello-a-b $hello_a_b --run-probe run-probe.wasm \
      --native "lean --run ${../RunProbe.lean}" --about "$about" --json $out/measurements.json \
      canister.wasm canister-opt.wasm > $out/report.txt
  ''
