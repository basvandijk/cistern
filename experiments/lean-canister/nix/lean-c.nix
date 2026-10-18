# Lean → C for the canister and run-probe, using the native Lean compiler.
#
# Interface (used by ../default.nix):
#   A derivation with $out/<module>.c for Hello, Ic0, Probes, Canister and RunProbe, generated
#   from ../../lean-wasm/Hello.lean and ../<module>.lean, and $out/olean/<module>.olean, with
#   which `lean --run` imports them.
#
# Canister.lean imports Hello, Ic0 and Probes; RunProbe.lean imports Probes. Lean reads imports
# from .olean files, so each module is compiled to one as well, before the modules that import
# it; LEAN_PATH finds them. Init's .olean files come with lean4.
{ runCommand, lean4 }:
runCommand "lean-canister-c" { nativeBuildInputs = [ lean4 ]; } ''
  # Only these files, so that other edits in the repository don't cause a rebuild.
  cp ${../../lean-wasm/Hello.lean} Hello.lean
  cp ${../Ic0.lean} Ic0.lean
  cp ${../Probes.lean} Probes.lean
  cp ${../Canister.lean} Canister.lean
  cp ${../RunProbe.lean} RunProbe.lean
  mkdir -p $out/olean
  for module in Hello Ic0 Probes Canister RunProbe; do
    LEAN_PATH=$out/olean lean -R . -o $out/olean/$module.olean -c $out/$module.c $module.lean
  done
''
