{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

  };


  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ ];
      };

      lib = pkgs.lib;
      in {
        devShells.default = pkgs.mkShell {
        nativeBuildInputs = [
        pkgs.odin
        pkgs.ols

        pkgs.openssl
        # used to set ELF interpreter, for nix -> other system compatibility https://github.com/NixOS/patchelf
        pkgs.patchelf
        ];

        # for ols
        #ODIN_ROOT = "${pkgs.odin}/share";
      };
    });
}
