{ pkgs }:

pkgs.writeShellApplication {
  name = "bootstrap-auth";

  runtimeInputs = with pkgs; [
    netbird
    gh
    git
  ];

  text = ''
  set -euo pipefail

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

  echo "==> Bootstrap authentication complete."
'';

}