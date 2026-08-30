{
  description = "Kohaku NixOS bootstrap";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.bootstrap =
      nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          ({ config, pkgs, ... }: {
            networking.networkmanager.enable = true;

            services.openssh.enable = true;

            users.users.tj-coding = {
              isNormalUser = true;
              extraGroups = [ "wheel" ];
              initialPassword = "changeme";
            };

            security.sudo.wheelNeedsPassword = false;

            environment.systemPackages = with pkgs; [
              git
              vim
              curl
              wget
              age
              sops
            ];

            system.stateVersion = "26.05";
          })
        ];
      };
  };
}