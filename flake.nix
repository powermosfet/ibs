{
  description = "Iterative Barcode Searcher";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      source = nixpkgs.lib.cleanSourceWith {
        src = ./.;
        filter =
          path: type:
          let
            name = builtins.baseNameOf path;
          in
          !(builtins.elem name [
            "build"
            ".git"
            ".agents"
            ".codex"
            ".aws"
            ".env"
            "erl_crash.dump"
            "__pycache__"
          ])
          && !(nixpkgs.lib.hasPrefix "result" name);
      };
      packageFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          dependencies = import ./nix/dependencies.nix {
            inherit pkgs;
            manifest = ./manifest.toml;
          };
        in
        import ./nix/package.nix {
          inherit pkgs dependencies;
          src = source;
        };
    in
    {
      nixosModules = {
        default = self.nixosModules.ibs;
        ibs = { pkgs, lib, ... }: {
          imports = [ ./nix/module.nix ];
          services.ibs.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };
      };
      packages = eachSystem (system: {
        default = packageFor system;
        iterative-barcode-searcher = packageFor system;
      });
      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${packageFor system}/bin/iterative-barcode-searcher";
          meta.description = "Iterative Barcode Searcher";
        };
      });
      devShells = eachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              gleam
              beamPackages.erlang
              beamPackages.rebar3
              python3
            ];
          };
        }
      );
      checks = eachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          package = packageFor system;
          integration = import ./nix/integration.nix {
            inherit pkgs;
            package = packageFor system;
            module = self.nixosModules.default;
          };
        }
      );
    };
}
