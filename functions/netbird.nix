# Installs and launches Netbird VPN service at boot time.
# Provides: Netbird
{ config, pkgs, ... }:
{
  services.netbird.enable = true;
  environment.systemPackages = with pkgs; [
      netbird
  ];
}
