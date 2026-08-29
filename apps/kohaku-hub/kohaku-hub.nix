{ config, lib, pkgs, kohaku-hub, secrets, ... }:

{
  options.services.kohaku-hub = {
    base-url = lib.mkOption {
      type = lib.types.str;
    };

    s3-endpoint = lib.mkOption {
      type = lib.types.str;
    };

    secrets-path = lib.mkOption {
      type = lib.types.str;
      default = "secrets/kohaku-hub.env";
    };
  };

  config = {
    virtualisation.docker.enable = true;

    # Upstream KohakuHub source.
    environment.etc."kohaku-hub".source = kohaku-hub;

    # Deployment-specific Docker Compose configuration.
    environment.etc."kohaku-hub-compose.yml".source = ./docker-compose.yml;

    environment.etc."kohaku-hub-nginx.conf".source =
      "${kohaku-hub}/docker/nginx/default.conf";
    # KohakuHub secrets.
    sops.secrets."kohaku-hub-env" = {
      sopsFile =
        "${secrets}/${config.services.kohaku-hub.secrets-path}";
      format = "dotenv";
    };

    systemd.services.kohaku-hub = {
      wantedBy = [ "multi-user.target" ];

      after = [ "docker.service" ];
      requires = [ "docker.service" ];

      environment = {
        KOHAKUHUB_SOURCE = kohaku-hub;
        KOHAKUHUB_BASE_URL = config.services.kohaku-hub.base-url;
        KOHAKUHUB_S3_ENDPOINT = config.services.kohaku-hub.s3-endpoint;
      };

      serviceConfig = {
        WorkingDirectory = "/etc/kohaku-hub";

        EnvironmentFile =
          config.sops.secrets."kohaku-hub-env".path;

        ExecStart =
          "${pkgs.docker}/bin/docker compose -f /etc/kohaku-hub-compose.yml up --build";

        ExecStop =
          "${pkgs.docker}/bin/docker compose -f /etc/kohaku-hub-compose.yml down";
      };
    };
  };
}

#   #       preStart = ''
#   #   rm -rf /var/lib/kohaku-hub/ui-dist/*
#   #   cp -r ${kohaku-hub}/src/kohaku-hub-ui/. \
#   #     /var/lib/kohaku-hub/ui-dist/
# # 
#   #   rm -rf /var/lib/kohaku-hub/admin-dist/*
#   #   cp -r ${kohaku-hub}/src/kohaku-hub-admin/. \
#   #     /var/lib/kohaku-hub/admin-dist/