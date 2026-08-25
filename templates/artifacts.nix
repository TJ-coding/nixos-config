# Server for Storing Large Artifacts
# Provides: 
# Warning: Opens SSH port
{ config, pkgs, ... }:
{
  imports =
    [ # Include the results of the hardware scan.
      ../modules/servers.nix
      ../functions/docker_compose.nix
    ];
}