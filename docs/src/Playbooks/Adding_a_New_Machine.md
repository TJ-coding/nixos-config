# Adding a New Machine

## 1. Install NixOS

Install a normal NixOS installation on the machine, following the [NixOS
manual](https://nixos.org/manual/nixos/stable/).
(If the machine is not applying this repository's configuration yet, the
bootstrap example in
[flakes/bootstrap/flake.nix](../../flakes/bootstrap/flake.nix) is a minimal
system for the first install.)

At this point the installer environment has **neither flakes nor the unified
`nix` CLI** enabled — they are experimental features, off until something turns
them on. That is what the next step is for.

## 2. Enable flakes and the `nix-command` CLI

This repository is a flake, so every command in this playbook needs
`nix-command` plus `flakes`. Enable them **before** enrolling, or `bootstrap-auth`
will stop with a message pointing back here.

### Option A — declarative (preferred, and what this repo does)

This is the durable fix: the features are declared in the configuration, so they
survive reboots and are not per-user state.

- Fleet-wide, for hosts that import `modules/common.nix` (which every server
template does), it is already declared:

  ``` nix
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  ```

- For a host that does not import `modules/common.nix` yet, add that line to
  `hosts/<host-name>/configuration.nix`.

See the manual for the option and the full list of features:
<https://nixos.org/manual/nixos/stable/#opt-nix.settings.experimental-features>

Because the features are not on yet, this first rebuild has to pass them on the
command line:

``` bash
sudo nixos-rebuild switch \
  --flake .#<host-name> \
  --show-trace \
  --extra-experimental-features 'nix-command flakes'
```

### Option B — imperative (temporary; no config of this repo needed)

Use this when the machine is brand new, or when you deliberately do not want to
touch its configuration — for instance during the very first bootstrap of
[flakes/bootstrap/flake.nix](../../flakes/bootstrap/flake.nix), which is what
`nixos-install` would use.

- For the current shell only:

  ``` bash
  export NIX_CONFIG="$(printf 'experimental-features = nix-command flakes\n')\n$NIX_CONFIG"
  ```

- Or persist for the current user:

  ``` bash
  mkdir -p ~/.config/nix
  printf 'experimental-features = nix-command flakes\n' >> ~/.config/nix/nix.conf
  ```

To confirm the features are active:

``` bash
nix config show experimental-features
# fetch-tree flakes nix-command
```

Two things that trip people up here:

- Nix reads its configuration **once, at start-up**. After enabling the features
durably, a shell that was already running still lacks them — open a new shell,
and remember that `nixos-rebuild` must be started *after* the rebuild that
enabled the features in order to see them.
- Any bare `nix` invocation made before the features are enabled needs
  `--extra-experimental-features 'nix-command flakes'`; that is why the clone
  step below spells it out.

## 3. Clone the repository

1. Install git
    ``` bash
    nix shell nixpkgs#git --extra-experimental-features 'nix-command flakes'
    ```
2. Then clone the repository:
    ``` bash
    git clone https://github.com/TJ-coding/nixos-config.git ~/nixos-config
    cd ~/nixos-config
    ```

## 4. Enroll the machine

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

## 5. Configure the host

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

## 6. Add the Configuration as a Flake

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

## 7. Apply the configuration

1. Check the configuration
    ``` bash
    nix flake check --show-trace
    ```
    If `nix` reports `experimental Nix feature 'nix-command' is disabled`,
    step 2 was skipped or the current shell predates it — see
    [2. Enable flakes and the `nix-command` CLI](#2-enable-flakes-and-the-nix-command-cli).
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
