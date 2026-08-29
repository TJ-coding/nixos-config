# Server for Storing Large Artifacts
# Provides: 
# Warning: Opens SSH port
{config, pkgs, kohaku-hub, secrets, sops-nix, ...}:
{
  imports =
    [ # Include the results of the hardware scan.
      ../modules/servers.nix
      ../functions/docker_compose.nix
      # ../apps/kohaku-hub/kohaku-hub.nix
      ../modules/terminal-rice/terminal-rice.nix
      ../functions/rustfs.nix
      ../apps/lakefs/lakefs.nix
    ];
    # RustFS Configuration
    services.rustfs = {
    volume_mounts = "/mnt/s3data";
    open_ports = true;
    rustfs-secrets-path = "secrets/artifacts/rustfs.yaml";
  };
    services.lakefs = {
    s3-endpoint = "http://localhost:9000";
    s3-secrets-path = "secrets/artifacts/rustfs.yaml";
    lakefs-secrets-path = "secrets/artifacts/lakefs.env";
};
}