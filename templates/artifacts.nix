# Server for Storing Large Artifacts
# Provides: 
# Warning: Opens SSH port
{ config, pkgs, kohaku-hub, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ../modules/servers.nix
      ../functions/docker_compose.nix
      # ../apps/kohaku-hub/kohaku-hub.nix
      ../modules/terminal-rice/terminal-rice.nix
    ];
}