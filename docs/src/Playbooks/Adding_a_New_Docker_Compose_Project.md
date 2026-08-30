# Adding a New Docker Compose Project

This playbook captures the pattern used by this repository for adding a new containerized service managed by Docker Compose on NixOS.

The key idea is simple: keep the service declarative, keep state under well-known host paths, keep secrets SOPS-managed, and keep networking explicit.

## 1. Add the compose file and the service module

Create a service directory under `apps/` and add:

- a compose file such as `apps/my-service/docker-compose.yml`
- a Nix module such as `apps/my-service/my-service.nix`

The service module should usually:

- define an option set under `services.<name>`
- declare the app-specific settings such as `enable`, `base-url`, `secrets-path`, etc.
- create a `sops.secrets.*` definition for environment variables
- generate the systemd unit that runs `docker compose ... up --build`
- point to the compose file under `/etc` using `environment.etc` if needed

A good pattern looks like this:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.my-service;
in {
  options.services.my-service = {
    enable = lib.mkEnableOption "My Service";
    secrets-path = lib.mkOption {
      type = lib.types.str;
      default = "secrets/my-service.env";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."my-service-env" = {
      sopsFile = "${secrets}/${cfg.secrets-path}";
      format = "dotenv";
    };

    systemd.services.my-service = {
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      serviceConfig = {
        EnvironmentFile = config.sops.secrets."my-service-env".path;
        ExecStart = "${pkgs.docker}/bin/docker compose -f /etc/my-service-compose.yml up --build";
        ExecStop = "${pkgs.docker}/bin/docker compose -f /etc/my-service-compose.yml down";
      };
    };
  };
}
```

Then import the module from the host template:

```nix
imports = [
  ../apps/my-service/my-service.nix
];
```

## 2. Keep the app source and runtime state in stable locations

For projects like KohakuHub, the app source should be kept in an explicit immutable source path rather than being modified in place.

The repo uses a stable state directory such as:

```text
/var/lib/kohaku-hub
/var/lib/kohaku-hub/data
/var/lib/kohaku-hub/data/hub-meta
```

and creates those directories declaratively with `systemd.tmpfiles.rules`:

```nix
systemd.tmpfiles.rules = [
  "d /var/lib/kohaku-hub 0755 root root -"
  "d /var/lib/kohaku-hub/data 0755 root root -"
  "d /var/lib/kohaku-hub/data/hub-meta 0755 root root -"
];
```

This matters because Docker bind mounts should target stable directories under `/var/lib` or other known host paths; these are easier to back up, inspect, and reconstruct.

### Overlay strategy for source immutability

When an application needs an immutable source tree but still needs a writable layer, use an overlay mount pattern. This repo previously used the pattern:

```nix
fileSystems."/var/lib/kohaku-hub/merged" = {
  device = "overlay";
  fsType = "overlay";
  options = [
    "lowerdir=${kohaku-hub}"
    "upperdir=/var/lib/kohaku-hub/upper"
    "workdir=/var/lib/kohaku-hub/work"
  ];
};
```

This gives you:

- a read-only lower layer from the upstream source tree
- a writable upper layer under `/var/lib/kohaku-hub/upper`
- a merged view mounted at `/var/lib/kohaku-hub/merged`

This is useful for reproducibility and making container build contexts deterministic. In many cases, if the upstream project is already static and buildable, it is simpler to use the upstream source directly instead of a custom overlay layer. The repo currently prefers the simpler and more robust approach of mounting the upstream source directly when no writable overlay is needed.

## 3. Handle volume paths carefully

Volume paths are one of the most important parts of a Docker Compose project.

The practical rule is:

- do not put mutable state under random ephemeral directories
- bind persistently to `/var/lib/...`
- create the directories explicitly with `systemd.tmpfiles.rules`
- mount them as named volumes or host bind mounts in the compose file

Example from this repo:

```yaml
volumes:
  - /var/lib/kohaku-hub/data/hub-meta/lakefs-data:/var/lakefs/data
  - /var/lib/kohaku-hub/data/hub-meta/postgres-data:/var/lib/postgresql/data
  - /var/lib/kohaku-hub/data/hub-meta/valkey-data:/data
```

This gives each dependency its own durable state and keeps data ownership consistent across rebuilds.

Avoid:

- mounting directly into project directories that are not persistent
- relying on auto-created directories without declarative rules
- mixing mutable state with immutable source trees

## 4. Handle networking explicitly

For containerized services, networking needs to be predictable.

The repo uses a named default network:

```yaml
networks:
  default:
    name: hub-net
```

and services then reach each other by service name, for example:

```yaml
hub-api:
  environment:
    KOHAKU_HUB_DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/kohakuhub
    KOHAKU_HUB_LAKEFS_ENDPOINT: http://lakefs:28000
    KOHAKU_HUB_CACHE_URL: redis://valkey:6379/0
```

This makes internal communication container-local and stable.

For external access, expose only the ports you need:

```yaml
ports:
  - "28080:80"
  - "48888:48888"
```

and make sure the host firewall allows those ports:

```nix
networking.firewall.allowedTCPPorts = [ 22 28080 ];
```

If the service must reach a host service such as the local MinIO or local S3 endpoint, use `extra_hosts`:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

This is useful when the containerized app needs to talk to a process running on the host machine.

## 5. Handle secrets with SOPS and dotenv files

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

Secrets should not be embedded in the compose file or stored as plain values in the repo.

This repo uses a SOPS-managed `.env` file, for example:

```nix
sops.secrets."kohaku-hub-env" = {
  sopsFile = "${secrets}/${cfg.secrets-path}";
  format = "dotenv";
};
```

Then the service injects it with:

```nix
EnvironmentFile = config.sops.secrets."kohaku-hub-env".path;
```

and the compose file reads the values as environment variables:

```yaml
environment:
  KOHAKU_HUB_SESSION_SECRET: ${KOHAKU_HUB_SESSION_SECRET}
  KOHAKU_HUB_ADMIN_SECRET_TOKEN: ${KOHAKU_HUB_ADMIN_SECRET_TOKEN}
  KOHAKU_HUB_DATABASE_KEY: ${KOHAKU_HUB_DATABASE_KEY}
```

This keeps secrets out of the repository while preserving a declarative runtime shape.

### Recommended secret layout

For each app:

- keep a single secret file under the external secrets repo
- store all environment variables for that service in a dotenv file
- point `sopsFile` to that file
- only expose the minimum set required to the app container

## 6. Template for a new Compose-backed app

Use this checklist when adding a new project:

1. Add the project under `apps/<project>/`
2. Create `docker-compose.yml`
3. Add a Nix module that exposes `services.<project>` options
4. Create stable data directories under `/var/lib/<project>`
5. Add the `systemd.tmpfiles.rules` entries
6. Add the service to the host template imports
7. Expose required ports in the firewall
8. Define network names and dependencies explicitly
9. Keep all secrets in SOPS-managed dotenv files
10. Rebuild the host with `sudo nixos-rebuild switch --flake .#artifacts`

## 7. Operational example from this repo

The live pattern here is:

- build an immutable source or Nix-built frontend artifact
- mount it read-only into a container
- keep mutable state under `/var/lib/kohaku-hub/data/...`
- let the app talk over the default Docker network
- load environment values from SOPS-managed secrets instead of ad hoc shell exports

That is the core pattern to follow for new Compose projects in this repository.
