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
  environment.systemPackages = with pkgs; [
      vim
      git 
      gh
      bootstrap-auth
      openssl
      tree
      iputils
  ];
}
