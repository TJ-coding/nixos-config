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

    echo "==> Configuring Git identity..."

    GITHUB_NAME="$(gh api user --jq '.name // .login')"
    GITHUB_EMAIL="$(gh api user --jq '.email // empty')"

    if [ -z "$GITHUB_EMAIL" ]; then
      echo "GitHub has no public email."
      echo "Please configure your Git email manually."
      exit 1
    fi

    git config --global user.name "$GITHUB_NAME"
    git config --global user.email "$GITHUB_EMAIL"

    echo "==> Git configured as:"
    echo "    $GITHUB_NAME <$GITHUB_EMAIL>"

    echo "==> Bootstrap authentication complete."
  '';
}