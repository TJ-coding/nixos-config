# University (NAIST) SSH Access

The HPC host reaches the university filesystem over SSH using
`functions/ssh-uni.nix`. Everything needed is in git: the client
configuration, the pinned gateway host key, and the private key (encrypted in
`TJ-coding/nixos-secrets`).

## How it is put together

| Piece | Where |
|---|---|
| Client config (`Host naist`, `ProxyJump`, `IdentityFile`) | `functions/ssh-uni.nix` |
| Private key, age-encrypted | `nixos-secrets: secrets/shared/university-ssh-key.yaml` |
| Decrypted key at runtime | `/run/secrets/university-ssh-key` (owner `tj-coding`, mode `0400`) |
| Enabled per host | `services.university-ssh.enable = true` in `hosts/<host>/configuration.nix` |

The key is never copied into `~/.ssh`. SSH reads it straight out of
`/run/secrets`, which sops-nix writes at activation time, so a rebuilt machine
gets the access back without anyone remembering which file to scp.

```nix
services.university-ssh = {
  enable = true;
  remoteUser = "tomoyuki-j";       # the university account
  keyOwner = "tj-coding";          # the local account that may read the key
  computeHosts = [ "pine11" "pine12" "pine13" ];
};
```

## Using it

```sh
ssh naist                 # gateway, sh.naist.jp
ssh pine11                # lab node, via ProxyJump through the gateway
rsync -av foo/ pine11:~/  # works unattended, no passphrase prompt
```

## About the key

The key is a dedicated ed25519 key, `uni-ssh-hpc`, with **no passphrase**.

That is deliberate. The key that was originally copied to the artifact host was
the workstation's personal `id_rsa`, which *is* passphrase-protected; without an
agent holding the passphrase it can never authenticate, so unattended use
(`rsync`, `systemd` units, Slurm jobs) fails with `Permission denied
(publickey)`. A per-host key with no passphrase is what makes the access
actually reproducible. Anything that can read `/run/secrets/university-ssh-key`
can use the key, which is why it is `0400` and owned by a single user.

## Adding a new host

1. Generate a key on the new machine:

   ```sh
   ssh-keygen -t ed25519 -N '' -C "uni-ssh-<hostname>" -f /tmp/uni_ssh
   ```

2. Authorise the public key **on both university filesystems**. This trips
   people up: `sh.naist.jp` serves `~` from local ZFS, while `pine11`-`pine13`
   serve `~` from the lab NFS export, so the same path is two different files.

   ```sh
   key="$(cat /tmp/uni_ssh.pub)"
   for host in sh.naist.jp pine11; do
     ssh "$host" "printf '%s\n' '$key' >> ~/.ssh/authorized_keys"
   done
   ```

3. Check it authenticates with *only* that key before storing it:

   ```sh
   ssh -i /tmp/uni_ssh -o IdentitiesOnly=yes -o BatchMode=yes naist hostname
   ```

4. Encrypt it into the secrets repository:

   ```sh
   cd ~/nixos-secrets
   cp /tmp/uni_ssh /tmp/key-material
   { echo 'private_key: |'; sed 's/^/  /' /tmp/key-material; } \
     > secrets/shared/university-ssh-key.yaml
   sops --encrypt --in-place secrets/shared/university-ssh-key.yaml
   shred -u /tmp/key-material
   git add -A && git commit -m "Add university SSH key for <hostname>" && git push
   ```

5. Point the host at it and rebuild:

   ```nix
   imports = [ ../../functions/ssh-uni.nix ];
   services.university-ssh.enable = true;
   ```

   ```sh
   cd ~/nixos-config
   nix flake update secrets
   sudo nixos-rebuild switch --flake .#<hostname>
   ```

6. Verify the decrypted key is the right one:

   ```sh
   sudo ssh-keygen -lf /run/secrets/university-ssh-key
   ```

## Removing access

Delete the key's line from `~/.ssh/authorized_keys` on both university
filesystems and remove the entry from `secrets/shared/university-ssh-key.yaml`.
