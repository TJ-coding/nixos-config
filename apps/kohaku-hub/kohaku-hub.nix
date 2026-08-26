{ config, pkgs, ... }:

{
  virtualisation.docker.enable = true;

  environment.etc."kohaku-hub".source = ./kohaku-hub;


  options.services.kohakuHub = {
    baseUrl = lib.mkOption {
      type = lib.types.str;
    };

    s3Endpoint = lib.mkOption {
      type = lib.types.str;
    };
  };
  
  systemd.services.kohaku-hub = {
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" ];
    requires = [ "docker.service" ];

    # Sets Environment variable KOHAKUHUB_SOURCE to the kohaku-hub input from flake.nix
    environment = {
      KOHAKUHUB_SOURCE = inputs.kohaku-hub;
      KOHAKUHUB_BASE_URL = config.services.kohakuHub.baseUrl;
      KOHAKUHUB_S3_ENDPOINT = config.services.kohakuHub.s3Endpoint;
    };

    serviceConfig = {
      WorkingDirectory = "/etc/kohaku-hub";

      ExecStart =
        "${pkgs.docker}/bin/docker compose up -d --build";

      ExecStop =
        "${pkgs.docker}/bin/docker compose down";
    };
  };
}