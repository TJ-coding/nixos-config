{ config, lib, pkgs, rustfs, secrets, ... }:

{
  # =========================================================================
  # Options
  # =========================================================================

  options.services.lakefs = {
    base-url = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:8000";
      description = "The base URL of the lakeFS service.";
    };

    s3-endpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:9000";
      description = "The S3 endpoint used by lakeFS.";
    };

    lakefs-secrets-path = lib.mkOption {
      type = lib.types.str;
      default = "secrets/artifacts/lakefs.env";
      description = "Path to the SOPS-encrypted lakeFS environment file.";
    };
  };

  # =========================================================================
  # Configuration
  # =========================================================================

  config = {
    virtualisation.docker.enable = true;

    # -----------------------------------------------------------------------
    # Secrets
    # -----------------------------------------------------------------------

    sops.secrets."lakefs-env" = {
      sopsFile =
        "${secrets}/${config.services.lakefs.lakefs-secrets-path}";
      format = "dotenv";
    };

    # -----------------------------------------------------------------------
    # lakeFS
    # -----------------------------------------------------------------------

    systemd.services.lakefs = {
      wantedBy = [ "multi-user.target" ];

      after = [
        "docker.service"
        "network-online.target"
      ];

      requires = [
        "docker.service"
      ];

      wants = [
        "network-online.target"
      ];

      environment = {
        KOHAKUHUB_BASE_URL =
          config.services.lakefs.base-url;

        S3_ENDPOINT =
          config.services.lakefs.s3-endpoint;
      };

      serviceConfig = {
        EnvironmentFile =
          config.sops.secrets."lakefs-env".path;

        ExecStart =
          "${pkgs.docker}/bin/docker compose up --build";

        ExecStop =
          "${pkgs.docker}/bin/docker compose down";
      };
    };
  };
}