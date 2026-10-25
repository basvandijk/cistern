# The native Lean (`lean`, `lake`, the `Init` and `Std` sources and .olean files), built from the flake
# input `lean4`: the `cistern` branch of basvandijk/lean4, which is the upstream commit of the nightly
# `nightly` (what ../lean-toolchain names, for the editor) plus cistern's commits. See ../README.md.
#
# Interface (used by ../flake.nix, as `pkgs.lean4` through an overlay):
#   nixpkgs' lean4 derivation with the fork as `src`, so that `${lean4}/src/lean`,
#   `${lean4}/include/lean/{config,version}.h` and `lean4.src` (../nix/lean-runtime.nix,
#   ../nix/lean-libs.nix) are as nixpkgs lays them out, and `passthru.nightly`, the nightly's name.
#
# nixpkgs' recipe fits upstream master except for CaDiCaL, which Lean links over FFI since
# v4.36.0-rc1: without the three variables, the top-level CMakeLists.txt clones it from GitHub, which
# the sandbox forbids. nixpkgs' cadical is rel-3.0.1, the version Lean pins. The typed cmake flags of
# the recipe (`USE_GITHASH`, `INSTALL_*`) are not forwarded to the stages and have no effect; the
# untyped ones below are.
{
  lib,
  lean4,
  cadical,
  gitMinimal,
  src,
  nightly,
}:
lean4.overrideAttrs (
  final: old: {
    # What `lean --version` prints for a build that is not a release: versionCheckHook looks for it.
    version = "4.37.0-pre";
    inherit src;
    # git: the configure step of the external projects that are not built (lean4lean, nanoda, ...)
    # still needs it; the recipe has it for its tests only.
    nativeBuildInputs = [
      gitMinimal
    ]
    ++ map (p: if lib.getName p == "cadical" then cadical else p) old.nativeBuildInputs;
    cmakeFlags = old.cmakeFlags ++ [
      "-DCADICAL=${lib.getExe cadical}"
      "-DCADICAL_LIB=${lib.getLib cadical}/lib/libcadical.a"
      "-DCADICAL_INCLUDE_DIR=${lib.getDev cadical}/include"
    ];
    # `bv_decide` runs `cadical`, looking next to `lean` first and then on PATH.
    postInstall = "wrapProgram $out/bin/lean --prefix PATH : ${cadical}/bin";
    passthru = (old.passthru or { }) // {
      inherit nightly;
    };
    meta = old.meta // {
      changelog = "https://github.com/basvandijk/lean4/commits/cistern";
    };
  }
)
