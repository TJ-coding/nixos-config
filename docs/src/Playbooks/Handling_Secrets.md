# Handling Secrets

Secrets do **not** live in this repository. They live in a separate, private
repository, [`TJ-coding/nixos-secrets`](https://github.com/TJ-coding/nixos-secrets),
encrypted at rest with [SOPS](https://github.com/getsops/sops) using
[age](https://github.com/FiloSottile/age). [sops-nix](https://github.com/Mic92/sops-nix)
decrypts them during system activation and exposes the plaintext under
`/run/secrets/...`, where systemd units read them.

The rule that follows from this: **the machine needs two independent
credentials before it can use a secret at all.**

1. a way to read the *encrypted* secrets repository (a GitHub SSH key), and
2. the age private key that decrypts them.

Missing either one produces a different error, and neither is obvious from the
Nix code. This playbook is mostly about those two credentials.

## 1. The pieces

| Piece | Where it lives | Readable by |
|---|---|---|
| Encrypted secrets | `TJ-coding/nixos-secrets`, `secrets/<flake-host>/...` | anyone with repo access (ciphertext is useless without the key) |
| age private key | `/var/lib/sops-nix/infrastructure.age.key` on each host | root on that host |
| age recipient | `creation_rules` in `nixos-secrets/.sops.yaml` | public |
| GitHub deploy key | per-host SSH key registered on `nixos-secrets` | read-only, revocable per machine |

The age key is the same on every host (`infrastructure.age.key`) — it is a
single shared secret, so **anything that host can decrypt, every host can
decrypt**. That is a deliberate simplicity trade-off for a small fleet. If that
ever stops being acceptable, see [§7](#7-rotating-the-age-key).

The repository layout is keyed by the *flake attribute name*, not by
`networking.hostName` (two of the machines are both called `nixos`, so the
hostname cannot identify a host):

```text
nixos-secrets/
├── .sops.yaml                       # who may decrypt what
└── secrets/
    ├── shared/                      # read by more than one host
    │   └── university-ssh-key.yaml  # -> functions/ssh-uni.nix
    └── artifacts/                   # nixosConfigurations.artifacts
        ├── kohaku-hub.env           # dotenv: whole file is one service env
        └── rustfs.yaml              # YAML: one key per sops.secrets entry
```

## 2. Why a fresh machine cannot read secrets

Two things have to be true, and neither is set up by installing NixOS:

**a. The private flake input must be fetchable.** `flake.nix` pulls the secrets
repository as an input:

```nix
secrets = {
  url = "git+ssh://git@github.com/TJ-coding/nixos-secrets.git";
  flake = false;
};
```

A `git+ssh://` URL is fetched by `git` over SSH, so it needs an SSH key that
GitHub accepts for that repository. `gh auth setup-git` is **not** enough: it
configures an HTTPS credential helper, and SSH URLs never consult it. Without a
suitable key the failure is:

```text
error: Failed to fetch git repository 'ssh://git@github.com/TJ-coding/nixos-secrets.git'
git@github.com: Permission denied (publickey).
```

Note that this only bites when the input is actually *used*. A host whose
template imports no secrets-using module never forces the input, so the flake
evaluates happily and the missing credential stays invisible until the first
service that needs a secret is added.

**b. The age key must be installed.** `functions/sops.nix` declares
`sops.age.keyFile = "/var/lib/sops-nix/infrastructure.age.key"`. If that file is
absent, sops-nix silently has nothing to decrypt, and `/run/secrets/` stays
empty.

## 3. Bootstrapping a new host

Run this on the freshly installed machine, from a checkout of this repository:

```sh
cd ~/nixos-config
nix run ".?dir=flakes/bootstrap#enroll"
```

It is the *bootstrap* flake and not `nix run .#enroll`, because of §2a: this is
the one moment when the main flake cannot be evaluated yet. Nix fetches every
input before calling `outputs`, so with no deploy key the main flake cannot even
be evaluated to reach the helper that registers the deploy key:

```text
$ nix run .#enroll
error: … while fetching the input 'git+ssh://git@github.com/TJ-coding/nixos-secrets.git'
       error: Failed to fetch git repository 'ssh://git@github.com/TJ-coding/nixos-secrets.git'
```

`flakes/bootstrap/flake.nix` depends on nixpkgs alone, so it always evaluates and
exports the same helpers. Once the credentials are in place the main flake
becomes evaluable and `nix run .#enroll` works identically.

`enroll` writes `hosts/<flake-host>/hardware-configuration.nix` and then runs
`bootstrap-auth`, which does the following, idempotently:

1. brings the machine onto NetBird (`netbird up`);
2. ensures an SSH key exists, offers to register it as a **read-only deploy key**
   on `nixos-secrets`, and verifies the result with `git ls-remote`;
3. installs the age key (paste an existing one, or generate a new one);
4. checks the key's recipient against `nixos-secrets/.sops.yaml`;
5. prints a PASS/FAIL summary and exits non-zero if the repository is still
   unreachable.

### Doing it by hand

```sh
# 1. NetBird
sudo netbird up

# 2. GitHub: a key GitHub accepts for the private repository
ssh-keygen -t ed25519 -C "$(hostname)" -f ~/.ssh/id_ed25519      # if needed
gh auth login                                                    # as the repo owner
gh repo deploy-key add ~/.ssh/id_ed25519.pub \
  --repo TJ-coding/nixos-secrets --title "$(hostname)"

# verify
ssh -T git@github.com                       # "Hi TJ-coding/nixos-secrets! ..."
git ls-remote git@github.com:TJ-coding/nixos-secrets.git HEAD

# 3. The age key (copy it from a host that already has it)
ssh <existing-host> sudo cat /var/lib/sops-nix/infrastructure.age.key

sudo install -d -m 700 /var/lib/sops-nix
sudo tee /var/lib/sops-nix/infrastructure.age.key >/dev/null   # paste, then Ctrl-D
sudo chmod 600 /var/lib/sops-nix/infrastructure.age.key
sudo chown root:root /var/lib/sops-nix/infrastructure.age.key

# 4. Confirm the key can actually decrypt something
cd ~/nixos-config
nix flake archive                    # forces every input, including secrets
sudo nixos-rebuild switch --flake .#<host>
sudo ls /run/secrets                 # populated only for hosts that use secrets
```

Only hosts that define `sops.secrets.*` need the age key. A pure compute host
can be built without one; it just cannot decrypt anything.

## 4. Adding or changing a secret

```sh
git clone git@github.com:TJ-coding/nixos-secrets.git ~/nixos-secrets

# dotenv file: the whole file is exported to one service
sops ~/nixos-secrets/secrets/artifacts/kohaku-hub.env

# YAML file: one key per sops.secrets entry
sops ~/nixos-secrets/secrets/artifacts/rustfs.yaml

git -C ~/nixos-secrets commit -am "Update <service> secrets"
git -C ~/nixos-secrets push

# pin the new revision in this repository
cd ~/nixos-config
nix flake update secrets
sudo nixos-rebuild switch --flake .#artifacts
```

`sops` picks the age recipient from `.sops.yaml` automatically, so you never
paste a key while editing.

## 5. Wiring a secret into a module

**dotenv** — one file, all variables, useful for `EnvironmentFile`:

```nix
sops.secrets."kohaku-hub-env" = {
  sopsFile = "${secrets}/secrets/artifacts/kohaku-hub.env";
  format = "dotenv";
};

systemd.services.kohaku-hub.serviceConfig.EnvironmentFile =
  config.sops.secrets."kohaku-hub-env".path;
```

**YAML** — select individual keys, useful for services that take a file path:

```nix
sops.secrets."rustfs-access-key" = {
  sopsFile = "${secrets}/secrets/artifacts/rustfs.yaml";
  key = "access_key";
  restartUnits = [ "rustfs.service" ];
};
```

**A file, not an environment variable** — a private key has to be readable by
one local user and nobody else, so it needs `owner`/`mode` (`functions/ssh-uni.nix`):

```nix
sops.secrets."university-ssh-key" = {
  sopsFile = "${secrets}/secrets/shared/university-ssh-key.yaml";
  key = "private_key";
  owner = "tj-coding";
  mode = "0400";
};
```

The variable `secrets` is the flake input, passed down through `specialArgs`:

```nix
specialArgs = { inherit kohaku-hub rustfs secrets; };
```

Always reference `config.sops.secrets.<name>.path`; never read the file at
evaluation time, because at evaluation time the decrypted file does not exist.

## 6. Verifying that it actually works

```sh
# Is the private input fetchable at all? (forces every input)
nix flake archive

# Which key does this host have, and is it the authorised one?
sudo age-keygen -y /var/lib/sops-nix/infrastructure.age.key
grep -oE 'age1[0-9a-z]{58}' ~/nixos-secrets/.sops.yaml

# Can this key decrypt a file?
cd ~/nixos-secrets && sops -d secrets/artifacts/rustfs.yaml >/dev/null && echo ok

# What did sops-nix actually produce, and when?
sudo ls -la /run/secrets
sudo journalctl -u sops-nix -b --no-pager
```

## 7. Rotating the age key

The recipient lives in exactly one place, `nixos-secrets/.sops.yaml`:

```yaml
creation_rules:
  - path_regex: .*
    age: age1...
```

To add a host's newly generated key, *add* its recipient to that list and
re-encrypt every file — SOPS wraps the data key once per recipient, so the data
itself does not change and everyone keeps reading the same plaintext:

```sh
sops updatekeys secrets/artifacts/rustfs.yaml
sops updatekeys secrets/artifacts/kohaku-hub.env

git commit -am "Add <host> to age recipients" && git push
cd ~/nixos-config && nix flake update secrets
```

To *remove* a host, delete its recipient, `sops updatekeys` every file, and
rotate anything that host could have read. Removing a recipient does not undo
access it already had.

Deploy keys are revoked independently, which is the point of `--allow-read-only`:

```sh
gh repo deploy-key list --repo TJ-coding/nixos-secrets
gh repo deploy-key delete <id> --repo TJ-coding/nixos-secrets
```

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` from `nix flake archive` | host key is not a deploy key, or the deploy key was added from a *different* key | `gh repo deploy-key list --repo TJ-coding/nixos-secrets`, compare with `~/.ssh/id_ed25519.pub`, add the right one |
| `Failed to fetch git repository ... nixos-secrets` | no SSH key registered, or no network | `ssh -T git@github.com` |
| `/run/secrets` missing or empty | no age key, or the host defines no `sops.secrets` | install the age key; check `journalctl -u sops-nix` |
| `sops` says *no matching creation rules* | recipient missing from `.sops.yaml` | add it, then `sops updatekeys` |
| Build succeeds but the service starts with empty values | the module reads the secret at eval time, or `restartUnits` is not set | use `config.sops.secrets.…​.path`; add `restartUnits` |
| Secrets input never fetched, so nothing complains | no imported module uses `secrets` | that host simply does not need it; see §2a |

## 9. Rules of custody

- Never commit the age private key, a decrypted file, or a token into either
  repository. `.gitignore` is not a safety net.
- Keep an offline copy of the age key somewhere you would keep a password
  manager. Losing it means every secret has to be re-encrypted from scratch.
- Prefer per-machine read-only deploy keys over personal SSH keys: they are
  scoped to one repository and can be revoked without touching your GitHub
  account.
- Installing the key must be done as root with mode `600`:
  `sudo install -m 600 -o root -g root <key> /var/lib/sops-nix/infrastructure.age.key`.
- Rotate a secret by editing it with `sops`, not by rewriting the file by hand;
  writing plaintext and re-encrypting later leaks it into shell history and
  backups.

## 10. Known rough edges

- `secrets/<flake-host>/` is named after the flake attribute, while both
  machines set `networking.hostName = "nixos"`. Auto-deriving secret paths from
  the hostname is therefore not possible today; templates set
  `secrets-path`/`rustfs-secrets-path` explicitly. Renaming a host means
  renaming its directory in the secrets repository.
- `apps/kohaku-hub` and `functions/rustfs.nix` have defaults like
  `secrets/kohaku-hub.env` that do not match the layout above. They are always
  overridden by `templates/artifacts.nix`; do not rely on the defaults.
- `secrets/artifacts/kohaku-hub.env` currently contains
  `LAKEFS_AUTH_ENCRYPT_SECRET_KEY` twice. In a dotenv file the last definition
  wins, so the first one is dead. Worth cleaning up in the secrets repository.
