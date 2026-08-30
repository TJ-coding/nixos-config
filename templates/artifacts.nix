# Server for Storing Large Artifacts
# Provides: 
# Warning: Opens SSH port
{config, pkgs, kohaku-hub, secrets, sops-nix, ...}:
{
  imports =
    [ 
      ../modules/servers.nix
      ../functions/docker_compose.nix
      ../modules/terminal-rice/terminal-rice.nix
      ../functions/rustfs.nix
      ../apps/kohaku-hub/kohaku-hub.nix
    ];
    # RustFS Configuration
    services.rustfs = {
    volume_mounts = "/mnt/s3data";
    open_ports = true;
    rustfs-secrets-path = "secrets/artifacts/rustfs.yaml";
  };
    services.kohaku-hub = {
    enable = true;
    s3-endpoint = "http://192.168.10.125:9000";
    base-url = "http://nixos.netbird.cloud:28080";
    secrets-path = "secrets/artifacts/kohaku-hub.env";
};
}