# Runs the Candid library's test programs, Candid/Tests/*.lean, natively with `lean --run`. The
# library's 32-bit behavior, which matters as a canister is 32-bit (more numbers are bignums
# there: a `Nat` from 2^31, an `Int` outside -2^30 to 2^30 - 1; `USize` has 32 bits), is exercised
# in the canister, under PocketIC (../../experiments/lean-canister).
#
# Interface (used by ../default.nix):
#   A derivation with $out/<Test>.txt, the output of each program, which fails to build if a test
#   fails.
#
# Tests/Derive.lean needs Lean's own modules, which only the compiler runs (see lean-c.nix).
# Tests/Parse.lean also parses the .did files of the Rust parser's tests, from the flake input
# dfinity/candid, when it is given their directory.
{
  lib,
  runCommand,
  lean4,
  candidC,
  candidSrc,
}:
let
  # Only the test programs, so that other edits in the repository don't cause a rerun.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../Candid/Tests;
  };

  # The files of the Rust parser's tests that Tests/Parse.lean reads: the inputs, `X.did`, and in
  # ok/ the Rust printer's output for each, `X.did`, or `X.fail` if the Rust parser rejects it.
  # Only those, so that a new commit of dfinity/candid that leaves them alone does not rerun the
  # tests.
  assetsDir = "${candidSrc}/rust/candid_parser/tests/assets";
  assets = builtins.path {
    name = "candid-parser-assets";
    path = assetsDir;
    filter =
      path: type:
      let
        isIn = dir: dirOf path == dir && type == "regular";
      in
      (type == "directory" && path == "${assetsDir}/ok")
      || (isIn assetsDir && lib.hasSuffix ".did" path)
      || (isIn "${assetsDir}/ok" && (lib.hasSuffix ".did" path || lib.hasSuffix ".fail" path));
  };

  # The programs. A new program in Candid/Tests runs only once it is in this list.
  all = [
    "Encode"
    "Decode"
    "Parse"
    "RoundTrip"
    "Derive"
  ];

  # `run FILE COMMAND…` runs a test program with its output in FILE. If the program fails, it
  # prints the lines of the output that are not passed checks (`ok …`), which are the failures
  # and the counts, so that they are at the end of the build log, the part that Nix shows.
  run = ''
    run() {
      local output=$1
      shift
      if ! "$@" > "$output"; then
        grep -v '^ok ' "$output" || true
        return 1
      fi
    }
  '';
in
runCommand "candid-tests" { nativeBuildInputs = [ lean4 ]; } ''
  ${run}
  export LEAN_PATH=${candidC}/olean
  mkdir $out
  for test in ${lib.escapeShellArgs all}; do
    if [ $test = Parse ]; then args="--assets ${assets}"; else args=""; fi
    run $out/$test.txt lean --run ${src}/Candid/Tests/$test.lean $args
  done
''
