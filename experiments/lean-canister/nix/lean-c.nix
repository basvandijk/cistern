# Lean → C for the canister, using the native Lean compiler.
#
# Interface (used by ../default.nix):
#   A derivation with $out/<module>.c for Hello, Ic0, Probes, Interface, Ic and Canister,
#   generated from ../<module>.lean, and $out/olean/<module>.olean, with which `lean --run`
#   imports them (GenDid.lean in nix/did.nix, RunProbe.lean in nix/measure.nix).
#
# Canister.lean imports Hello, Ic0, Probes, Interface and Ic; Interface.lean imports the Candid
# library (../../../candid), whose .olean files are those of `candidC`, and its deriving handler,
# Candid.Derive, with `meta import`; Ic.lean imports Ic0, Interface and Std.Async.Basic. Lean
# reads imports from .olean files, so each module is compiled to one as well, before the modules
# that import it; LEAN_PATH finds them. Init's and Std's .olean files come with lean4. GenDid.lean
# and RunProbe.lean are not compiled here: nix/did.nix and nix/measure.nix run them with
# `lean --run`.
{
  runCommand,
  lean4,
  candidC,
}:
runCommand "lean-canister-c" { nativeBuildInputs = [ lean4 ]; } ''
  # Only these files, so that other edits in the repository don't cause a rebuild.
  cp ${../Hello.lean} Hello.lean
  cp ${../Ic0.lean} Ic0.lean
  cp ${../Probes.lean} Probes.lean
  cp ${../Interface.lean} Interface.lean
  cp ${../Ic.lean} Ic.lean
  cp ${../Canister.lean} Canister.lean
  mkdir -p $out/olean
  for module in Hello Ic0 Probes Interface Ic Canister; do
    LEAN_PATH=$out/olean:${candidC}/olean lean -R . -o $out/olean/$module.olean \
      -c $out/$module.c $module.lean
  done
''
