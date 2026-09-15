{
  description = "Kohaku NixOS bootstrap";

  # This flake exists to be usable *before* the main flake can be evaluated.
  #
  # The main flake (../../flake.nix) takes `secrets` as an input:
  #
  #   secrets = { url = "git+ssh://git@github.com/TJ-coding/nixos-secrets.git"; }
  #
  # Nix fetches every input before it can call `outputs`, so on a host that has
  # no GitHub deploy key yet the whole main flake is unusable -- including the
  # enrollment helper that is supposed to set that key up. `nix run .#enroll`
  # therefore cannot be the first thing you run on a fresh host; it fails with
  # `Failed to fetch git repository 'ssh://git@github.com/TJ-coding/nixos-secrets.git'`.
  #
  # This flake depends on nixpkgs alone, so it always evaluates, and it exports
  # the same helpers:
  #
  #   nix run ./flakes/bootstrap#enroll          # credentials + hardware config
  #   nix run ./flakes/bootstrap#bootstrap-auth  # credentials only
  #
  # Once the deploy key and the age key are in place the main flake becomes
  # evaluable and `nix run .#enroll` works too.
  #
  # It also defines `nixosConfigurations.bootstrap`, the minimal system used to
  # bring a bare metal install to the point where it can reach the repository:
  #
  #   sudo nixos-rebuild switch --flake ./flakes/bootstrap#bootstrap
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.bootstrap =
        nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            ({ config, pkgs, ... }: {
              networking.networkmanager.enable = true;

              services.openssh.enable = true;

              users.users.tj-coding = {
                isNormalUser = true;
                extraGroups = [ "wheel" ];
                initialPassword = "changeme";
              };

              security.sudo.wheelNeedsPassword = false;

              environment.systemPackages = with pkgs; [
                git
                vim
                curl
                wget
                age
                sops
              ];

              system.stateVersion = "26.05";
            })
          ];
        };

      # `nix run ./flakes/bootstrap#enroll` resolves these: `nix run` falls back
      # to `packages.<system>.<name>` when there is no `apps` entry.
      packages.${system} = {
        bootstrap-auth = pkgs.callPackage ../../apps/bootstrap-auth.nix { };
        enroll = pkgs.callPackage ../../apps/bootstrap-enroll.nix { };
      };
    };
}
