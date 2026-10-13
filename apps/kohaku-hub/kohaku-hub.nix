{ config, lib, pkgs, kohaku-hub, secrets, ... }:

let
  cfg = config.services.kohaku-hub;

  # Upstream (KohakuBlueleaf/KohakuHub @ 2facb54) has two issues that make the
  # dataset card slow to open on a large repo:
  #   0001 - the HF `siblings` list is resolved with one DB query per file
  #          (~34k lookups, 16 s for a 40k-file dataset)
  #   0002 - that list is always materialised even when the caller does not want
  #          it (6 MB / ~0.9 s TTFB for the same dataset)
  # Carry both locally until they land upstream, then drop this override and let
  # the flake input move forward.
  backendSource = pkgs.applyPatches {
    name = "kohaku-hub-src-patched";
    src = kohaku-hub;
    patches = [
      ./patches/0001-batch-hf-siblings-db-lookup.patch
      ./patches/0002-repo-info-include-siblings-flag.patch
    ];
  };

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
        KOHAKU_HUB_SOURCE = "${backendSource}";
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
        WorkingDirectory = "${backendSource}";
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