{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {self, nixpkgs, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
	system = "x86_64-linux";
	modules = [
	    ./configuration.nix
	    ./hardware-configuration.nix
	];
    };
    packages = builtins.mapAttrs (system: pkgs: {
      hello = pkgs.hello;

      default = self.packages.${system}.hello;
    }) nixpkgs.legacyPackages;
  };
}
