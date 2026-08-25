# Standard server configuration.
# Provides:  SSH, netbird, and common server tooling.
# Warning: Opens SSH port
{ config, pkgs, ... }:
let
  bootstrap-auth = pkgs.callPackage ../apps/bootstrap-auth.nix {};
in
{
  imports =
    [ # Include the results of the hardware scan.
      ../functions/ssh.nix
      ../functions/vscode_remote_server.nix  
      ../functions/netbird.nix
      
  ];
  environment.systemPackages = with pkgs; [
      vim
      git 
      gh
      bootstrap-auth
  ];
}
