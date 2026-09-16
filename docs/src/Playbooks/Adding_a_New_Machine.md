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

Run the repository's enrollment command **on the new machine**:

``` bash
cd ~/nixos-config
nix run ".?dir=flakes/bootstrap#enroll"
```

Pass the host name explicitly unless the machine's hostname happens to match
its flake attribute and host directory:

``` bash
nix run ".?dir=flakes/bootstrap#enroll" -- highperformancecomputing
```

Prefer the bootstrap flake for this first run: it depends on nixpkgs alone, so
no missing private input can affect it, and it carries
`nixosConfigurations.bootstrap` as well.

To be precise about why: flake inputs are lazy, so `nix run .#enroll` does
evaluate without a deploy key — evaluating `packages` never touches the private
`secrets` input. What fails before the key exists is anything that evaluates a
*host configuration*, which is what the rebuild after enrollment does:

``` text
$ nix eval .#nixosConfigurations.highperformancecomputing.config.system.build.toplevel.drvPath
error: Failed to fetch git repository 'ssh://git@github.com/TJ-coding/nixos-secrets.git'
```

Once the credentials are in place the two entry points are equivalent.

The `?dir=` form is what makes this work: `flakes/bootstrap` is a flake inside
this repository, and pointing Nix at the repository root keeps the helper
scripts in `apps/` reachable from it.

This generates `hosts/<hostname>/hardware-configuration.nix` and then runs
`bootstrap-auth`, which sets up the GitHub deploy key that makes the private
`secrets` flake input fetchable, the SOPS age key, and NetBird membership —
registering the peer with the shared setup key from `nixos-secrets` so it is not
subject to the account's Peer Session Expiration. NetBird is enrolled last, once
the age key exists to decrypt that setup key.

The credentials step is the one that is easy to get half-right — a deploy key
that exists but does not match the host's key looks fine and fails later with
`Permission denied (publickey)`. `bootstrap-auth` verifies each step and prints a
PASS/FAIL summary. See [Handling Secrets](./Handling_Secrets.md) for what it is
doing and how to do it by hand.

If the host will not use any secrets, it can be built without step 3's age key;
it simply cannot decrypt anything.

## 4. Configure the host

1. Open the configuration
    ``` bash
    nano ~/nixos-config/hosts/<host-name>/configuration.nix
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

1. Open the flake file
    ``` bash
    nano ~/nixos-config/flake.nix
    ```
2. Add a new `nixosConfigurations` entry
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
3. Replace `<host-name>` with the actual host name

`specialArgs` only needs the inputs that the host's templates actually use.
Passing `secrets` to a host that imports no secrets-using module is harmless but
pointless — and, as [Handling Secrets](./Handling_Secrets.md) explains, it is
also why a missing deploy key can stay hidden until the first secret is added.

If the host consumes secrets, its encrypted files belong in
`nixos-secrets/secrets/<host-name>/`, matching the flake attribute name.

## 6. Apply the configuration

1. Check the configuration
    ``` bash
    nix flake check --show-trace
    ```
2. Apply the configuration
    ``` bash
    sudo nixos-rebuild switch \
    --flake .#<host-name> \
    --show-trace
    ```
3. Confirm secrets landed, if the host uses them
    ``` bash
    sudo ls /run/secrets
    ```
