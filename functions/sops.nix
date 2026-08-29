{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    sops
    age
  ];

  environment.sessionVariables = {
    SOPS_AGE_KEY_FILE = "/var/lib/sops-nix/infrastructure.age.key";
  };
  sops.age.keyFile = "/var/lib/sops-nix/infrastructure.age.key";
}