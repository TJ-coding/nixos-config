{ config, pkgs, ... }:
{
# Required for vscode remote server
  programs.nix-ld.enable = true;
}