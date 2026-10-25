# The canister's Candid interface, canister.did, generated from Interface.lean, and a check that
# the committed one and canister.wasm's exports agree with it.
#
# Interface (used by ../default.nix):
#   did   : a derivation with $out/canister.did, and $out/exports.txt, the functions that
#           canister.wasm must export, one per line, both printed by ../GenDid.lean
#   check : a derivation that fails to build if ../canister.did is not the generated one, or if
#           canister.wasm does not export exactly the functions of exports.txt
#
# c/canister.c defines the exports by hand; the check makes sure that they are those of
# Interface.lean's methods.
{
  runCommand,
  lean4,
  wabt,
  canisterC,
  candidC,
  canister,
}:
rec {
  did = runCommand "lean-canister-did" { nativeBuildInputs = [ lean4 ]; } ''
    export LEAN_PATH=${canisterC}/olean:${candidC}/olean
    mkdir $out
    lean -j "$NIX_BUILD_CORES" --run ${../GenDid.lean} > $out/canister.did
    lean -j "$NIX_BUILD_CORES" --run ${../GenDid.lean} --exports > $out/exports.txt
  '';

  check = runCommand "lean-canister-interface" { nativeBuildInputs = [ wabt ]; } ''
    diff -u ${../canister.did} ${did}/canister.did
    # wasm-objdump runs on its own line, so that the build fails if it does.
    wasm-objdump -x -j Export ${canister}/bin/canister.wasm > listing.txt
    grep -o '"canister_[^"]*"' listing.txt | tr -d '"' | sort > exports.txt
    sort ${did}/exports.txt | diff -u - exports.txt
    mkdir $out
    cp exports.txt $out/
  '';
}
