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
| age private key | `/var/lib/sops-nix/infrastructure.age.key` for sops-nix, `~/.config/sops/age/keys.txt` for editing | root, and the user who bootstrapped the host |
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
    │   ├── university-ssh-key.yaml  # -> functions/ssh-uni.nix
    │   └── netbird.yaml             # -> functions/netbird*.nix (setup_key, api_token)
    └── artifacts/                   # nixosConfigurations.artifacts
        ├── kohaku-hub.env           # dotenv: whole file is one service env
        └── rustfs.yaml              # YAML: one key per sops.secrets entry
```

## 2. Why a fresh machine cannot read secrets

Three things have to be true, and none of them is set up by installing NixOS:

**0. The `nix-command` and `flakes` experimental features must be enabled.**
Nothing in this repository can be evaluated without them, since it is a flake
input fetched through the unified `nix` CLI. On a fresh install they are off by
default, and the first thing that fails is any `nix` subcommand:

```text
$ nix flake check
warning: 'flake-check' is a deprecated alias for 'check'
error: experimental Nix feature 'nix-command' is disabled; add '--extra-experimental-features nix-command' to enable it
```

This is a prerequisite for the two credentials below, not a third credential.
See [Adding a New Machine](./Adding_a_New_Machine.md#2-enable-flakes-and-the-nix-command-cli),
or the option reference at
<https://nixos.org/manual/nixos/stable/#opt-nix.settings.experimental-features>.
`modules/common.nix` declares the features for every host that imports it, and
`bootstrap-auth` refuses to run without them, so a host that has been through
`enroll` already has this covered.

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

**b. The age key must be installed — twice, for two different readers.**
`functions/sops.nix` declares
`sops.age.keyFile = "/var/lib/sops-nix/infrastructure.age.key"`, which is what
sops-nix reads at boot; if that file is absent, sops-nix silently has nothing to
decrypt and `/run/secrets/` stays empty.

That copy is root-only (mode `600`), which is right for a service and wrong for a
human. This is the trap: on a host that decrypts secrets perfectly well at boot,
editing one as your own user fails, because the only identity on the machine is
unreadable to you:

```text
Failed to get the data key required to decrypt the SOPS file.
  age18tqkdukn4cfs0es7zknm9eacpagmfqrfaaclcdzhs46cylrqg92smff6qm: FAILED
    - | failed to create reader for decrypting sops data key with age: identity
      | did not match any of the recipients ... failed to open
      | SOPS_AGE_KEY_FILE file: open
      | /var/lib/sops-nix/infrastructure.age.key: permission denied.
Recovery failed because no master key was able to decrypt the file.
```

The fix is a second copy at sops' own default location,
`~/.config/sops/age/keys.txt`, which `bootstrap-auth` installs and which needs no
`SOPS_AGE_KEY_FILE`:

```sh
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" \
  /var/lib/sops-nix/infrastructure.age.key ~/.config/sops/age/keys.txt
```

It hands over nothing `sudo` did not already: the same user can `sudo cat` the
root copy. See §9 for custody.

## 3. Bootstrapping a new host

Run this on the freshly installed machine, from a checkout of this repository:

```sh
cd ~/nixos-config
nix run ".?dir=flakes/bootstrap#enroll"
```

It is the *bootstrap* flake and not `nix run .#enroll` because it depends on
nixpkgs alone, so no missing private input can affect it — and because it also
carries `nixosConfigurations.bootstrap` for the bare-metal install.

Strictly, `nix run .#enroll` from the main flake does work here too: flake
inputs are lazy, so evaluating `packages` never touches `secrets`. What does
fail before the deploy key exists is anything that evaluates a *host
configuration* — see §2a:

```text
$ nix eval .#nixosConfigurations.highperformancecomputing.config.system.build.toplevel.drvPath
error: Failed to fetch git repository 'ssh://git@github.com/TJ-coding/nixos-secrets.git'
```

Once the credentials are in place the main flake is fully usable and
`nix run .#enroll` behaves identically.

`enroll` writes `hosts/<flake-host>/hardware-configuration.nix` and then runs
`bootstrap-auth`, which does the following, idempotently:

1. ensures an SSH key exists, offers to register it as a **read-only deploy key**
   on `nixos-secrets`, and verifies the result with `git ls-remote`;
2. installs the age key for sops-nix (paste an existing one, or generate a new
   one) **and a user-readable copy** at `~/.config/sops/age/keys.txt`, so that
   `sops` can decrypt — and therefore edit — secrets on that host (§2b);
3. checks the key's recipient against `nixos-secrets/.sops.yaml`, and leaves a
   checkout behind at `~/nixos-secrets` (which is also what step 4 reads);
4. brings the machine onto NetBird, registering it with the setup key from
   `secrets/shared/netbird.yaml`, which it decrypts using the age key from step 2;
5. prints a PASS/FAIL summary and exits non-zero if the repository is still
   unreachable.

NetBird runs **last** because it is the one step that consumes a secret this
script has to decrypt itself, and it can only do that once step 2 has installed
the age key. Enrolling through an interactive SSO login instead — which is what
this script used to do first — silently opts the peer into the account's **Peer
Session Expiration** (24h by default), so the machine drops off the mesh daily
until somebody runs `netbird up` on it by hand. Peers registered with a setup
key are exempt from session expiration.

That also makes NetBird the only skippable step: with no key to hand, the host
is simply not on the mesh yet, and the deployed configuration registers it at
the first rebuild (see [functions/netbird.nix](../../functions/netbird.nix)).
`NETBIRD_SETUP_KEY_FILE=/path/to/key` overrides the decryption, for the case
where the secrets repository cannot be read yet.

### Doing it by hand

```sh
# 1. GitHub: a key GitHub accepts for the private repository
ssh-keygen -t ed25519 -C "$(hostname)" -f ~/.ssh/id_ed25519      # if needed
gh auth login                                                    # as the repo owner
gh repo deploy-key add ~/.ssh/id_ed25519.pub \
  --repo TJ-coding/nixos-secrets --title "$(hostname)"

# verify
ssh -T git@github.com                       # "Hi TJ-coding/nixos-secrets! ..."
git ls-remote git@github.com:TJ-coding/nixos-secrets.git HEAD

# 2. The age key (copy it from a host that already has it)
ssh <existing-host> sudo cat /var/lib/sops-nix/infrastructure.age.key

sudo install -d -m 700 /var/lib/sops-nix
sudo tee /var/lib/sops-nix/infrastructure.age.key >/dev/null   # paste, then Ctrl-D
sudo chmod 600 /var/lib/sops-nix/infrastructure.age.key
sudo chown root:root /var/lib/sops-nix/infrastructure.age.key

# ...and a copy your own user can read, or `sops` cannot edit anything here (§2b)
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" \
  /var/lib/sops-nix/infrastructure.age.key ~/.config/sops/age/keys.txt

# ...and the checkout secrets are edited from (NetBird reads it in step 3 too)
git clone git@github.com:TJ-coding/nixos-secrets.git ~/nixos-secrets

# 3. NetBird, with the shared setup key, so the peer never expires
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/infrastructure.age.key \
  sops --decrypt --extract '["setup_key"]' \
  ~/nixos-secrets/secrets/shared/netbird.yaml > /tmp/netbird-setup-key
chmod 600 /tmp/netbird-setup-key
sudo netbird up --setup-key-file /tmp/netbird-setup-key
rm -f /tmp/netbird-setup-key

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

# shared YAML: the NetBird setup key and the API token that clears peer session
# expiration (functions/netbird.nix, functions/netbird-session-expiration.nix)
sops ~/nixos-secrets/secrets/shared/netbird.yaml

git -C ~/nixos-secrets commit -am "Update <service> secrets"
git -C ~/nixos-secrets push

# pin the new revision in this repository
cd ~/nixos-config
nix flake update secrets
sudo nixos-rebuild switch --flake .#artifacts
```

`sops` picks the age *recipient* from `.sops.yaml` automatically, so you never
paste one while editing. It still needs an *identity* to decrypt with — the
user-readable age key from §2b — and that is what `bootstrap-auth` sets up
(§3).

Three more assumptions this block makes:

- **The checkout exists.** `bootstrap-auth` leaves one at `~/nixos-secrets`
  (§3); otherwise the `git clone` above is the first step.
- **You can push.** The deploy key a bootstrapped host gets is read-only by
  design, so `git push` from that host is refused:
  ```text
  ERROR: The key you are authenticating with has been marked as read only.
  ```
  Push from the machine where you normally edit secrets, or run `gh auth login`
  on the host and push over HTTPS.
- **Commits work.** `git commit` needs an author identity, and a freshly
  bootstrapped host often has none — it fails with *"Author identity unknown"*,
  which reads like a repository problem. Set one in the checkout before the first
  commit (`bootstrap-auth` reports this at enrolment):
  ```sh
  git -C ~/nixos-secrets config user.name  '<your name>'
  git -C ~/nixos-secrets config user.email '<your email>'
  ```

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

**A credential for one systemd unit** — the NetBird login oneshot does not put
its key in an environment variable at all. The module passes
`setupKeyFile` to systemd as `LoadCredential`, so the key is exposed to
`netbird up` as `$CREDENTIALS_DIRECTORY/setup-key` and never appears in the
unit's environment or in `/proc/*/environ` (`functions/netbird.nix`):

```nix
sops.secrets."netbird-setup-key" = {
  sopsFile = "${secrets}/secrets/shared/netbird.yaml";
  key = "setup_key";
};

services.netbird.clients.default.login = {
  enable = true;
  setupKeyFile = config.sops.secrets."netbird-setup-key".path;
  systemdDependencies = [ "sops-install-secrets.service" ];
};
```

The `systemdDependencies` entry is the load-bearing part: without it the login
unit is free to start before sops-nix has written the file, and it reads a path
that does not exist yet.

The same pattern carries the NetBird personal access token that
[functions/netbird-session-expiration.nix](../../functions/netbird-session-expiration.nix)
uses to clear the account's 24h **Peer Session Expiration** on this host's own
peer (`LoadCredential = "api-token:${…}"`, read by the script as
`$CREDENTIALS_DIRECTORY/api-token`). Create the token once in the NetBird
dashboard — **user menu → Personal access tokens → Create** — under a user who
may see and update these peers (an admin, or whoever enrolled them), then add it
to `secrets/shared/netbird.yaml` as `api_token` and pin the new revision, exactly
as in [§4](#4-adding-or-changing-a-secret).

That key is a prerequisite, not an optional nicety. `sops-install-secrets` aborts
the whole activation when a declared `sops.secrets.*.key` is absent from the file
(`the key 'api_token' cannot be found`), so a rebuild that lands before the key
exists stops with a decryption error rather than silently leaving the peer on the
daily-expiry path.

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
| `experimental Nix feature 'nix-command' is disabled` | flakes are not enabled on the host, or the running shell predates enabling them | declare `nix.settings.experimental-features = [ "nix-command" "flakes" ]`, or pass `--extra-experimental-features 'nix-command flakes'`; see [Adding a New Machine](./Adding_a_New_Machine.md#2-enable-flakes-and-the-nix-command-cli) |
| `Permission denied (publickey)` from `nix flake archive` | host key is not a deploy key, or the deploy key was added from a *different* key | `gh repo deploy-key list --repo TJ-coding/nixos-secrets`, compare with `~/.ssh/id_ed25519.pub`, add the right one |
| `Failed to fetch git repository ... nixos-secrets` | no SSH key registered, or no network | `ssh -T git@github.com` |
| `/run/secrets` missing or empty | no age key, or the host defines no `sops.secrets` | install the age key; check `journalctl -u sops-nix` |
| `sops` says *no matching creation rules* | recipient missing from `.sops.yaml` | add it, then `sops updatekeys` |
| `sops` fails with `permission denied: /var/lib/sops-nix/infrastructure.age.key` or `no master key was able to decrypt the file`, but the host decrypts fine at boot | you are editing as your user and only the root-only copy of the age key exists | install the user copy (§2b); `bootstrap-auth` does it |
| `git push` to `nixos-secrets` refused: *key ... marked as read only* | the host's deploy key is deliberately read-only | push from another machine, or `gh auth login` here |
| `git commit` says *Author identity unknown* | no `user.name`/`user.email` for git on that host | `git -C ~/nixos-secrets config user.name …` and `… config user.email …`; `bootstrap-auth` warns about it |
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
- The user-readable copy at `~/.config/sops/age/keys.txt` (§2b) is that same
  shared key in a second place. It is what makes `sops` work on the host; keep it
  mode `600`, and never copy it into either repository.
- Rotate a secret by editing it with `sops`, not by rewriting the file by hand;
  writing plaintext and re-encrypting later leaks it into shell history and
  backups.

## 10. Known rough edges

- A bootstrapped host can *read* `nixos-secrets` but not push to it: the deploy
  key `bootstrap-auth` registers is read-only by design. Editing a secret from a
  host is therefore a two-machine dance unless you add a write-enabled deploy key
  or authenticate `gh` there.
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
