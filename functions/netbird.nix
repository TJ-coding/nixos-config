# Installs and launches the NetBird VPN service at boot time, and keeps the
# machine registered without a human at the keyboard.
# Provides: Netbird
{ config, pkgs, secrets, ... }:
{
  services.netbird.enable = true;
  environment.systemPackages = with pkgs; [
      netbird
  ];

  # Register with a NetBird *setup key*, not interactive SSO login.
  #
  # Peers enrolled through SSO login inherit the account's "Peer Session
  # Expiration" (24h by default). When it fires, management answers
  # `PermissionDenied desc = peer login has expired, please log in once more`
  # and the machine drops off the mesh until somebody runs `netbird up` on it by
  # hand -- which is what artifacts and highperformancecomputing were doing
  # roughly every 24 hours. Peers registered with a setup key are exempt from
  # session expiration.
  #
  # clients.default.login is a oneshot that waits for the daemon to report
  # `NeedsLogin`, then runs `netbird up`, which reads the key from
  # NB_SETUP_KEY_FILE. On a host that has not enrolled yet that is an unattended
  # login, so bringing a new machine onto the mesh needs no human at the console.
  sops.secrets."netbird-setup-key" = {
    sopsFile = "${secrets}/secrets/shared/netbird.yaml";
    key = "setup_key";
  };

  services.netbird.clients.default.login = {
    enable = true;
    setupKeyFile = config.sops.secrets."netbird-setup-key".path;
    # The key does not exist until sops-nix has decrypted it.
    systemdDependencies = [ "sops-install-secrets.service" ];
  };

  # Configure Docker to use public DNS instead of NetBird's DNS listener.
  # Docker bridge traffic cannot currently query the NetBird DNS endpoint.
  virtualisation.docker.daemon.settings = {
    dns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };
}
