# Installs and launches Netbird VPN service at boot time.
# Provides: Netbird
{ config, pkgs, ... }:
{
  services.netbird.enable = true;
  environment.systemPackages = with pkgs; [
      netbird
  ];

  # Configure Docker to use public DNS instead of NetBird's DNS listener.
  # Docker bridge traffic cannot currently query the NetBird DNS endpoint.
  virtualisation.docker.daemon.settings = {
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };
}
