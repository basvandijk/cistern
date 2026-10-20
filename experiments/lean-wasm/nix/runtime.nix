# The Lean runtime (libleanrt), built for wasm32-wasip1.
#
# Interface (used by ../default.nix):
#   A derivation with
#     $out/include/lean/*.h  lean.h plus a config.h that matches how this runtime was built
#     $out/lib/libleanrt.a   the runtime as a wasm32 static library
#   and `passthru.cflags`: the flags Lean-generated C must be compiled with, so that
#   it agrees with the runtime on configuration (allocator, threading, ...).
#   Also `passthru.ldflags`: the flags the final link needs. Compile and link with the
#   wrapped compilers of `wasi.stdenv` ($CC, $CXX); nothing else is needed.
#   `passthru.headers` is a derivation with just those headers ($out/include/lean/*.h); it is
#   what `cflags` refers to.
#
# The configuration is the most minimal one: single-threaded, no mimalloc, no GMP (Lean's own
# bignums) and no mmap. Upstream's CMake build is not used, as it builds Lean itself as well.
{
  lib,
  runCommand,
  lean4,
  wasi,
}:
let
  # The files of src/runtime/CMakeLists.txt that make sense on WASI (some with
  # ../runtime/wasi.patch). The others are replaced by ../runtime/wasi-stubs.cpp:
  #   process.cpp                 there are no processes
  #   stack_overflow.cpp          there are no signals
  #   libuv.cpp, uv/*.cpp         there is no libuv; io.cpp gets ../runtime/uv.h instead
  #   openssl.cpp                 there is no OpenSSL
  # compact.cpp (.olean files and compacted regions) needs mmap and dl_iterate_phdr and is
  # not used by Init, so it is simply left out.
  sources = [
    "alloc.cpp"
    "allocprof.cpp"
    "apply.cpp"
    "byteslice.cpp"
    "debug.cpp"
    "exception.cpp"
    "hash.cpp"
    "init_module.cpp"
    "interrupt.cpp"
    "io.cpp"
    "memory.cpp"
    "mpn.cpp"
    "mpz.cpp"
    "mutex.cpp"
    "object.cpp"
    "object_ref.cpp"
    "platform.cpp"
    "sharecommon.cpp"
    "stackinfo.cpp"
    "thread.cpp"
    "utf8.cpp"
  ];

  # As upstream's release build of the runtime (src/CMakeLists.txt), minus -fPIC and
  # -ftls-model, which do not apply to a static wasm32 library.
  cxxflags = [
    "-std=c++20"
    "-O3"
    "-DNDEBUG"
    "-DLEAN_BUILD_TYPE=Release"
    "-DLEAN_EXPORTING"
    "-D__CLANG__"
    "-ffp-contract=off"
    "-fvisibility=hidden"
    "-fvisibility-inlines-hidden"
    "-Isrc"
    "-Isrc/include"
    "-Iwasi"
  ];

  # The stack in linear memory. Lean code keeps its locals in Wasm locals, on the engine's
  # stack, but some runtime functions have a frame here, among them `lean_apply_*`, through
  # which Lean calls closures. So recursion through closures uses this stack as well: with
  # wasm-ld's default of 64 KiB it ran out long before the engine's stack did (see
  # ../README.md). 8 MiB, what Lean gives threads on 32-bit targets (thread.cpp), is ample.
  stackSize = 8 * 1024 * 1024;

  # A derivation of their own, so that compiling Lean code does not depend on the runtime's
  # sources. config.h and version.h are those of the lean4 that generates our C, but without
  # mimalloc and with the actual target.
  headers = runCommand "lean-headers-${lean4.version}" { } ''
    cp --no-preserve=mode ${lean4.src}/src/include/lean/lean.h .
    patch lean.h ${../runtime/lean.h.patch}
    substitute ${lean4}/include/lean/config.h config.h --replace-fail "#define LEAN_MIMALLOC" ""
    substitute ${lean4}/include/lean/version.h version.h \
      --replace-fail 'LEAN_PLATFORM_TARGET ""' 'LEAN_PLATFORM_TARGET "${wasi.stdenv.hostPlatform.config}"'
    install -Dm444 -t $out/include/lean lean.h config.h version.h
  '';
in
wasi.stdenv.mkDerivation {
  pname = "lean-runtime";
  inherit (lean4) version;

  # Copy just the runtime's part of the Lean source tree (681 MB in all), and our headers.
  unpackPhase = ''
    runHook preUnpack
    mkdir -p source/src source/wasi
    cp -r --no-preserve=mode ${lean4.src}/src/{include,runtime,util} source/src/
    cp --no-preserve=mode ${headers}/include/lean/*.h source/src/include/lean/
    cp ${../runtime/uv.h} source/wasi/uv.h
    cp ${../runtime/wasi-stubs.cpp} source/wasi/wasi-stubs.cpp
    cd source
    runHook postUnpack
  '';

  patches = [
    ../runtime/wasi.patch
    ../runtime/string-to-list.patch
    ../runtime/task-manager.patch
  ];

  postPatch = ''
    substitute ${lean4.src}/src/githash.h.in src/githash.h --replace-fail "@GIT_SHA1@" ""
  '';

  # The runtime has `throw`s, so it needs -fexceptions (see wasi-stubs.cpp). The cc-wrapper
  # appends -fno-exceptions after the command line, but NIX_CFLAGS_COMPILE comes after that.
  env.NIX_CFLAGS_COMPILE = "-fexceptions";

  buildPhase = ''
    runHook preBuild
    for file in ${lib.concatMapStringsSep " " (f: "src/runtime/${f}") sources} wasi/wasi-stubs.cpp; do
      echo "compiling $file"
      $CXX ${lib.escapeShellArgs cxxflags} -c "$file" -o "$(basename "$file" .cpp).o"
    done
    $AR rcs libleanrt.a *.o
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 -t $out/lib libleanrt.a
    install -Dm444 -t $out/include/lean src/include/lean/{lean.h,config.h,version.h}
    runHook postInstall
  '';

  passthru = {
    inherit headers;

    # For compiling Lean-generated C, as leanc does: its -fdata-sections and -ffunction-sections
    # are the default for wasm, and -fstack-clash-protection and -fPIC do not apply.
    cflags = [
      "-I${headers}/include"
      "-O3"
      "-DNDEBUG"
      "-ffp-contract=off"
      "-fvisibility=hidden"
    ];

    # For linking libleanrt.a (and Lean code) into a WASI command.
    ldflags = [
      "-Wl,-z,stack-size=${toString stackSize}"
      # Puts the stack below the static data, so that an overflow traps instead of
      # overwriting that data.
      "-Wl,--stack-first"
      # The runtime is C++; clang++ adds these, clang does not.
      "-lc++"
      "-lc++abi"
    ];
  };
}
