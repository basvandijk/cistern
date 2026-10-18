# PocketIC, a local Internet Computer replica for testing canisters, as built by ic-nix
# (https://github.com/ninegua/ic-nix).
#
# ic-nix is not a flake, and evaluating it fetches an unpinned rust-overlay, which a flake's
# pure evaluation does not allow. Building PocketIC from source would also take long: it is
# a part of the IC repository, and ic-nix's build of it needs the Motoko compiler too. So
# this uses ic-nix's prebuilt binary, which ic-nix's CI builds with Nix from the IC commit
# that mainnet was running (its nix/sources.nix). Its releases have it for x86_64-linux and
# aarch64-darwin only.
#
# To update, take a release from https://github.com/ninegua/ic-nix/releases. The hashes are
# GitHub's digests of its ic-binaries assets:
#   curl -s https://api.github.com/repos/ninegua/ic-nix/releases/tags/<release> |
#     jq -r '.assets[] | "\(.name) \(.digest)"'
# The version is the one that `pocket-ic --version` prints, which `tests.runs` checks.
#
# A derivation that runs PocketIC needs `cacert` as well, see `tests.runs`.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  runCommand,
  cacert,
  curl,
  jq,
}:
let
  release = "20261009";
  hashes = {
    x86_64-linux = "180a22c4f1259c02f86e6466aea7ba067a6e1a4434199264b04d1050b3dd0316";
    aarch64-darwin = "9730bb384e012e706f2c526aba7c28cdd70e62f3af756ab72e16ef559781fa69";
  };
  inherit (stdenv.hostPlatform) system;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "pocket-ic";
  version = "16.0.0";

  # All of ic-nix's binaries (dfx, moc, ic-wasm, ...), of which only pocket-ic is unpacked.
  src = fetchurl {
    url = "https://github.com/ninegua/ic-nix/releases/download/${release}/ic-binaries-${release}-${system}.tar.gz";
    sha256 = hashes.${system};
  };

  dontUnpack = true;

  # On Linux, the binary needs glibc and libgcc_s, but has an interpreter of
  # /lib64/ld-linux-x86-64.so.2. On macOS, it only needs system libraries.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.libgcc ];

  installPhase = ''
    runHook preInstall
    mkdir $out
    tar -xzf $src -C $out --strip-components=1 ic-binaries-${release}/bin/pocket-ic
    runHook postInstall
  '';

  # Keeps its symbol table, which the backtraces of panics use for function names.
  dontStrip = true;

  # Unpacking is quicker than sending the tarball (282 MB) to a remote builder.
  preferLocalBuild = true;

  # Starts the server in the sandbox, which has a loopback interface, and has it create an
  # instance (a replica) with one application subnet through its REST API. $out has the
  # version and the instance's topology.
  passthru.tests.runs =
    runCommand "pocket-ic-runs"
      {
        nativeBuildInputs = [
          finalAttrs.finalPackage
          # Each instance has an adapter for HTTPS outcalls, which fails to start without CA
          # certificates, and the instance with it; even if there are no outcalls (in the
          # sandbox, there is no network anyway). The stdenv sets SSL_CERT_FILE to
          # /no-cert-file.crt, and cacert's setup hook sets it to its certificates.
          cacert
          curl
          jq
        ];
      }
      ''
        pocket-ic --version > version.txt
        test "$(cat version.txt)" = "pocket-ic-server ${finalAttrs.version}"

        pocket-ic --port-file port &
        server=$!
        # The server writes its port, followed by a newline, once it listens.
        for _ in $(seq 300); do
          [ -s port ] && [ -z "$(tail -c 1 port)" ] && break
          sleep 0.1
        done
        url=http://127.0.0.1:$(cat port)

        curl -sSf --json '{
          "subnet_config_set": {
            "application": [{ "state_config": "New", "instruction_config": "Production" }],
            "system": [],
            "verified_application": []
          }
        }' $url/instances > instance.json
        instance=$(jq -e .Created.instance_id instance.json)
        curl -sSf -X DELETE $url/instances/$instance
        kill $server

        mkdir $out
        cp version.txt $out/
        jq .Created.topology instance.json > $out/topology.json
      '';

  meta = {
    description = "Local Internet Computer replica for testing canisters";
    homepage = "https://github.com/dfinity/pocketic";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames hashes;
    mainProgram = "pocket-ic";
  };
})
