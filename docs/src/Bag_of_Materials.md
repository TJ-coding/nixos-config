# Bag of Materials

An inventory of what this flake is made of, and where each piece lives.

## Machines

| Flake attribute | Host configuration | Proxmox VM | Runs |
|---|---|---|---|
| `artifacts` | [hosts/artifacts/configuration.nix](../../hosts/artifacts/configuration.nix) | VM101 `ArtifactsStore` | RustFS, lakeFS, KohakuHub, Homepage |
| `highperformancecomputing` | [hosts/highperformancecomputing/configuration.nix](../../hosts/highperformancecomputing/configuration.nix) | VM100 `HighPerformanceComputing` | Slurm, scientific toolchain, VS Code remote server |

Both machines set `networking.hostName = "nixos"`, so the **flake attribute name**
identifies a host — not the hostname. That name is also what
`nixos-secrets/secrets/<name>/` is keyed by, which is why it matters.

## Templates

| Template | Used by | Purpose |
|---|---|---|
| [templates/artifacts.nix](../../templates/artifacts.nix) | `artifacts` | Storage workloads: RustFS, KohakuHub, Homepage, terminal |
| [templates/highperformancecomputing.nix](../../templates/highperformancecomputing.nix) | `highperformancecomputing` | Single-node Slurm cluster, uv/Python toolchain |

A template is the composition layer: it imports modules and sets the
service-specific values for one class of machine.

## Modules

| Module | Provides |
|---|---|
| [modules/servers.nix](../../modules/servers.nix) | Server base: SSH, NetBird, VS Code, common tooling |
| [modules/common.nix](../../modules/common.nix) | Packages common to every host; pulls in SOPS and NetBird |
| [modules/terminal-rice/terminal-rice.nix](../../modules/terminal-rice/terminal-rice.nix) | zsh, starship, tmux, fastfetch |

## Functions

| Function | Provides |
|---|---|
| [functions/ssh.nix](../../functions/ssh.nix) | OpenSSH daemon, port 22 |
| [functions/netbird.nix](../../functions/netbird.nix) | NetBird VPN with setup-key login (exempt from session expiry), plus Docker DNS that bypasses its DNS listener |
| [functions/sops.nix](../../functions/sops.nix) | SOPS age key location and `sops`/`age` tooling |
| [functions/rustfs.nix](../../functions/rustfs.nix) | RustFS S3 storage, wired to its SOPS secrets |
| [functions/docker_compose.nix](../../functions/docker_compose.nix) | Docker and Compose |
| [functions/vscode_remote_server.nix](../../functions/vscode_remote_server.nix) | `programs.nix-ld`, needed for the VS Code Remote-SSH server |
| [functions/ssh-uni.nix](../../functions/ssh-uni.nix) | University (NAIST) SSH access from a SOPS-managed key |

## Apps

| App | Provides |
|---|---|
| [apps/kohaku-hub](../../apps/kohaku-hub/kohaku-hub.nix) | KohakuHub plus its lakeFS / Postgres / Valkey Compose stack |
| [apps/homepage](../../apps/homepage/homepage.nix) | Homepage dashboard |
| [apps/bootstrap-auth.nix](../../apps/bootstrap-auth.nix) | NetBird, GitHub deploy key and SOPS age key |
| [apps/bootstrap-enroll.nix](../../apps/bootstrap-enroll.nix) | `nix run .#enroll` — hardware config, then `bootstrap-auth` |

## Playbooks

- [Adding a New Machine](./Playbooks/Adding_a_New_Machine.md)
- [Handling Secrets](./Playbooks/Handling_Secrets.md)
- [Adding a New Docker Compose Project](./Playbooks/Adding_a_New_Docker_Compose_Project.md)
- [University (NAIST) SSH Access](./Playbooks/University_SSH_Access.md)
