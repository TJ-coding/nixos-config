{ config, lib, pkgs, rustfs, secrets, ... }:

{
  # Replace NixOS's bundled module with the module from the RustFS flake.
  disabledModules = [ "services/web-servers/rustfs.nix" ];
  imports = [ rustfs.nixosModules.default ];

  options.services.rustfs.volume_mounts = lib.mkOption {
    type = lib.types.str;
    default = "/mnt/s3data";
    description = "The path where rustfs will store its data.";
  };

  options.services.rustfs.open_ports = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "If true, the firewall will open ports 9000 and 9001 for rustfs.";
  };

  options.services.rustfs.rustfs-secrets-path = lib.mkOption {
    type = lib.types.str;
    default = "secrets/artifacts/rustfs.yaml";
    description = "The path to the sops-encrypted secrets file for rustfs.";
  };

  config = {
    sops.secrets."rustfs-access-key" = {
      sopsFile = "${secrets}/${config.services.rustfs.rustfs-secrets-path}";
      key = "access_key";
    };

    sops.secrets."rustfs-secret-key" = {
      sopsFile = "${secrets}/${config.services.rustfs.rustfs-secrets-path}";
      key = "secret_key";
    };

    services.rustfs = {
      enable = true;
      package = rustfs.packages.${pkgs.stdenv.hostPlatform.system}.default;

      accessKeyFile = config.sops.secrets."rustfs-access-key".path;
      secretKeyFile = config.sops.secrets."rustfs-secret-key".path;
      volumes = config.services.rustfs.volume_mounts;
      address = ":9000";
      consoleEnable = true;
      consoleAddress = ":9001";
    };

    networking.firewall.allowedTCPPorts =
      lib.mkIf config.services.rustfs.open_ports [ 9000 9001 ];
  };
}
