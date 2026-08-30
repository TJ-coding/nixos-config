# Adding a New Machine

## 1. Install NixOS

Install a normal NixOS installation on the machine.

## 2. Clone the repository

1. Install git
    ``` bash
    nix shell nixpkgs#git --extra-experimental-features 'nix-command flakes'
    ```
2. Then clone the repository:
    ``` bash
    git clone https://github.com/TJ-coding/nixos-config.git ~/nixos-config 
    cd ~/nixos-config
    ```

## 3. Enroll the machine

* Run the repository's enrollment command:
    ``` bash
    nix run .#enroll
    ```

## 4. Configure the host

1. Open the configuration 
    ```
    nano ~/hosts/<host-name>/configuration.nix
    ```
2. Add a template to the configuration file
    ``` nix
    imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../templates/artifacts.nix
    ];
    ```

## 5. Add the Configuration as a Flake
    1. open flake file
        ``` nix
        nano flake.nix
        ```
    2. add a new flake
    ``` nix
    nixosConfigurations.<host-name> = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        kohaku-hub = kohaku-hub;
        rustfs = rustfs;
        secrets = secrets;
      };
      modules = [
          ./hosts/<host-name>/configuration.nix
          ./hosts/<host-name>/hardware-configuration.nix
          sops-nix.nixosModules.sops
      ];
    };
    ```
    3. replace `<host-name>` with the actual host name

## 6. Apply the configuration

1. Check the Configuration
    ``` nix
    nix flake check --show-trace
    ```
2. Apply the Configuration
    ``` nix
    sudo nixos-rebuild switch \
    --flake .#my-host \
    --show-trace
    ```