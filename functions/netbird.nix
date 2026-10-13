# Installs and launches the NetBird VPN service at boot time, and keeps the
# machine registered without a human at the keyboard.
# Provides: Netbird
{ config, lib, pkgs, secrets, ... }:

let
  nb = lib.getExe config.services.netbird.clients.default.wrapper;

  # The PAT does not exist yet (nixos-secrets/secrets/shared/netbird.yaml
  # carries only setup_key), but declaring a sops secret whose key is missing
  # from the file makes sops-install-secrets abort the whole activation --
  # which would brick every host on rebuild. The top-level key names in a
  # sops-encrypted YAML stay plaintext, so the presence check can run at
  # evaluation time. Once someone adds api_token to that file, the module
  # below activates with no further changes.
  hasApiToken = lib.hasInfix "api_token:" (builtins.readFile "${secrets}/secrets/shared/netbird.yaml");
in
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
  # and the machine drops off the mesh until somebody runs `netbird up` on it
  # by hand -- which is what artifacts, highperformancecomputing and aiagents
  # were doing roughly every 24 hours. Peers registered with a setup key are
  # exempt from session expiration, and netbird-login below is the oneshot
  # that enrols a not-yet-enrolled host with the key, so bringing a new
  # machine onto the mesh needs no human at the console.
  #
  # Two things a setup key cannot do, handled elsewhere:
  # - management refuses a setup-key login for a peer that was originally
  #   enrolled via SSO ("setup keys can only enrol new peers"). Such a peer
  #   has to be deleted in the dashboard once; the automation below then
  #   enrols it fresh with the setup key and it stays connected for good.
  #   functions/netbird-session-expiration.nix (imported below) is the
  #   alternative: with an api_token in the secrets file it flips the peer's
  #   login-expiration flag through the Management REST API instead.
  imports = [ ./netbird-session-expiration.nix ];

  # netbird-login is a oneshot that runs `netbird up`, which reads the key
  # from NB_SETUP_KEY_FILE. On a host that has not enrolled yet that is an
  # unattended login, so bringing a new machine onto the mesh needs no human
  # at the console.
  sops.secrets."netbird-setup-key" = {
    sopsFile = "${secrets}/secrets/shared/netbird.yaml";
    key = "setup_key";
  };

  services.netbird.clients.default.login = {
    enable = true;
    setupKeyFile = config.sops.secrets."netbird-setup-key".path;
  };
  # No extra systemdDependencies. The nixpkgs module doc suggests
  # `sops-install-secrets.service`, but that unit only exists when
  # `sops.useSystemdActivation = true`. With the default activation-script
  # mode the unit does not exist, and a `Requires=` on a missing unit makes
  # netbird-login *silently never start* -- which is exactly how the
  # auto-login was broken here for weeks (it had zero journal entries).
  # With activation-script mode the secrets are installed during system
  # activation, which always precedes boot-time services, so no dependency
  # is needed.

  # Replace the stock login script. The stock one only acts when the daemon
  # reports `NeedsLogin`, but a session that expires *while the daemon is
  # running* reports `SessionExpired` instead -- so the stock script spun
  # uselessly and the host stayed off the mesh. Act on both states, and on
  # anything else but a working connection just wait: `Connecting` and
  # `Disconnected` are transient states the daemon recovers from itself.
  systemd.services.netbird-login = {
    serviceConfig.RemainAfterExit = lib.mkForce false;
    script = lib.mkForce ''
      set -u

      attempt=0
      while [ "$attempt" -lt 30 ]; do
        status="$(${nb} status 2>&1 || true)"
        case "$status" in
          *": Connected"*)
            exit 0
            ;;
          *"NeedsLogin"* | *"SessionExpired"*)
            break
            ;;
        esac
        attempt=$((attempt + 1))
        sleep 2
      done
      [ "$attempt" -lt 30 ] || exit 0

      # NB_SETUP_KEY_FILE points at the mounted setup key and is picked up by
      # the CLI automatically, so `netbird up` logs in without a browser.
      # timeout caps the hang: for a peer still registered with a user login
      # the management server refuses a setup-key login, which is reported as
      # a failed unit; the timer below retries until the stale peer has been
      # deleted in the dashboard and this host can enrol as a new one.
      ${pkgs.coreutils}/bin/timeout 300 ${nb} up
    '';
  };

  # Session expiry fires while the machine is *running* (no reboot around
  # it), so a boot-time oneshot is not enough: re-check periodically and
  # re-login if the peer has fallen off. RemainAfterExit was forced off
  # above so the timer can re-trigger the unit.
  systemd.timers.netbird-login = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
      AccuracySec = "1min";
    };
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
