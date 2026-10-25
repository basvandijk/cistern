# Checks that each .lean file of the repository opens in an editor without errors.
#
# An editor's Lean support runs `lake serve` in the directory with lean-toolchain, the
# repository's root. It finds the modules that a file imports through ../lakefile.toml, and
# builds them (VS Code when it opens the file, see ../.vscode/settings.json), with the Lean that
# ../lean-toolchain names. This elaborates each .lean file the same way, with `lake lean`, which
# builds the file's imports and then runs `lean` on it, using the flake's Lean. lean-toolchain
# must name the upstream nightly that the flake's Lean is built from (`lean4.nightly`, see
# ../nix/lean4.nix), so that the editor elaborates the same library. Fails if it does not, or if
# a file has an error, such as an import that lakefile.toml does not find.
{
  lib,
  runCommand,
  lean4,
}:
let
  # Only these files, so that other edits in the repository don't cause a rebuild.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../lakefile.toml
      ../lake-manifest.json
      ../lean-toolchain
      (lib.fileset.fileFilter (file: file.hasExt "lean") ../.)
    ];
  };
in
runCommand "lean-files-open" { nativeBuildInputs = [ lean4 ]; } ''
  toolchain=$(< ${src}/lean-toolchain)
  if [ "$toolchain" != "leanprover/lean4:${lean4.nightly}" ]; then
    echo "lean-toolchain names $toolchain, but the flake's Lean is built from ${lean4.nightly}" >&2
    exit 1
  fi
  # Lake builds in .lake, next to lakefile.toml.
  cp -r --no-preserve=mode ${src} src
  cd src
  export HOME=$TMPDIR
  for file in $(find . -name '*.lean' | sort); do
    echo "$file"
    lake lean "$file"
  done
  touch $out
''
