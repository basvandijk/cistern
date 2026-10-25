# Lean → C for the Candid library, using the native Lean compiler.
#
# Interface (used by ../default.nix):
#   A derivation with $out/c/Candid.c and $out/c/Candid/<X>.c, the C of the library's modules,
#   and $out/olean, their .olean files and that of Candid.Derive, with which `lean` finds the
#   modules that a file imports through LEAN_PATH.
#
# Each module is compiled after the modules it imports, whose .olean files it reads. Candid.Derive
# is compiled to .olean only, not to C: it imports Lean's own modules, which a canister does not
# link, and only the compiler runs it, when it elaborates a file that derives `CandidType`.
{
  lib,
  runCommand,
  lean4,
}:
let
  # In the order of their imports.
  modules = [
    "Candid.Error"
    "Candid.Hash"
    "Candid.Leb128"
    "Candid.Ty"
    "Candid.Principal"
    "Candid.Value"
    "Candid.Subtype"
    "Candid.Encode"
    "Candid.Decode"
    "Candid.Parse"
    "Candid.Class"
    "Candid"
  ];

  # The .lean files: Candid.lean, and those in Candid/.
  leanFiles = lib.fileset.unions [
    ../Candid.lean
    (lib.fileset.fileFilter (file: file.hasExt "lean") ../Candid)
  ];

  # The programs, which are not part of the library.
  programs = lib.fileset.unions [
    ../Candid/Tests
    ../Candid/Conformance.lean
  ];

  # The library's modules, without the programs, so that editing a test does not rebuild the
  # library, nor what links it.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference leanFiles programs;
  };
in
# `-j`: as many threads as the build has cores (see ../../nix/lean-libs.nix).
runCommand "candid-c" { nativeBuildInputs = [ lean4 ]; } ''
  cd ${src}
  mkdir -p $out/c/Candid $out/olean/Candid
  for module in ${lib.escapeShellArgs modules}; do
    file=''${module//.//}
    LEAN_PATH=$out/olean lean -j "$NIX_BUILD_CORES" -R . -o $out/olean/$file.olean -c $out/c/$file.c $file.lean
  done
  LEAN_PATH=$out/olean lean -j "$NIX_BUILD_CORES" -R . -o $out/olean/Candid/Derive.olean Candid/Derive.lean
''
