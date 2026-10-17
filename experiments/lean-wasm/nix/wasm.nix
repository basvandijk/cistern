# Compiles Lean-generated C for wasm32-wasip1, links it and inspects the result.
#
# Interface (used by ../default.nix):
#   init   : derivation with $out/lib/libInit.a (Lean's Init library, wasm32)
#   hello  : derivation with $out/bin/hello.wasm
#            (also $out/bin/hello-opt.wasm, the same after `wasm-opt -O`, and
#            $out/share/hello.map, the linker's map of hello.wasm)
#   report : derivation with $out/report.txt describing hello.wasm
#            (imports, exports, sections, sizes; also the raw wasm-objdump output
#            in $out/sections.txt, $out/imports.txt and $out/exports.txt)
#   check  : derivation that runs hello.wasm and hello-opt.wasm under wasmtime and compares
#            their output with the native `lean --run Hello.lean`
{
  lib,
  runCommand,
  lean4,
  binaryen,
  python3,
  wabt,
  wasm-tools,
  wasmtime,
  wasi,
  runtime,
  initC,
  helloC,
}:
let
  cflags = lib.escapeShellArgs runtime.cflags;
  ldflags = lib.escapeShellArgs runtime.ldflags;
in
rec {
  # Archive members are named after their file, and many modules share a file name
  # (Init/Data/List/Basic.c, Init/Data/Array/Basic.c, ...). So each object is named
  # after its module instead: Init.Data.List.Basic.o.
  init = wasi.runCommandCC "lean-init-${lean4.version}" { } ''
    compile() { $CC ${cflags} -c "${initC}/$1" -o "$(echo "''${1%.c}" | tr / .).o"; }
    export -f compile
    (cd ${initC} && find . -name '*.c' -printf '%P\n') | sort |
      xargs -P "$NIX_BUILD_CORES" -n 1 bash -c 'compile "$0"'
    $AR rcs libInit.a *.o
    install -Dm444 -t $out/lib libInit.a
  '';

  # wasm-ld fails on undefined symbols (there is no --allow-undefined), so the link is
  # complete. It also drops unreferenced functions and data by default (--gc-sections).
  # The map names the linked files by their store paths. Without the hashes, the output
  # does not keep those files alive.
  hello = wasi.runCommandCC "lean-hello" { nativeBuildInputs = [ binaryen ]; } ''
    $CC ${cflags} -c ${helloC}/Hello.c -o Hello.o
    $CC Hello.o ${init}/lib/libInit.a ${runtime}/lib/libleanrt.a ${ldflags} \
      -Wl,-Map=hello.map -o hello.wasm
    wasm-opt -O hello.wasm -o hello-opt.wasm
    install -Dm444 -t $out/bin hello.wasm hello-opt.wasm
    mkdir -p $out/share
    sed -E 's|${builtins.storeDir}/[0-9a-z]{32}-||g' hello.map > $out/share/hello.map
  '';

  report =
    runCommand "lean-wasm-report"
      {
        nativeBuildInputs = [
          python3
          wabt
          wasm-tools
        ];
        about =
          "hello.wasm is Hello.lean compiled to C by Lean ${lean4.version}, and then by clang "
          + "${wasi.stdenv.cc.version} to ${wasi.stdenv.hostPlatform.config}, together with "
          + "Lean's Init library and runtime. This report comes from report.py, using wabt "
          + "${wabt.version} and wasm-tools ${wasm-tools.version}.";
      }
      ''
        mkdir $out
        # Working in the directory makes the tools name the files rather than their store paths.
        cd ${hello}/bin
        python3 ${../report.py} hello.wasm hello-opt.wasm ../share/hello.map "$about" > $out/report.txt
        wasm-objdump -h hello.wasm > $out/sections.txt
        wasm-objdump -x -j Import hello.wasm > $out/imports.txt
        wasm-objdump -x -j Export hello.wasm > $out/exports.txt
      '';

  check =
    runCommand "lean-wasm-hello-runs"
      {
        nativeBuildInputs = [
          lean4
          wasmtime
        ];
      }
      ''
        # helloC.src holds the Hello.lean that hello.wasm was compiled from.
        lean --run ${helloC.src}/Hello.lean > native.txt
        # Without its cache, which would be in $HOME, wasmtime runs in the sandbox.
        wasmtime run -C cache=n ${hello}/bin/hello.wasm > wasm.txt
        wasmtime run -C cache=n ${hello}/bin/hello-opt.wasm > wasm-opt.txt
        diff -u native.txt wasm.txt
        diff -u native.txt wasm-opt.txt
        mkdir $out
        cp native.txt wasm.txt wasm-opt.txt $out/
      '';
}
