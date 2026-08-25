{ pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    package = pkgs.docker;
  };

  environment.systemPackages = with pkgs; [
    docker-compose
  ];
}