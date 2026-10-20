# Compiles the Candid library's C for wasm32-wasip1: that of every module but Candid.Derive, which
# has none (see lean-c.nix).
#
# Interface (used by ../default.nix):
#   A derivation with $out/lib/libCandid.a, which a program or canister links with the libInit.a
#   and libleanrt.a of the lean-wasm experiment.
#
# As for libInit.a (../../experiments/lean-wasm/nix/wasm.nix), each object is named after its
# module, and compiled with the runtime's flags.
{
  lib,
  wasi,
  runtime,
  candidC,
}:
wasi.runCommandCC "candid-wasm" { } ''
  for file in $(cd ${candidC}/c && find . -name '*.c' -printf '%P\n' | sort); do
    $CC ${lib.escapeShellArgs runtime.cflags} -c ${candidC}/c/$file \
      -o "$(echo "''${file%.c}" | tr / .).o"
  done
  $AR rcs libCandid.a *.o
  install -Dm444 -t $out/lib libCandid.a
''
