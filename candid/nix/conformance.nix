# Runs the conformance suite of the Candid specification, the test/*.test.did files of
# dfinity/candid, with Candid/Conformance.lean.
#
# Interface (used by ../default.nix):
#   A derivation with $out/results.txt, which names the commit of dfinity/candid and has a line
#   per assertion and the totals. It fails to build if an assertion fails, and then the build log
#   shows the lines of the results that are not passed assertions. `passthru.suite` is the
#   directory with the test files.
#
# `candidSrc` is the flake input dfinity/candid. Only its test files are copied into the store for
# this derivation, so that it needs them and not the whole repository. As the results name the
# commit, a new commit reruns the check, which takes seconds.
{
  lib,
  runCommand,
  lean4,
  candidC,
  candidSrc,
}:
let
  suite = builtins.path {
    name = "candid-conformance-suite";
    path = "${candidSrc}/test";
    filter = path: type: type == "regular" && lib.hasSuffix ".test.did" (baseNameOf path);
  };

  # The commit, as the first line of the results says, such as 10423fa.
  commit = candidSrc.shortRev or "unknown";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../Candid/Conformance.lean;
  };
in
runCommand "candid-conformance"
  {
    nativeBuildInputs = [ lean4 ];
    passthru = { inherit suite; };
  }
  ''
    export LEAN_PATH=${candidC}/olean
    mkdir $out
    echo "The conformance suite of dfinity/candid at ${commit}." > $out/results.txt
    if ! lean -j "$NIX_BUILD_CORES" --run ${src}/Candid/Conformance.lean ${suite}/*.test.did >> $out/results.txt; then
      # The failures and the totals, at the end of the build log, the part that Nix shows.
      grep -v '^pass ' $out/results.txt || true
      exit 1
    fi
  ''
