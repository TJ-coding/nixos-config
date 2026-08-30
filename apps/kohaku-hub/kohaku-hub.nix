{ config, lib, pkgs, kohaku-hub, secrets, ... }:

let
  cfg = config.services.kohaku-hub;
  frontend = pkgs.callPackage ./frontend.nix {
    inherit kohaku-hub;
  };
in
{
  options.services.kohaku-hub = {
    enable = lib.mkEnableOption "KohakuHub";

    base-url = lib.mkOption {
      type = lib.types.str;
      default = "http://nixos.netbird.cloud:28080";
      description = "Public URL used by KohakuHub. This matches the exposed UI port in the compose stack.";
    };

    s3-endpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://host.docker.internal:9000";
    };

    secrets-path = lib.mkOption {
      type = lib.types.str;
      default = "secrets/kohaku-hub.env";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/kohaku-hub 0755 root root -"
      "d /var/lib/kohaku-hub/data 0755 root root -"
      "d /var/lib/kohaku-hub/data/hub-meta 0755 root root -"
    ];

    # Compose configuration.
    environment.etc."kohaku-hub-compose.yml".source =
      ./docker-compose.yml;

    # Secrets.
    sops.secrets."kohaku-hub-env" = {
      sopsFile = "${secrets}/${cfg.secrets-path}";
      format = "dotenv";
    };

    systemd.services.kohaku-hub = {
      wantedBy = [ "multi-user.target" ];

      after = [ "docker.service" ];
      requires = [ "docker.service" ];

      environment = {
        # Build from the immutable upstream source directly so Docker always sees the real repo root.
        KOHAKU_HUB_SOURCE = "${kohaku-hub}";
        KOHAKU_HUB_FRONTEND = "${frontend}";
        # Public configuration.
        KOHAKU_HUB_BASE_URL = cfg.base-url;
        KOHAKU_HUB_S3_ENDPOINT = cfg.s3-endpoint;

        # Immutable frontend builds.
        KOHAKU_HUB_UI_DIST = "${frontend}/ui";
        KOHAKU_HUB_ADMIN_DIST = "${frontend}/admin";
      };

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "${kohaku-hub}";
        EnvironmentFile = config.sops.secrets."kohaku-hub-env".path;
        Restart = "on-failure";
        RestartSec = "5s";

        ExecStart = lib.concatStringsSep " " [
          "${pkgs.docker}/bin/docker"
          "compose"
          "--env-file ${config.sops.secrets."kohaku-hub-env".path}"
          "-f /etc/kohaku-hub-compose.yml"
          "up"
          "--build"
          "--remove-orphans"
        ];

        ExecStop = lib.concatStringsSep " " [
          "${pkgs.docker}/bin/docker"
          "compose"
          "-f /etc/kohaku-hub-compose.yml"
          "down"
          "--remove-orphans"
        ];
      };
    };
  };
}