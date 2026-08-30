# Nix Config Architecture

This repository is organized as a small NixOS flake that models a single machine (`artifacts`) with a declarative host configuration, reusable templates, and a few service-specific modules. The overall pattern is: define a machine in one place, import reusable modules, and keep sensitive configuration in a SOPS-managed secrets repository.

## 1. The flake is the entrypoint

The root file [flake.nix](../../flake.nix) is the top-level configuration for the system. It does four important things:

- pins the upstream inputs:
  - `nixpkgs`
  - `kohaku-hub`
  - `rustfs`
  - `secrets`
  - `sops-nix`
- defines a NixOS system via `nixosConfigurations.artifacts`
- passes special arguments such as `kohaku-hub`, `rustfs`, and `secrets` into the modules
- enables the SOPS module with `sops-nix.nixosModules.sops`

The current deployment target is the `artifacts` host:

```nix
nixosConfigurations.artifacts = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = {
    kohaku-hub = kohaku-hub;
    rustfs = rustfs;
    secrets = secrets;
  };
  modules = [
    ./hosts/artifacts/configuration.nix
    ./hosts/artifacts/hardware-configuration.nix
    sops-nix.nixosModules.sops
  ];
};
```

That means the machine's actual state is assembled by Nix at evaluation time rather than by ad hoc shell commands.

## 2. Host configuration is deliberately separate from reusable logic

The actual machine config lives in [hosts/artifacts/configuration.nix](../../hosts/artifacts/configuration.nix). It is intentionally lean and mostly focused on machine-specific concerns:

- hostname
- bootloader
- timezone and locale
- desktop/X configuration
- SSH and firewall policy
- NetBird enablement
- the host-specific import of the machine template

The host imports the artifact template:

- [templates/artifacts.nix](../../templates/artifacts.nix)

This is the central composition file for the machine. It imports the common server modules and the service modules that make up the workload stack.

## 3. The template is the workload composition layer

[templates/artifacts.nix](../../templates/artifacts.nix) acts as the machine's service assembly file. It imports:

- [modules/servers.nix](../../modules/servers.nix)
- [functions/docker_compose.nix](../../functions/docker_compose.nix)
- [modules/terminal-rice/terminal-rice.nix](../../modules/terminal-rice/terminal-rice.nix)
- [functions/rustfs.nix](../../functions/rustfs.nix)
- [apps/kohaku-hub/kohaku-hub.nix](../../apps/kohaku-hub/kohaku-hub.nix)

Then it sets the runtime values for the services, for example:

```nix
services.rustfs = {
  volume_mounts = "/mnt/s3data";
  open_ports = true;
  rustfs-secrets-path = "secrets/artifacts/rustfs.yaml";
};

services.kohaku-hub = {
  enable = true;
  s3-endpoint = "http://host.docker.internal:9000";
  base-url = "http://nixos.netbird.cloud:28080";
  secrets-path = "secrets/artifacts/kohaku-hub.env";
};
```

This is the place where the operator decides which workloads are enabled and what their deployment-specific parameters are.

## 4. Reusable modules are separated by responsibility

### Common server layer

[modules/servers.nix](../../modules/servers.nix) defines the common operating-system base for server-style hosts:

- SSH
- NetBird
- common tooling
- other shared services

### Docker Compose support

[functions/docker_compose.nix](../../functions/docker_compose.nix) ensures the host has Docker Compose available for service-managed stacks.

### NetBird

[functions/netbird.nix](../../functions/netbird.nix) enables the VPN client and configures Docker DNS so container traffic does not get trapped behind NetBird's DNS listener.

### RustFS

[functions/rustfs.nix](../../functions/rustfs.nix) defines the S3-compatible storage service, including secret file handling and firewall/tcp exposure. It is part of the storage backend supporting the Dockerized app stack.

## 5. KohakuHub is a Nix module that owns a Compose stack

The real application service is defined in [apps/kohaku-hub/kohaku-hub.nix](../../apps/kohaku-hub/kohaku-hub.nix).

This module does a few things:

- creates a `services.kohaku-hub` Nix option set
- declares the service with `enable`, `base-url`, `s3-endpoint`, and `secrets-path`
- builds the frontend from the upstream `kohaku-hub` source with `pkgs.callPackage ./frontend.nix`
- creates the SOPS secret path for the environment file
- injects the runtime environment into a systemd service
- starts the Docker Compose stack from [apps/kohaku-hub/docker-compose.yml](../../apps/kohaku-hub/docker-compose.yml)

The compose file defines the application topology:

- `hub-ui` (nginx frontend)
- `hub-api` (application backend)
- `lakefs`
- `postgres`
- `valkey`

The important detail is that the Docker stack is not a separate hand-managed setup: it is a declarative systemd service anchored by the Nix module and the generated compose file under `/etc`.

## 6. Secret management uses SOPS as the source of truth

This repository treats secrets as declarative infrastructure, not as ad hoc generated files.

The critical pieces are:

- [functions/sops.nix](../../functions/sops.nix)
- the `secrets` flake input in [flake.nix](../../flake.nix)
- the `sops.secrets.*` definitions in the service modules

For example, the KohakuHub service does this:

```nix
sops.secrets."kohaku-hub-env" = {
  sopsFile = "${secrets}/${cfg.secrets-path}";
  format = "dotenv";
};
```

and then loads it into the service with:

```nix
EnvironmentFile = config.sops.secrets."kohaku-hub-env".path;
```

This means the runtime values come from the SOPS-encrypted secret repo, decrypted by the configured age key and exposed at `/run/secrets/...` during activation. The repository is therefore intentionally aligned with the rule: secrets are managed by SOPS, and the Nix module merely wires them into the systemd environment.

## 7. Why this architecture is useful

This setup gives a few practical advantages:

- reproducibility: the exact input pins and Nix evaluation define the machine
- separation of concerns: host config, service config, and shared modules are not mixed together
- portability: the same Nix modules can be lifted to another machine by changing the host template or service settings
- secret safety: sensitive values are stored outside the repo in the SOPS-managed external secrets store
- clear ownership: each service has its own module and its own deployment configuration

## 8. Typical edit patterns

When changing the system:

- edit host behavior in [hosts/artifacts/configuration.nix](../../hosts/artifacts/configuration.nix)
- edit workload wiring in [templates/artifacts.nix](../../templates/artifacts.nix)
- edit service behavior in the corresponding module under [apps](../../apps)
- edit secret labels and paths in the relevant module and in the encrypted secrets repo

When adding a new service, the usual pattern is:

1. create a new module under `apps/` or `functions/`
2. add a corresponding `services.<name>` option in a template
3. define `sops.secrets.*` if runtime secrets are needed
4. set up a systemd service via `systemd.services.<name>`
5. usually attach a Docker Compose stack if the service is containerized

## 9. Current deployment model

The current machine is configured around a single artifact host that runs:

- NetBird
- SSH
- Docker Compose-based services
- KohakuHub and its supporting storage/database services
- RustFS-backed S3-compatible storage

This is a practical “single machine + service modules” layout rather than a large monorepo of unrelated systems.

## Summary

The repository is structured around a simple rule: the flake defines the machine, the templates compose the workloads, the modules encapsulate service behavior, and SOPS manages the secret material. That makes the configuration both reproducible and easy to evolve without scattering operational state outside the Nix declarative model.
