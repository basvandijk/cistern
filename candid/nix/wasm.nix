# Compiles the Candid library's C for wasm32-wasip1: that of every module but Candid.Derive, which
# has none (see lean-c.nix).
#
# Interface (used by ../default.nix):
#   A derivation with $out/lib/libCandid.a, which a canister links with libInit.a
#   (../../nix/lean-libs.nix) and libleanrt.a (../../nix/lean-runtime.nix).
#
# As for libInit.a, each object is named after its module, and compiled with the runtime's flags.
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
