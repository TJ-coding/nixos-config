{ pkgs }:

# Give a freshly installed host the credentials it needs to take part in this
# flake:
#
#   1. GitHub SSH access to the *private* `secrets` flake input
#      (git+ssh://git@github.com/TJ-coding/nixos-secrets.git). Without this,
#      `nixos-rebuild` cannot fetch the input, and the failure surfaces as a
#      confusing `Permission denied (publickey)` during evaluation.
#   2. The SOPS age key at /var/lib/sops-nix/infrastructure.age.key, which is
#      what sops-nix uses to decrypt secrets into /run/secrets -- plus a
#      user-readable copy at ~/.config/sops/age/keys.txt, because *editing* a
#      secret needs an identity and the root-only one is not one sops can use.
#   3. A checkout of the secrets repository at ~/nixos-secrets, which is where
#      secrets are edited from.
#   4. NetBird membership, so the host is reachable -- registered with the
#      shared setup key from the secrets repository, not an interactive SSO
#      login.
#
# Step 4 runs *last* on purpose: it is the step that wants a secret this script
# has to decrypt for itself, and it can only do that once step 2 has installed
# the age key. Ordering it first (as this script used to) enrolled every new
# host through SSO, which silently opts the machine into the account's "Peer
# Session Expiration" (24h by default). The peer then fell off the mesh daily
# until somebody ran `netbird up` on it by hand -- which is exactly what was
# happening to artifacts and highperformancecomputing. Peers registered with a
# setup key are exempt from session expiration.
#
# NetBird is therefore the only step that can be skipped safely: if no key can
# be had, the host is simply not on the mesh yet, and the deployed NixOS
# configuration registers it at the first rebuild (see functions/netbird.nix).
#
# Each step is verified rather than assumed, because a half-finished version of
# this is exactly what makes secrets look configured when they are not: the
# deploy key exists, the host has a key, but they are not the same key. Access
# is tested first, so a host that already works is left alone.
#
# See docs/src/Playbooks/Handling_Secrets.md for the full story.
pkgs.writeShellApplication {
  name = "bootstrap-auth";

  runtimeInputs = with pkgs; [
    age
    coreutils
    gawk
    gh
    git
    gnugrep
    gnused
    hostname
    netbird
    nix
    openssh
    sops
  ];

  text = ''
    SECRETS_REPO="TJ-coding/nixos-secrets"
    SECRETS_URL="git@github.com:''${SECRETS_REPO}.git"
    AGE_KEY_FILE="/var/lib/sops-nix/infrastructure.age.key"
    # sops looks here by default, so an edit needs no SOPS_AGE_KEY_FILE dance.
    USER_AGE_KEY_FILE="''${XDG_CONFIG_HOME:-''${HOME}/.config}/sops/age/keys.txt"
    # Checkout a human edits secrets from. The NetBird step also decrypts the
    # setup key out of it, so it is deliberately left in place, not thrown away.
    SECRETS_CHECKOUT="''${HOME}/nixos-secrets"
    SSH_KEY="''${HOME}/.ssh/id_ed25519"
    SETUP_KEY_SECRET="secrets/shared/netbird.yaml"

    # Escape hatch for the case where the secrets repository cannot be read
    # yet: NETBIRD_SETUP_KEY_FILE=/path/to/key enroll <host>. The normal path
    # decrypts the key with the age key installed in step 2, so nobody has to
    # carry the key around by hand.
    SETUP_KEY_FILE="''${NETBIRD_SETUP_KEY_FILE:-}"

    github_ok=0
    age_ok=0
    # 0 once it is known that the host has no git author identity, which makes
    # commits in the secrets checkout fail.
    git_identity_ok=1
    # `setup_key` and `status_out` are initialised because `set -u`
    # (writeShellApplication) makes an unset expansion a hard error on the paths
    # that return early, and the summary below reads `status_out`.
    setup_key=""
    status_out=""
    # Filled in by require_flakes; read by the success line and the summary.
    features=""
    secrets_dir=""

    step() { printf '\n==> %s\n' "$*"; }
    warn() { printf 'warning: %s\n' "$*" >&2; }
    die() { printf 'error: %s\n' "$*" >&2; exit 1; }

    # The enabled experimental features, as `nix config show` reports them
    # (space-separated). Empty when `nix` cannot be run at all, which is the
    # fresh-installer case: the installer ISO forbids nix.conf unless
    # NIX_CONFIG is set.
    enabled_features() {
      nix config show experimental-features 2>/dev/null || true
    }

    # This repository is a flake, so nothing here works without these. Check up
    # front rather than letting the operator discover it halfway through
    # credential setup -- after `enroll` has already generated a hardware
    # configuration.
    require_flakes() {
      # Declared first so the message can report what *is* enabled; `local` from
      # `-`/`+`/`*` strips the enclosing scope's variable, which would silently
      # shadow the global this function also assigns.
      features="$(enabled_features)"
      local features_missing=""
      # Space-pad before matching: `nix config show` reports these
      # space-separated, and padding makes "nix-command" not match
      # "no-nix-command"-style values.
      case " $features " in
        *" nix-command "*) ;;
        *) features_missing="nix-command" ;;
      esac
      case " $features " in
        *" flakes "*) ;;
        *) features_missing="''${features_missing:+''${features_missing} }flakes" ;;
      esac
      if [ -z "$features_missing" ]; then
        return 0
      fi

      printf 'error: this repository is a flake, but %s %s not enabled\n' \
        "$features_missing" "$(if [ "$features_missing" = "nix-command flakes" ]; then echo are; else echo is; fi)" >&2
      printf '       enabled now: %s\n' "''${features:-<none reported by nix config show>}" >&2
      printf '       needed:      nix-command flakes\n' >&2
      printf '\n' >&2
      printf 'Fix it declaratively in the host configuration (and then rebuild once with\n' >&2
      printf 'the features passed on the command line, since Nix only reads its\n' >&2
      printf 'configuration at start-up):\n' >&2
      printf '\n' >&2
      printf "    nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];\n" >&2
      printf '\n' >&2
      printf 'or temporarily, for a single shell:\n' >&2
      printf "\n    export NIX_CONFIG='experimental-features = nix-command flakes'\n\n" >&2
      printf 'Both are written up in docs/src/Playbooks/Adding_a_New_Machine.md\n' >&2
      printf '(section 2, “Enable flakes and the nix-command CLI”), with the option\n' >&2
      printf 'itself at\n' >&2
      printf 'https://nixos.org/manual/nixos/stable/#opt-nix.settings.experimental-features\n' >&2
      return 1
    }

    need_tty() {
      if [ ! -t 0 ]; then
        die "$1 needs an interactive terminal (re-run with: ssh -t <host>)"
      fi
    }

    can_read_secrets() {
      timeout 60 git ls-remote "$SECRETS_URL" HEAD >/dev/null 2>&1
    }

    # A decrypted copy of the shared NetBird setup key, or failure. Printed on
    # stdout so the caller can capture it; the file is the caller's to remove.
    setup_key_from_secrets() {
      [ -n "$secrets_dir" ] || return 1

      local encrypted="$secrets_dir/$SETUP_KEY_SECRET"
      [ -f "$encrypted" ] || return 1

      # Resolve the absolute path first: sudo resets PATH, and `sops` here is a
      # Nix wrapper that lives outside the system profile.
      local sops_bin
      sops_bin="$(command -v sops || true)"
      [ -n "$sops_bin" ] || return 1

      # The age key is root-only, so the decryption has to run as root. Capture
      # the plaintext through a pipe rather than redirecting into the file:
      # `sudo cmd >file` is the *user's* shell creating the file, which is both
      # wrong and what shellcheck flags as SC2024.
      local key_value
      key_value="$(sudo SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" "$sops_bin" --decrypt \
        --extract '["setup_key"]' "$encrypted" 2>/dev/null || true)"
      [ -n "$key_value" ] || return 1

      local out
      out="$(mktemp)"
      chmod 600 "$out"
      printf '%s\n' "$key_value" >"$out"
      printf '%s\n' "$out"
    }

    # ---------------------------------------------------- 0. flake prerequisites
    # Cheap, and it gates everything after it: without the features below, the
    # rebuild at the end cannot even evaluate this repository.
    step "Flake features (nix-command, flakes)"
    if require_flakes; then
      echo "OK: $features"
    else
      exit 1
    fi

    # --------------------------------------------------------------- 1. GitHub
    # Turn a "Permission denied (publickey)" into something readable.
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
      ssh-keyscan -H github.com >>"''${HOME}/.ssh/known_hosts" 2>/dev/null || true
    fi

    step "Access to ''${SECRETS_REPO}"
    if can_read_secrets; then
      echo "OK: already reachable with the credentials on this host"
      github_ok=1
    else
      git_err="$(timeout 60 git ls-remote "$SECRETS_URL" HEAD 2>&1 || true)"
      case "$git_err" in
        *"Permission denied"* | *publickey*)
          echo "not reachable: this host has no SSH key that ''${SECRETS_REPO} accepts"
          ;;
        *)
          warn "unexpected error talking to $SECRETS_URL:"
          printf '%s\n' "$git_err" | sed 's/^/         /'
          ;;
      esac
    fi

    if [ "$github_ok" -ne 1 ]; then
      step "GitHub authentication"
      if gh auth status >/dev/null 2>&1; then
        echo "gh is authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
      else
        need_tty "gh auth login"
        echo "Log in as the owner of ''${SECRETS_REPO}."
        echo "HTTPS is enough: this is only used to register the host's SSH key."
        gh auth login
      fi

      step "SSH key"
      mkdir -p "''${HOME}/.ssh"
      chmod 700 "''${HOME}/.ssh"

      if [ -f "$SSH_KEY" ]; then
        echo "using existing $SSH_KEY"
      else
        echo "no key at $SSH_KEY; generating one (no passphrase)"
        ssh-keygen -q -t ed25519 -N "" -C "$(hostname)" -f "$SSH_KEY"
      fi

      key_blob="$(awk '{print $2}' "''${SSH_KEY}.pub")"

      step "Deploy key on ''${SECRETS_REPO}"
      if gh api --paginate "repos/''${SECRETS_REPO}/keys" --jq '.[].key' 2>/dev/null \
        | awk '{print $2}' | grep -qxF "$key_blob"; then
        echo "this host's key is already a deploy key, but access still failed"
        echo "check that the key is enabled and belongs to ''${SECRETS_REPO}"
      else
        need_tty "deploy key registration"
        echo "This host's public key is not a deploy key on ''${SECRETS_REPO}:"
        echo
        sed 's/^/    /' "''${SSH_KEY}.pub"
        echo
        echo "A read-only deploy key is the least privilege that works, and it is"
        echo "revocable per machine without touching your GitHub account."
        printf 'Add it as a read-only deploy key? [y/N] '
        read -r reply
        case "$reply" in
          y | Y | yes | YES)
            gh repo deploy-key add "''${SSH_KEY}.pub" \
              --repo "$SECRETS_REPO" \
              --title "$(hostname)-$(date +%Y%m%d)"
            ;;
          *)
            warn "skipped"
            ;;
        esac
      fi

      if can_read_secrets; then
        echo "OK: ''${SECRETS_REPO} is now reachable"
        github_ok=1
      else
        warn "still cannot reach $SECRETS_URL"
      fi
    fi

    # ------------------------------------------------------------ 2. SOPS age key
    step "SOPS age key"
    if sudo test -f "$AGE_KEY_FILE"; then
      recipient="$(sudo cat "$AGE_KEY_FILE" | age-keygen -y)"
      echo "already installed at $AGE_KEY_FILE"
      echo "recipient: $recipient"
      age_ok=1
    else
      need_tty "age key setup"
      echo "No age key at $AGE_KEY_FILE."
      echo
      echo "  1) Paste the existing infrastructure age key."
      echo "     The same key decrypts every file in ''${SECRETS_REPO}. Copy it from a"
      echo "     machine that already has it, e.g."
      echo "       ssh <that-host> sudo cat $AGE_KEY_FILE"
      echo "  2) Generate a NEW age key on this host."
      echo "     Its recipient must then be added to ''${SECRETS_REPO}/.sops.yaml and"
      echo "     the secret files re-encrypted with sops updatekeys."
      echo
      printf 'Choose [1/2]: '
      read -r choice

      case "$choice" in
        2)
          tmp_dir="$(mktemp -d)"
          chmod 700 "$tmp_dir"
          age-keygen -o "$tmp_dir/key.txt" >/dev/null 2>&1
          recipient="$(age-keygen -y "$tmp_dir/key.txt")"
          sudo install -m 600 -o root -g root "$tmp_dir/key.txt" "$AGE_KEY_FILE"
          rm -rf "$tmp_dir"
          age_ok=1
          echo
          echo "Generated a new age key. Public recipient:"
          echo "    $recipient"
          echo
          echo "It cannot decrypt any existing secret yet. To make it useful:"
          echo "  1. add the recipient to creation_rules in ''${SECRETS_REPO}/.sops.yaml"
          echo "  2. cd <nixos-secrets checkout> && sops updatekeys secrets/<file>"
          echo "     for every encrypted file"
          echo "  3. commit and push, then here:"
          echo "     cd ~/nixos-config && nix flake update secrets"
          ;;
        *)
          printf 'Age key (hidden input): '
          read -r -s age_key
          printf '\n'
          if [ -z "$age_key" ]; then
            die "empty age key"
          fi
          tmp_key="$(mktemp)"
          chmod 600 "$tmp_key"
          printf '%s\n' "$age_key" >"$tmp_key"
          unset age_key
          if ! recipient="$(age-keygen -y "$tmp_key" 2>/dev/null)"; then
            rm -f "$tmp_key"
            die "that is not a valid age private key"
          fi
          sudo install -m 600 -o root -g root "$tmp_key" "$AGE_KEY_FILE"
          rm -f "$tmp_key"
          age_ok=1
          echo "installed at $AGE_KEY_FILE"
          echo "recipient: $recipient"
          ;;
      esac
    fi

    # sops-nix reads the key as root at boot; a *human* needs a copy they can
    # read, and sops only looks in the places it is allowed to look. Without this
    # an edit fails with "permission denied:
    # /var/lib/sops-nix/infrastructure.age.key", which is confusing, because the
    # host plainly *can* decrypt secrets. It grants nothing new -- whoever runs
    # this is in wheel and can already read the root copy with sudo -- it just
    # makes `sops <file>` work.
    if [ "$age_ok" -eq 1 ]; then
      # mkdir, not `install -d -m`, so that an existing ~/.config keeps its mode
      # and only the directory holding the key is tightened.
      user_key_dir="$(dirname "$USER_AGE_KEY_FILE")"
      mkdir -p "$user_key_dir"
      chmod 700 "$user_key_dir"
      if sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" \
        "$AGE_KEY_FILE" "$USER_AGE_KEY_FILE"; then
        echo "also installed a copy for your user at $USER_AGE_KEY_FILE"
      else
        warn "could not install $USER_AGE_KEY_FILE; to edit a secret use:"
        warn "  sudo SOPS_AGE_KEY_FILE=$AGE_KEY_FILE sops <file>"
      fi
    fi

    # Check the recipient against what .sops.yaml actually authorises. A key
    # that decrypts nothing is the failure mode this whole script exists for.
    # The checkout stays: the NetBird step decrypts the setup key out of it, and
    # it is where secrets are edited afterwards.
    if [ "$age_ok" -eq 1 ] && [ "$github_ok" -eq 1 ]; then
      step "Checking the recipient against .sops.yaml"
      if [ -d "$SECRETS_CHECKOUT/.git" ]; then
        echo "using the existing checkout at $SECRETS_CHECKOUT"
        secrets_dir="$SECRETS_CHECKOUT"
      elif git clone --quiet --depth 1 "$SECRETS_URL" "$SECRETS_CHECKOUT" 2>/dev/null; then
        secrets_dir="$SECRETS_CHECKOUT"
      else
        warn "could not clone ''${SECRETS_REPO} to $SECRETS_CHECKOUT"
      fi

      if [ -n "$secrets_dir" ]; then
        expected="$(grep -oE 'age1[0-9a-z]{58}' "$secrets_dir/.sops.yaml" | sort -u || true)"
        if [ -z "$expected" ]; then
          warn "no age recipients found in ''${SECRETS_REPO}/.sops.yaml"
        elif printf '%s\n' "$expected" | grep -qx "$recipient"; then
          echo "OK: this key is authorised to decrypt the secrets"
        else
          warn "this key's recipient is NOT in ''${SECRETS_REPO}/.sops.yaml"
          warn "decryption will fail; authorised recipients are:"
          printf '%s\n' "$expected" | sed 's/^/         /'
        fi
      fi
    fi

    # The checkout exists so that a human can edit secrets on this host, and that
    # needs a git identity. Without one `git commit` fails with "Author identity
    # unknown", which reads like a repository problem rather than a host one.
    if [ -d "$SECRETS_CHECKOUT/.git" ] \
      && [ -z "$(git -C "$SECRETS_CHECKOUT" config --get user.email || true)" ]; then
      git_identity_ok=0
      warn "git has no author identity on this host, so committing here fails:"
      warn "  git -C $SECRETS_CHECKOUT config user.name  '<your name>'"
      warn "  git -C $SECRETS_CHECKOUT config user.email '<your email>'"
    fi

    # ------------------------------------------------------------- 3. NetBird
    # Register with a setup key rather than an interactive SSO login: SSO peers
    # inherit the account's "Peer Session Expiration" and drop off the mesh when
    # it fires. The key is a shared secret, so the normal path decrypts it here
    # with the age key from step 2 instead of making the operator paste it.
    step "NetBird"
    if netbird status 2>/dev/null | grep -q "Management: Connected"; then
      echo "already connected"
    else
      setup_key=""
      if [ -n "$SETUP_KEY_FILE" ]; then
        [ -f "$SETUP_KEY_FILE" ] || die "no such setup key file: $SETUP_KEY_FILE"
        setup_key="$SETUP_KEY_FILE"
        echo "using the setup key from $SETUP_KEY_FILE"
      else
        setup_key="$(setup_key_from_secrets || true)"
        if [ -n "$setup_key" ]; then
          echo "using the setup key from $SETUP_KEY_SECRET"
        fi
      fi

      if [ -n "$setup_key" ]; then
        sudo netbird up --setup-key-file "$setup_key"
        if [ "$setup_key" != "$SETUP_KEY_FILE" ]; then
          rm -f "$setup_key"
        fi
      elif [ -t 0 ]; then
        echo "no setup key available; falling back to interactive SSO login"
        sudo netbird up
      else
        warn "no setup key available, and no terminal for an SSO login; skipping"
        warn "the deployed configuration registers the peer on its first rebuild"
      fi
    fi

    # The two registrations look identical until the session expires a day
    # later, so say which one this host actually got.
    status_out="$(netbird status 2>/dev/null || true)"
    if printf '%s' "$status_out" | grep -q "Session expires"; then
      warn "this peer is registered with a *user* login, so the account's peer"
      warn "session expiration applies to it: it will need 'netbird up' by hand"
      warn "when the deadline fires."
      warn "The deployed configuration clears that flag instead"
      warn "(functions/netbird-session-expiration.nix), so this stops once the host"
      warn "is rebuilt with api_token present in secrets/shared/netbird.yaml."
      warn "See docs/src/Nix_Config_Architecture.md."
    elif printf '%s' "$status_out" | grep -q "Management: Connected"; then
      echo "OK: connected with no session expiry"
    fi

    # ----------------------------------------------------------------- summary
    step "Summary"
    echo "  [ok]   flake features enabled: $features"
    if [ "$github_ok" -eq 1 ]; then
      echo "  [ok]   GitHub SSH access to ''${SECRETS_REPO}"
    else
      echo "  [FAIL] GitHub SSH access to ''${SECRETS_REPO}: the private flake input cannot be fetched"
    fi
    if [ "$age_ok" -eq 1 ]; then
      echo "  [ok]   SOPS age key at $AGE_KEY_FILE"
      echo "  [ok]   user-readable copy at $USER_AGE_KEY_FILE"
    else
      echo "  [warn] no SOPS age key: sops-nix will not decrypt anything on this host"
    fi
    if [ -d "$SECRETS_CHECKOUT/.git" ]; then
      echo "  [ok]   ''${SECRETS_REPO} checked out at $SECRETS_CHECKOUT"
      echo "         (if 'git push' there is refused, the deploy key is read-only:"
      echo "          add a write-enabled key, or run 'gh auth login' and push over HTTPS)"
    fi
    if [ "$git_identity_ok" -eq 0 ]; then
      echo "  [warn] no git author identity: set user.name and user.email before committing"
    fi
    if printf '%s' "$status_out" | grep -q "Management: Connected"; then
      echo "  [ok]   NetBird peer connected"
    else
      echo "  [warn] NetBird peer not connected: this host is not on the mesh yet"
    fi

    echo
    echo "Next: sudo nixos-rebuild switch --flake ~/nixos-config#<host>"
    echo "Details: docs/src/Playbooks/Handling_Secrets.md"

    if [ "$github_ok" -ne 1 ]; then
      exit 1
    fi
  '';
}
