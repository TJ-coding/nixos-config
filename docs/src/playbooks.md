# Playbooks

Step-by-step procedures for the work this repository needs most often. Each one
is written to be followed on a real machine, in order.

| Playbook | Use it when |
|---|---|
| [Adding a New Machine](./Playbooks/Adding_a_New_Machine.md) | Bringing a freshly installed host into the flake |
| [Handling Secrets](./Playbooks/Handling_Secrets.md) | A host cannot read secrets, or you are adding or rotating one |
| [Adding a New Docker Compose Project](./Playbooks/Adding_a_New_Docker_Compose_Project.md) | Adding a containerised service under `apps/` |
| [University (NAIST) SSH Access](./Playbooks/University_SSH_Access.md) | Setting up or debugging access to the university cluster |

A new machine needs two independent credentials before it can use any secret: a
GitHub deploy key for the private `nixos-secrets` flake input, and the SOPS age
key. [Handling Secrets](./Playbooks/Handling_Secrets.md) covers both, and
`nix run .#enroll` sets them up.

For an inventory of what exists in the repository, see
[Bag of Materials](Bag_of_Materials.md).
