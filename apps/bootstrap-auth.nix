{ pkgs }:

# Give a freshly installed host the credentials it needs to take part in this
# flake:
#
#   1. NetBird membership, so the host is reachable.
#   2. GitHub SSH access to the *private* `secrets` flake input
#      (git+ssh://git@github.com/TJ-coding/nixos-secrets.git). Without this,
#      `nixos-rebuild` cannot fetch the input, and the failure surfaces as a
#      confusing `Permission denied (publickey)` during evaluation.
#   3. The SOPS age key at /var/lib/sops-nix/infrastructure.age.key, which is
#      what sops-nix uses to decrypt secrets into /run/secrets.
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
    openssh
  ];

  text = ''
    SECRETS_REPO="TJ-coding/nixos-secrets"
    SECRETS_URL="git@github.com:''${SECRETS_REPO}.git"
    AGE_KEY_FILE="/var/lib/sops-nix/infrastructure.age.key"
    SSH_KEY="''${HOME}/.ssh/id_ed25519"

    github_ok=0
    age_ok=0

    step() { printf '\n==> %s\n' "$*"; }
    warn() { printf 'warning: %s\n' "$*" >&2; }
    die() { printf 'error: %s\n' "$*" >&2; exit 1; }

    need_tty() {
      if [ ! -t 0 ]; then
        die "$1 needs an interactive terminal (re-run with: ssh -t <host>)"
      fi
    }

    can_read_secrets() {
      timeout 60 git ls-remote "$SECRETS_URL" HEAD >/dev/null 2>&1
    }

    # --------------------------------------------------------------- 1. NetBird
    step "NetBird"
    if netbird status 2>/dev/null | grep -q "Management: Connected"; then
      echo "already connected"
    else
      sudo netbird up
    fi

    # Turn a "Permission denied (publickey)" into something readable.
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
      ssh-keyscan -H github.com >>"''${HOME}/.ssh/known_hosts" 2>/dev/null || true
    fi

    # --------------------------------------------------------------- 2. GitHub
    # The private flake input is fetched over SSH, so git needs a key GitHub
    # accepts. HTTPS credentials are irrelevant here: a git+ssh:// URL never
    # consults a credential helper, which is why `gh auth setup-git` alone does
    # not make the secrets input fetchable.
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

    # ------------------------------------------------------------ 3. SOPS age key
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

    # Check the recipient against what .sops.yaml actually authorises. A key
    # that decrypts nothing is the failure mode this whole script exists for.
    if [ "$age_ok" -eq 1 ] && [ "$github_ok" -eq 1 ]; then
      step "Checking the recipient against .sops.yaml"
      clone_dir="$(mktemp -d)"
      if git clone --quiet --depth 1 "$SECRETS_URL" "$clone_dir/secrets" 2>/dev/null; then
        expected="$(grep -oE 'age1[0-9a-z]{58}' "$clone_dir/secrets/.sops.yaml" | sort -u || true)"
        if [ -z "$expected" ]; then
          warn "no age recipients found in ''${SECRETS_REPO}/.sops.yaml"
        elif printf '%s\n' "$expected" | grep -qx "$recipient"; then
          echo "OK: this key is authorised to decrypt the secrets"
        else
          warn "this key's recipient is NOT in ''${SECRETS_REPO}/.sops.yaml"
          warn "decryption will fail; authorised recipients are:"
          printf '%s\n' "$expected" | sed 's/^/         /'
        fi
      else
        warn "could not clone ''${SECRETS_REPO} to check recipients"
      fi
      rm -rf "$clone_dir"
    fi

    # ----------------------------------------------------------------- summary
    step "Summary"
    if [ "$github_ok" -eq 1 ]; then
      echo "  [ok]   GitHub SSH access to ''${SECRETS_REPO}"
    else
      echo "  [FAIL] GitHub SSH access to ''${SECRETS_REPO}: the private flake input cannot be fetched"
    fi
    if [ "$age_ok" -eq 1 ]; then
      echo "  [ok]   SOPS age key at $AGE_KEY_FILE"
    else
      echo "  [warn] no SOPS age key: sops-nix will not decrypt anything on this host"
    fi

    echo
    echo "Next: sudo nixos-rebuild switch --flake ~/nixos-config#<host>"
    echo "Details: docs/src/Playbooks/Handling_Secrets.md"

    if [ "$github_ok" -ne 1 ]; then
      exit 1
    fi
  '';
}
