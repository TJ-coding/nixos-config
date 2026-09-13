# Homepage — personal dashboard for the services running on this machine.
# Asset/config files live in ./config and are baked into the Nix build:
# deploy with: nixos-rebuild switch --flake .#artifacts
#
# NOTE: Homepage v1 writes its own log files to <config>/logs, so /app/config
# must be WRITABLE (a read-only mount makes every request 500). Assets stay
# Nix-managed: the store copy is synced into /var/lib/homepage/config before
# each start, and any change to compose/config bumps the unit text so
# switch-to-configuration restarts the stack.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.homepage;
in
{
  options.services.homepage = {
    enable = lib.mkEnableOption "Homepage dashboard";

    port = lib.mkOption {
      type = lib.types.int;
      default = 8080;
      description = "Public TCP port Homepage listens on (container port 3000).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Compose file for the stack.
    environment.etc."homepage-compose.yml".source = ./docker-compose.yml;

    systemd.tmpfiles.rules = [
      "d /var/lib/homepage 0755 root root -"
    ];

    systemd.services.homepage = {
      wantedBy = [ "multi-user.target" ];

      after = [ "docker.service" ];
      requires = [ "docker.service" ];

      # Compose edits don't change ExecStart's arguments (/etc/homepage-compose.yml
      # keeps its name), so force a restart when the compose file changes.
      # Config changes are already covered: their store path appears in
      # ExecStartPre below, which changes the unit text.
      restartTriggers = [
        (builtins.hashString "sha256" (toString ./docker-compose.yml))
      ];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";

        ExecStartPre = [
          (lib.concatStringsSep " " [
            "${pkgs.coreutils}/bin/mkdir" "-p" "/var/lib/homepage/config"
          ])
          (lib.concatStringsSep " " [
            "${pkgs.coreutils}/bin/cp" "-rT" "--no-preserve=mode"
            "${./config}" "/var/lib/homepage/config"
          ])
        ];

        ExecStart = lib.concatStringsSep " " [
          "${pkgs.docker}/bin/docker"
          "compose"
          "-f /etc/homepage-compose.yml"
          "up"
          "--remove-orphans"
        ];

        ExecStop = lib.concatStringsSep " " [
          "${pkgs.docker}/bin/docker"
          "compose"
          "-f /etc/homepage-compose.yml"
          "down"
          "--remove-orphans"
        ];
      };
    };
  };
}