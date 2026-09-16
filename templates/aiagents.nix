# Host for running AI-agent workloads (VM 104 on the home-server hypervisor).
# Provides: SSH, NetBird, VS Code remote server and the shared server tooling
# declared by modules/servers.nix (which itself pulls in modules/common.nix).
# Warning: Opens SSH port
{config, pkgs, ...}:
{
  imports =
    [ # Include the results of the hardware scan.
      ../modules/servers.nix
    ];

  # Role-specific tooling for agent workloads goes below. Nothing is needed yet:
  # the server module already provides SSH, NetBird and the VS Code remote server.
}
