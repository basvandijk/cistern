{
  description = "cistern - a Canister Development Kit for Lean";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # Not x86_64-darwin: nixpkgs dropped it in 26.11.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The Lean → WebAssembly experiment, see experiments/lean-wasm.
      leanWasm = pkgs: import ./experiments/lean-wasm { inherit pkgs; };

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

      # The Lean canister experiment, which builds on lean-wasm, see experiments/lean-canister.
      leanCanister =
        pkgs:
        import ./experiments/lean-canister {
          inherit pkgs;
          leanWasm = leanWasm pkgs;
          pocket-ic = (pocketIc pkgs).pocket-ic or null;
          pocket-ic-py = (pocketIc pkgs).pocket-ic-py or null;
        };
    in
    {
      packages = forAllSystems (
        pkgs: (leanWasm pkgs).packages // (leanCanister pkgs).packages // pocketIc pkgs
      );

      checks = forAllSystems (
        pkgs:
        (leanWasm pkgs).checks
        // (leanCanister pkgs).checks
        // lib.optionalAttrs (pocketIc pkgs ? pocket-ic) {
          pocket-ic-runs = (pocketIc pkgs).pocket-ic.tests.runs;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            # Provides `lean` (the compiler/interpreter) and `lake` (the build tool).
            pkgs.lean4
            # `wasm-objdump` and friends, for inspecting .wasm files.
            pkgs.wabt
            # A WebAssembly runtime with WASI support, for running .wasm files.
            pkgs.wasmtime
          ]
          # `pocket-ic`, a local IC replica, for running canisters, and `python3` with pocketic-py,
          # its Python library.
          ++ lib.attrValues (pocketIc pkgs);
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
