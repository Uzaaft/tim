{
  description = "Zig project with ObjC interop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigPkg = zig.packages.${system}."0.15.2";
        isDarwin = pkgs.stdenv.isDarwin;
      in {
        devShells.default = pkgs.mkShellNoCC {
          name = "zig-dev";
          packages = [ zigPkg ];
          
          shellHook = ''
            echo "Zig development environment"
            echo "Zig version: $(zig version)"
            ${pkgs.lib.optionalString isDarwin ''
              # Zig needs the macOS SDK for frameworks
              export SDKROOT="$(xcrun --show-sdk-path)"
              echo "SDK: $SDKROOT"
            ''}
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zig-hello";
          version = "0.1.0";
          src = ./.;
          
          nativeBuildInputs = [ zigPkg ];
          
          buildPhase = ''
            zig build -Doptimize=ReleaseSafe --cache-dir .zig-cache --global-cache-dir .zig-cache
          '';
          
          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/* $out/bin/ || true
          '';
        };
      }
    );
}
