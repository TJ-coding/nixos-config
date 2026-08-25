{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {self, nixpkgs, ... }: {
    nixosConfigurations.artifacts = nixpkgs.lib.nixosSystem {
	system = "x86_64-linux";
	modules = [
	    ./hosts/artifacts/configuration.nix
	    ./hosts/artifacts/hardware-configuration.nix
	];
    };
    packages = builtins.mapAttrs (system: pkgs: {
      hello = pkgs.hello;
	
      default = self.packages.${system}.hello;
    }) nixpkgs.legacyPackages;
  };
}
