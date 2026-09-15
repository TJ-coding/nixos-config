{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    kohaku-hub = {
      url = "github:KohakuBlueleaf/KohakuHub";
      flake = false;
    };
    # Pinned to the tip of rustfs-flake PR #64 (automation/update-sources-1.0.0-rc.5,
    # commit c17daec) which packages rustfs 1.0.0-rc.5. The flake's main branch still
    # ships 1.0.0-rc.1, which has erasure block-size bugs (zero-block_size divide-by-zero
    # in codec streaming reads #4340, inline-threshold div_ceil rounding #6390, 1MiB GET
    # mid-size reader #6861, large-file upload freeze). Once PR #64 is merged into main,
    # revert this to: url = "github:rustfs/rustfs-flake";
    #
    # Pinning matters operationally: artifacts runs 1.0.0-rc.5, so leaving this
    # unpinned makes the next rebuild of that host silently downgrade rustfs.
    rustfs = {
      url = "github:rustfs/rustfs-flake/c17daecdea77793da5de2cba081477178130f300";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    secrets = {
      url = "git+ssh://git@github.com/TJ-coding/nixos-secrets.git";
      flake = false;
    };
      sops-nix = {
    url = "github:Mic92/sops-nix/master";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  };

  outputs = {self, nixpkgs, kohaku-hub, rustfs, secrets, sops-nix }: {

  devShells.x86_64-linux.default =
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in
  pkgs.mkShell {
    packages = [
      pkgs.mdbook
      pkgs.mdbook-mermaid
    ];
  };
    nixosConfigurations.artifacts = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        kohaku-hub = kohaku-hub;
        rustfs = rustfs;
        secrets = secrets;
      };
      modules = [
          ./hosts/artifacts/configuration.nix
          ./hosts/artifacts/hardware-configuration.nix
          sops-nix.nixosModules.sops
      ];
    };
    nixosConfigurations.highperformancecomputing = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        kohaku-hub = kohaku-hub;
        rustfs = rustfs;
        secrets = secrets;
      };
      modules = [
          ./hosts/highperformancecomputing/configuration.nix
          ./hosts/highperformancecomputing/hardware-configuration.nix
          sops-nix.nixosModules.sops
      ];
    };
    packages = builtins.mapAttrs (system: pkgs: {
      hello = pkgs.hello;

      default = self.packages.${system}.hello;
    } // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # Machine bootstrap helpers. `nix run .#enroll` is the first thing to run
      # on a fresh host; see docs/src/Playbooks/Handling_Secrets.md.
      bootstrap-auth = pkgs.callPackage ./apps/bootstrap-auth.nix { };
      enroll = pkgs.callPackage ./apps/bootstrap-enroll.nix { };
    }) nixpkgs.legacyPackages;
  };
}
