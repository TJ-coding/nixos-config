{ pkgs }:

pkgs.writeShellApplication {
  name = "bootstrap-auth";

  runtimeInputs = with pkgs; [
    netbird
    gh
    git
    coreutils
  ];

  text = ''
    set -euo pipefail

    SOPS_AGE_KEY_FILE="/var/lib/sops-nix/infrastructure.age.key"

    echo "==> Connecting to NetBird..."
    sudo netbird up

    echo "==> Authenticating with GitHub..."
    gh auth login --git-protocol ssh
    gh auth setup-git

    if [ -z "$(git config --global user.name || true)" ] ||
       [ -z "$(git config --global user.email || true)" ]; then

      echo "==> Configuring Git identity..."

      git config --global user.name \
        "$(gh api user --jq '.name // .login')"

      git config --global user.email \
        "$(gh api user --jq '.email // (.login + "@users.noreply.github.com")')"
    fi

    if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
      echo
      echo "==> Configuring SOPS age key"
      echo
      echo "Paste the infrastructure age key."
      echo "It will not be echoed to the terminal."
      echo

      sudo mkdir -p "$(dirname "$SOPS_AGE_KEY_FILE")"

      while true; do
        read -r -s -p "Age key: " age_key
        echo

        if [ -n "$age_key" ]; then
          break
        fi

        echo "Age key cannot be empty."
      done

      printf '%s\n' "$age_key" |
        sudo tee "$SOPS_AGE_KEY_FILE" >/dev/null

      unset age_key

      sudo chmod 600 "$SOPS_AGE_KEY_FILE"
      sudo chown root:root "$SOPS_AGE_KEY_FILE"

      echo "==> SOPS age key installed."
    else
      echo "==> SOPS age key already exists; keeping it."
    fi

    echo
    echo "==> Bootstrap authentication complete."
  '';
}