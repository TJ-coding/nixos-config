# Publishes (and keeps refreshing) the OpenAlex parquet snapshot in KohakuHub.
#
# The snapshot is read straight from OpenAlex's public S3 bucket and written into
# the hub as content-addressed Git-LFS objects, so no second copy of the data is
# kept on this host. Each file is uploaded once; later runs only add new or
# changed partitions and skip everything the hub already holds.
{ config, lib, pkgs, secrets, ... }:

let
  cfg = config.services.openalex-sync;

  openalex-sync = pkgs.writeShellApplication {
    name = "openalex-sync";
    runtimeInputs = [ pkgs.python3 pkgs.rclone ];
    text = ''
      exec python3 ${./openalex_sync.py} "$@"
    '';
  };
in
{
  options.services.openalex-sync = {
    enable = lib.mkEnableOption "OpenAlex snapshot sync into KohakuHub";

    hub-url = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:48888";
      description = "KohakuHub API endpoint on this host.";
    };

    dataset = lib.mkOption {
      type = lib.types.str;
      default = "tj-coding/openalex";
      description = "Hub dataset repository to publish into.";
    };

    source-endpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://openalex.s3.amazonaws.com";
      description = "Public OpenAlex S3 endpoint holding the parquet snapshot.";
    };

    source-prefix = lib.mkOption {
      type = lib.types.str;
      default = "data/parquet";
    };

    dest-endpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://192.168.10.125:9000";
      description = "S3 endpoint of the rustfs instance backing the hub's LFS store.";
    };

    dest-bucket = lib.mkOption {
      type = lib.types.str;
      default = "kohaku-hub";
    };

    entities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "authors" "awards" "concepts" "continents" "countries" "domains" "fields"
        "funders" "institution-types" "institutions" "keywords" "languages"
        "licenses" "publishers" "sdgs" "source-types" "sources" "subfields"
        "topics" "work-types" "works"
      ];
      description = "OpenAlex entity types to publish.";
    };

    workers = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Parallel downloads/uploads. Keep modest: the hub's storage is one SMR disk.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar expression for the refresh timer.";
    };

    secrets-path = lib.mkOption {
      type = lib.types.str;
      default = "secrets/artifacts/openalex-sync.env";
      description = "Secret file with HUB_TOKEN.";
    };
  };

  config = lib.mkIf cfg.enable {
    # HUB_TOKEN only. The S3 credentials for the LFS writes are the hub's own
    # (KOHAKU_HUB_S3_*), reused below so there is a single source of truth; that
    # secret is declared by services.kohaku-hub.
    sops.secrets."openalex-sync-env" = {
      sopsFile = "${secrets}/${cfg.secrets-path}";
      format = "dotenv";
    };

    systemd.services.openalex-sync = {
      description = "Sync the OpenAlex parquet snapshot into KohakuHub";
      wants = [ "network-online.target" "rustfs.service" "kohaku-hub.service" ];
      after = [ "network-online.target" "rustfs.service" "kohaku-hub.service" ];

      environment = {
        HUB_URL = cfg.hub-url;
        DATASET = cfg.dataset;
        SRC_ENDPOINT = cfg.source-endpoint;
        SRC_PREFIX = cfg.source-prefix;
        DST_ENDPOINT = cfg.dest-endpoint;
        DST_BUCKET = cfg.dest-bucket;
        ENTITIES = lib.concatStringsSep "," cfg.entities;
        WORKERS = toString cfg.workers;
      };

      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = [
          config.sops.secrets."openalex-sync-env".path
          config.sops.secrets."kohaku-hub-env".path
        ];
        ExecStart = "${openalex-sync}/bin/openalex-sync";
        # The very first run pulls the whole snapshot; later runs are minutes.
        TimeoutStartSec = "0";
        Nice = 10;
      };
    };

    systemd.timers.openalex-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
