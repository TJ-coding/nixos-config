# Homepage — personal dashboard for the services running on this machine.
# Asset/config files live in ./config and are baked into the Nix build:
# deploy with: nixos-rebuild switch --flake .#artifacts
{ config, lib, pkgs, ... }:

let
  cfg = config.services.homepage;
in
{
  options.services.homepage = {
    enable = lib.mkEnableOption "Homepage dashboard";

    port = lib.mkOption {
      type = lib.types.int;
      default = 28088;
      description = "Public TCP port Homepage listens on (container port 3000).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Immutable copies of the repository assets: compose file + dashboard configs.
    environment.etc."homepage-compose.yml".source = ./docker-compose.yml;
    environment.etc."homepage/config".source = ./config;

    systemd.services.homepage = {
      wantedBy = [ "multi-user.target" ];

      after = [ "docker.service" ];
      requires = [ "docker.service" ];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";

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