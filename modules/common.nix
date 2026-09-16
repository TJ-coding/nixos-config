{ config, pkgs, ... }:
let
  bootstrap-auth = pkgs.callPackage ../apps/bootstrap-auth.nix {};
in
{
  imports =
    [ # Include the results of the hardware scan.
      ../functions/netbird.nix
      ../functions/sops.nix
  ];

  # Every host in this fleet is rebuilt from this repository's flake, which
  # requires the `nix-command` and `flakes` experimental features. Declaring them
  # here is what makes that true for a host that imports this module, so a new
  # machine cannot be enrolled and then fail at its first rebuild: `bootstrap-auth`
  # checks for them and points at this option when they are missing.
  #
  # Both aiagents and highperformancecomputing also list them in their own
  # configuration.nix. That is redundant, not harmful -- different host modules
  # setting the same value is exactly what happens here, and NixOS keeps one copy
  # as long as the lists are identical. If you edit one, edit the other, or drop
  # the per-host line deliberately.
  #
  # Nix only reads `nix.conf` at start-up, so a session that was already running
  # when the features were enabled still needs them passed explicitly, e.g.
  # `nix shell --extra-experimental-features 'nix-command flakes' nixpkgs#git`.
  # See https://nixos.org/manual/nixos/stable/#opt-nix.settings.experimental-features
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [
      vim
      git 
      gh
      bootstrap-auth
      openssl
      tree
      iputils
      tmux
      htop
      iotop
      nixos-rebuild
      nix-output-monitor
  ];
}
