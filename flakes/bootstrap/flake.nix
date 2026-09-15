{
  description = "Kohaku NixOS bootstrap";

  # This flake exists so the fresh-host entry point depends on nothing private.
  #
  # The main flake (../../flake.nix) takes `secrets` as an input:
  #
  #   secrets = { url = "git+ssh://git@github.com/TJ-coding/nixos-secrets.git"; }
  #
  # Flake inputs are lazy, so that is not fatal in itself: on a host with no
  # deploy key `nix build .#enroll` still succeeds, because evaluating
  # `packages` never touches `secrets`. What does force it is evaluating a *host
  # configuration*, which is what every rebuild is:
  #
  #   $ nix eval .#nixosConfigurations.highperformancecomputing.config.system.build.toplevel.drvPath
  #   error: Failed to fetch git repository 'ssh://git@github.com/TJ-coding/nixos-secrets.git'
  #
  # (So does anything that deliberately fetches every input, such as
  # `nix flake archive`.) The main flake therefore works right up to the moment
  # you want to build a machine -- which is exactly when enrollment has to work.
  #
  # This flake depends on nixpkgs alone, so it evaluates and builds with no
  # private access at all, and it exports the same helpers:
  #
  #   nix run ".?dir=flakes/bootstrap#enroll"          # credentials + hardware config
  #   nix run ".?dir=flakes/bootstrap#bootstrap-auth"  # credentials only
  #
  # Use the `?dir=` form: `./flakes/bootstrap#enroll` fails, because the helper
  # scripts it needs live in ../../apps/ and so fall outside that flake's root.
  #
  # Once the deploy key and the age key are in place the main flake is fully
  # usable, and `nix run .#enroll` behaves identically.
  #
  # It also defines `nixosConfigurations.bootstrap`, a minimal system for the
  # first install. It deliberately carries no filesystem or bootloader settings:
  # those are properties of the machine and there is no safe default to guess.
  # Generate them on the target and drop the file next to this one:
  #
  #   sudo nixos-generate-config --show-hardware-config > flakes/bootstrap/hardware-configuration.nix
  #   sudo nixos-rebuild switch --flake ".?dir=flakes/bootstrap#bootstrap"
  #
  # Until that file exists, `nixos-rebuild` on this attribute stops at NixOS's
  # assertions about `fileSystems` and `boot.loader`. The helpers above are not
  # affected either way -- `hardware-configuration.nix` is imported only if it is
  # there.
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
          ] ++ nixpkgs.lib.optional
            (builtins.pathExists ./hardware-configuration.nix)
            ./hardware-configuration.nix;
        };

      # `nix run ./flakes/bootstrap#enroll` resolves these: `nix run` falls back
      # to `packages.<system>.<name>` when there is no `apps` entry.
      packages.${system} = {
        bootstrap-auth = pkgs.callPackage ../../apps/bootstrap-auth.nix { };
        enroll = pkgs.callPackage ../../apps/bootstrap-enroll.nix { };
      };
    };
}
