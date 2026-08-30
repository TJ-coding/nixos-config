{ pkgs }:

pkgs.writeShellApplication {
  name = "kohaku-bootstrap";

  runtimeInputs = with pkgs; [
    coreutils
    git
    hostname
    nixos-install-tools
  ];

  text = ''
    set -euo pipefail

    repo="$(git rev-parse --show-toplevel)"
    hostname="$(hostnamectl hostname)"

    host_dir="$repo/hosts/$hostname"

    echo "==> Bootstrapping $hostname"
    echo "    Repository: $repo"
    echo "    Host:       $host_dir"

    if [ -e "$host_dir" ]; then
      echo "error: host directory already exists: $host_dir" >&2
      exit 1
    fi

    mkdir -p "$host_dir"

    echo "==> Generating hardware configuration"

    sudo nixos-generate-config \
      --show-hardware-config \
      > "$host_dir/hardware-configuration.nix"

    echo "==> Hardware configuration written to:"
    echo "    $host_dir/hardware-configuration.nix"

    echo "==> Running bootstrap authentication"

    nix \
      --extra-experimental-features 'nix-command flakes' \
      eval \
      --impure \
      --expr '
        let
          pkgs = import <nixpkgs> {};
        in
          import ./apps/bootstrap-auth.nix { inherit pkgs; }
      '

    echo
    echo "==> Bootstrap complete."
    echo "    Host: $hostname"
    echo "    Hardware: $host_dir/hardware-configuration.nix"
  '';
}