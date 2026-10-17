{
  description = "cistern - a Canister Development Kit for Lean";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Not x86_64-darwin: nixpkgs dropped it in 26.11.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The Lean → WebAssembly experiment, see experiments/lean-wasm.
      leanWasm = pkgs: import ./experiments/lean-wasm { inherit pkgs; };
    in
    {
      packages = forAllSystems (pkgs: (leanWasm pkgs).packages);

      checks = forAllSystems (pkgs: (leanWasm pkgs).checks);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            # Provides `lean` (the compiler/interpreter) and `lake` (the build tool).
            pkgs.lean4
            # `wasm-objdump` and friends, for inspecting .wasm files.
            pkgs.wabt
            # A WebAssembly runtime with WASI support, for running .wasm files.
            pkgs.wasmtime
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
