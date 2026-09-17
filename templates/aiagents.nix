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

  # The agent's shell reaches the rest of the fleet over NetBird. A missing
  # host key aborts ssh with "Host key verification failed" — that is what
  # stalled the ACL26 conversation — so declare the keys it needs, and accept
  # new ones on first contact (the mesh, not ssh's prompt, is the trust
  # boundary here; nothing in this UI can answer "yes" to a prompt).
  programs.ssh = {
    knownHosts.hpc = {
      hostNames = [ "hpc.netbird.cloud" "100.82.96.15" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOD5q9AwyUCZb5QEqTRE9dEKHS+2GwbnmoleWAVwozut";
    };
    extraConfig = ''
      StrictHostKeyChecking accept-new
    '';
  };

  # pi-web-ui drives a coding agent that can run bash and write files as
  # tj-coding, so the port is opened per interface — the LAN and the NetBird
  # tunnel only. A global rule would also expose this host's public IPv6.
  services.pi-web-ui = {
    enable = true;
    user = "tj-coding";
    workspace = "/home/tj-coding";
    # The agent's starting directory (and the project the UI opens on). The
    # ACL26 conversation was moved here from the Mac, transcripts included, so
    # this is where its history lives.
    cwd = "/home/tj-coding/Projects/acl26";
    port = 8787;

    firewallInterfaces = [ "ens18" "wt0" ];

    # No PI_WEB_TOKEN: the token flow needs one `?token=…` visit per origin, which
    # is friction when the same service is reached over both the LAN address and
    # the NetBird name. Access is instead gated by the interface-scoped firewall
    # above plus this Host allow-list.
    token = false;

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
