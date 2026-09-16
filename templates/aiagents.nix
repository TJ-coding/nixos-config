# Host for running AI-agent workloads (VM 104 on the home-server hypervisor).
# Provides: SSH, NetBird, VS Code remote server and the shared server tooling
# declared by modules/servers.nix (which itself pulls in modules/common.nix),
# plus the pi coding agent's web cockpit (apps/pi-web-ui).
# Warning: Opens SSH port
{config, pkgs, ...}:
{
  imports =
    [ # Include the results of the hardware scan.
      ../modules/servers.nix
      ../apps/pi-web-ui/pi-web-ui.nix
    ];

  # pi-web-ui drives a coding agent that can run bash and write files as
  # tj-coding, so the port is opened per interface — the LAN and the NetBird
  # tunnel only. A global rule would also expose this host's public IPv6.
  services.pi-web-ui = {
    enable = true;
    user = "tj-coding";
    workspace = "/home/tj-coding";
    port = 8787;

    firewallInterfaces = [ "ens18" "wt0" ];

    # Strict Host-header allow-list, on top of the always-on same-authority
    # check. PI_WEB_TOKEN (generated on first start) is the actual credential.
    allowedHosts = [
      "localhost"
      "127.0.0.1"
      "192.168.10.130"
      "100.82.164.233"
      "nixos-164-233.netbird.cloud"
      "aiagents.netbird.cloud"
    ];
  };
}
