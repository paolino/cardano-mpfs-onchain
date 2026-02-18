{
  description = "Aiken validators for MPF";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Pre-fetched Aiken dependencies
        stdlib = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "stdlib";
          rev = "v2.2.0";
          hash = "sha256-BDaM+JdswlPasHsI03rLl4OR7u5HsbAd3/VFaoiDTh4=";
        };

        fuzz = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "fuzz";
          rev = "v2.1.1";
          hash = "sha256-oMHBJ/rIPov/1vB9u608ofXQighRq7DLar+hGrOYqTw=";
        };

        merkle-patricia-forestry = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "merkle-patricia-forestry";
          rev = "v2.0.0";
          hash = "sha256-uHVQxA1dYDuPbH+pf6SkGNBF7nBlDXdULrPFkfUDjzU=";
        };

        # TOML manifest that aiken expects in build/packages/
        packagesToml = pkgs.writeText "packages.toml" ''
          [[packages]]
          name = "aiken-lang/stdlib"
          version = "v2.2.0"
          source = "github"

          [[packages]]
          name = "aiken-lang/fuzz"
          version = "v2.1.1"
          source = "github"

          [[packages]]
          name = "aiken-lang/merkle-patricia-forestry"
          version = "v2.0.0"
          source = "github"
        '';

      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "mpf-plutus-blueprint";
          version = "0.0.0";

          src = pkgs.lib.cleanSource ./.;

          nativeBuildInputs = [ pkgs.aiken ];

          buildPhase = ''
            # Populate build/packages/ with copies (aiken needs write access)
            mkdir -p build/packages
            cp ${packagesToml} build/packages/packages.toml
            cp -r ${stdlib} build/packages/aiken-lang-stdlib
            cp -r ${fuzz} build/packages/aiken-lang-fuzz
            cp -r ${merkle-patricia-forestry} build/packages/aiken-lang-merkle-patricia-forestry
            chmod -R u+w build/packages

            aiken build
          '';

          installPhase = ''
            cp plutus.json $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.aiken
            pkgs.lean4
          ];
        };
      }
    );
}
