# Runs the Candid library's test programs, Candid/Tests/*.lean: natively with `lean --run`, and
# compiled to wasm32-wasip1 under wasmtime, as a canister is 32-bit: more numbers are bignums
# there (a `Nat` from 2^31, an `Int` outside -2^30 to 2^30 - 1), and `USize` has 32 bits. The
# wasm32 output must be the native one.
#
# Interface (used by ../default.nix):
#   native : a derivation with $out/<Test>.txt, the output of each program, which fails to build
#            if a test fails
#   wasm   : a derivation with $out/<Test>.native.txt and $out/<Test>.wasm.txt, which fails to
#            build if a test fails on wasm32, or if the output differs from the native one
#
# Tests/Derive.lean runs natively only: deriving needs Lean's own modules, which only the compiler
# runs (see lean-c.nix). Tests/Parse.lean also parses the .did files of the Rust parser's tests,
# from the flake input dfinity/candid, when it is given their directory, which it is natively only:
# wasmtime would need access to the directory.
{
  lib,
  runCommand,
  lean4,
  wasmtime,
  wasi,
  runtime,
  init,
  candidC,
  candidWasm,
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

  # The programs that run on wasm32 too, and all of them, which run natively. A new program in
  # Candid/Tests runs only once it is in one of these lists.
  portable = [
    "Encode"
    "Decode"
    "Parse"
    "RoundTrip"
  ];
  all = portable ++ [ "Derive" ];

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
{
  native = runCommand "candid-tests" { nativeBuildInputs = [ lean4 ]; } ''
    ${run}
    export LEAN_PATH=${candidC}/olean
    mkdir $out
    for test in ${lib.escapeShellArgs all}; do
      if [ $test = Parse ]; then args="--assets ${assets}"; else args=""; fi
      run $out/$test.txt lean --run ${src}/Candid/Tests/$test.lean $args
    done
  '';

  wasm =
    wasi.runCommandCC "candid-tests-wasm"
      {
        nativeBuildInputs = [
          lean4
          wasmtime
        ];
      }
      ''
        ${run}
        export LEAN_PATH=${candidC}/olean
        mkdir $out
        for test in ${lib.escapeShellArgs portable}; do
          lean -R ${src} -c $test.c ${src}/Candid/Tests/$test.lean
          $CC ${lib.escapeShellArgs runtime.cflags} -c $test.c -o $test.o
          $CC $test.o ${candidWasm}/lib/libCandid.a ${init}/lib/libInit.a \
            ${runtime}/lib/libleanrt.a ${lib.escapeShellArgs runtime.ldflags} -o $test.wasm
          run $out/$test.native.txt lean --run ${src}/Candid/Tests/$test.lean
          # Without its cache, which would be in $HOME, wasmtime runs in the sandbox. With the IC's
          # Wasm stack of 5 MiB (MAX_WASM_STACK_SIZE in rs/embedders/src/lib.rs), rather than
          # wasmtime's 512 KiB, on which Tests/Parse.lean's deepest nesting runs out of stack.
          run $out/$test.wasm.txt wasmtime run -C cache=n -W max-wasm-stack=5242880 $test.wasm
          diff -u $out/$test.native.txt $out/$test.wasm.txt
        done
      '';
}
