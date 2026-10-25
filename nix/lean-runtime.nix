# The Lean runtime (libleanrt), built for wasm32-wasip1 from the sources of the `lean4` input.
#
# Interface (used by ../flake.nix):
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
# The configuration is the most minimal one: single-threaded (the task manager runs in its
# cooperative mode), no mimalloc, no GMP (Lean's own bignums) and no mmap. Upstream's CMake build
# is not used, as it builds Lean itself as well; the recipe is the comment at the top of
# src/runtime/wasi/stubs.cpp in the fork, which this file follows. See ../README.md.
{
  lib,
  runCommand,
  lean4,
  wasi,
}:
let
  # The files of src/runtime/CMakeLists.txt that make sense on WASI. The others are replaced by
  # src/runtime/wasi/stubs.cpp:
  #   process.cpp                 there are no processes
  #   stack_overflow.cpp          there are no signals
  #   libuv.cpp, uv/*.cpp         there is no libuv; io.cpp gets src/runtime/wasi/uv.h instead
  #   openssl.cpp                 there is no OpenSSL
  #   mimalloc.cpp                there is no mimalloc
  # compact.cpp (.olean files and compacted regions) needs mmap and dl_iterate_phdr and is
  # not used by Init, so it is simply left out. cadical.cpp is compiled without LEAN_CADICAL and
  # provides only stubs.
  sources = [
    "alloc.cpp"
    "allocprof.cpp"
    "apply.cpp"
    "byteslice.cpp"
    "cadical.cpp"
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
    "wasi/stubs.cpp"
  ];

  # As upstream's release build of the runtime (src/CMakeLists.txt), minus -fPIC and
  # -ftls-model, which do not apply to a static wasm32 library. -Isrc/runtime/wasi makes io.cpp's
  # <uv.h> the stand-in.
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
    "-Isrc/runtime/wasi"
  ];

  # The stack in linear memory. Lean code keeps its locals in Wasm locals, on the engine's
  # stack, but some runtime functions have a frame here, among them `lean_apply_*`, through
  # which Lean calls closures. So recursion through closures uses this stack as well: with
  # wasm-ld's default of 64 KiB it ran out long before the engine's stack did (see
  # ../README.md). 8 MiB, what Lean gives threads on 32-bit targets (thread.cpp), is ample.
  stackSize = 8 * 1024 * 1024;

  # A derivation of their own, so that compiling Lean code does not depend on the runtime's
  # sources. config.h and version.h are those of the lean4 that generates our C, but without
  # mimalloc and with the actual target (the native build's target is empty with gcc and the
  # host's triple with clang).
  headers = runCommand "lean-headers-${lean4.version}" { } ''
    cp --no-preserve=mode ${lean4.src}/src/include/lean/lean.h .
    substitute ${lean4}/include/lean/config.h config.h --replace-fail "#define LEAN_MIMALLOC" ""
    sed -E 's|LEAN_PLATFORM_TARGET "[^"]*"|LEAN_PLATFORM_TARGET "${wasi.stdenv.hostPlatform.config}"|' \
      ${lean4}/include/lean/version.h > version.h
    grep -q '${wasi.stdenv.hostPlatform.config}' version.h
    install -Dm444 -t $out/include/lean lean.h config.h version.h
  '';
in
wasi.stdenv.mkDerivation {
  pname = "lean-runtime";
  inherit (lean4) version;

  # Copy just the runtime's part of the Lean source tree (700 MB in all), and our headers.
  unpackPhase = ''
    runHook preUnpack
    mkdir -p source/src
    cp -r --no-preserve=mode ${lean4.src}/src/{include,runtime,util} source/src/
    cp --no-preserve=mode ${headers}/include/lean/*.h source/src/include/lean/
    cd source
    runHook postUnpack
  '';

  postPatch = ''
    substitute ${lean4.src}/src/githash.h.in src/githash.h --replace-fail "@GIT_SHA1@" ""
  '';

  # The runtime has `throw`s, so it needs -fexceptions (see src/runtime/wasi/stubs.cpp). The
  # cc-wrapper appends -fno-exceptions after the command line, but NIX_CFLAGS_COMPILE comes after
  # that.
  env.NIX_CFLAGS_COMPILE = "-fexceptions";

  buildPhase = ''
    runHook preBuild
    for file in ${lib.concatMapStringsSep " " (f: "src/runtime/${f}") sources}; do
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

    # For linking libleanrt.a (and Lean code) into a module.
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
