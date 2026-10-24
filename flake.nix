{
  description = "cistern - a Canister Development Kit for Lean";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The Lean that everything uses: the `cistern` branch of the basvandijk fork of lean4, which is
    # the upstream commit of the nightly that lean-toolchain names plus cistern's commits (see
    # README.md). Not a flake: nix/lean4.nix builds the compiler from its sources, and
    # nix/lean-runtime.nix the wasm32 runtime. `nix flake update lean4` moves it to the branch's head.
    lean4 = {
      url = "github:basvandijk/lean4/cistern";
      flake = false;
    };
    # The Candid specification's repository, for its conformance suite (candid/nix/conformance.nix)
    # and the test files of its Rust parser (candid/nix/tests.nix). Not a flake: only its files
    # are used. `nix flake update candid` moves it to the latest commit, and flake.lock records
    # which one.
    candid = {
      url = "github:dfinity/candid";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Not x86_64-darwin: nixpkgs dropped it in 26.11.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The upstream nightly whose commit the `cistern` branch of `lean4` is based on. lean-toolchain
      # must name it (nix/lean-files-open.nix checks that), so that the editor's Lean elaborates the
      # same library as the flake's. Update it with the branch, see README.md.
      nightly = "nightly-2026-10-24";

      # Replaces nixpkgs' lean4 with the one built from the `lean4` input (nix/lean4.nix), for every
      # `callPackage` below and the dev shell.
      overlay = final: prev: {
        lean4 = final.callPackage ./nix/lean4.nix {
          lean4 = prev.lean4;
          src = inputs.lean4;
          inherit nightly;
        };
      };
      forAllSystems =
        f: lib.genAttrs systems (system: f (nixpkgs.legacyPackages.${system}.extend overlay));

      # The Lean runtime, Init and Std.Async.Basic for wasm32-wasip1, which the Candid library and
      # the canister link (nix/lean-runtime.nix, nix/lean-libs.nix).
      wasm32 = pkgs: rec {
        # clang + wasi-libc + libc++ targeting wasm32-unknown-wasip1, the nixpkgs counterpart of
        # wasi-sdk.
        wasi = pkgs.pkgsCross.wasi32;
        runtime = pkgs.callPackage ./nix/lean-runtime.nix { inherit wasi; };
        libs = pkgs.callPackage ./nix/lean-libs.nix { inherit wasi runtime; };
      };

      # The Candid library, see candid. It is compiled for wasm32 with the runtime above.
      candid =
        pkgs:
        import ./candid {
          inherit pkgs;
          inherit (wasm32 pkgs) wasi runtime;
          candidSrc = inputs.candid;
        };

      # PocketIC, a local IC replica, from ic-nix (see nix/pocket-ic.nix), and pocketic-py, its
      # Python library, in a Python environment (see nix/pocket-ic-py.nix). An attribute set,
      # which is empty on aarch64-linux: ic-nix has no binary for it.
      pocketIc =
        pkgs:
        let
          pocket-ic = pkgs.callPackage ./nix/pocket-ic.nix { };
          pocket-ic-py = pkgs.callPackage ./nix/pocket-ic-py.nix { };
        in
        lib.optionalAttrs (lib.meta.availableOn pkgs.stdenv.hostPlatform pocket-ic) {
          inherit pocket-ic pocket-ic-py;
        };

      # The Lean canister experiment, which links the runtime and libraries above and uses the Candid
      # library, see experiments/lean-canister.
      leanCanister =
        pkgs:
        import ./experiments/lean-canister {
          inherit pkgs;
          inherit (wasm32 pkgs) wasi runtime;
          inherit ((wasm32 pkgs).libs) init std;
          candid = candid pkgs;
          pocket-ic = (pocketIc pkgs).pocket-ic or null;
          pocket-ic-py = (pocketIc pkgs).pocket-ic-py or null;
        };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          w = wasm32 pkgs;
        in
        {
          # The native Lean, built from the `lean4` input; what CI's store keeps.
          lean4 = pkgs.lean4;
          lean-runtime = w.runtime;
          lean-init-c = w.libs.initC;
          lean-std-c = w.libs.stdC;
          lean-init = w.libs.init;
          lean-std = w.libs.std;
        }
        // (candid pkgs).packages
        // (leanCanister pkgs).packages
        // pocketIc pkgs
      );

      checks = forAllSystems (
        pkgs:
        (candid pkgs).checks
        // (leanCanister pkgs).checks
        // lib.optionalAttrs (pocketIc pkgs ? pocket-ic) {
          pocket-ic-runs = (pocketIc pkgs).pocket-ic.tests.runs;
        }
        // {
          # Each .lean file opens in an editor without errors, see nix/lean-files-open.nix.
          lean-files-open = pkgs.callPackage ./nix/lean-files-open.nix { };
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            # Provides `lean` (the compiler/interpreter) and `lake` (the build tool), built from the
            # `lean4` input.
            pkgs.lean4
            # `wasm-objdump` and friends, for inspecting .wasm files.
            pkgs.wabt
          ]
          # `pocket-ic`, a local IC replica, for running canisters, and `python3` with pocketic-py,
          # its Python library.
          ++ lib.attrValues (pocketIc pkgs);
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
