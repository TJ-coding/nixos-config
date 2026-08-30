{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    kohaku-hub = {
      url = "github:KohakuBlueleaf/KohakuHub";
      flake = false;
    };
    rustfs = {
      url = "github:rustfs/rustfs-flake";
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

  devShells.default = nixpkgs.mkShell {
    packages = with nixpkgs; [
      mdbook
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
    packages = builtins.mapAttrs (system: pkgs: {
      hello = pkgs.hello;
	
      default = self.packages.${system}.hello;
    }) nixpkgs.legacyPackages;
  };
}
