{ pkgs }:

# `nix run .#enroll` -- first thing to run on a freshly installed host.
#
# Generates the host's hardware configuration, then hands over to
# bootstrap-auth (see apps/bootstrap-auth.nix) for the NetBird / GitHub / SOPS
# credentials that a host needs before it can rebuild from this flake.
let
  bootstrap-auth = pkgs.callPackage ./bootstrap-auth.nix { };
in
pkgs.writeShellApplication {
  name = "enroll";

  runtimeInputs = [
    bootstrap-auth
    pkgs.coreutils
    pkgs.git
    pkgs.hostname
    pkgs.nixos-install-tools
  ];

  text = ''
    repo="$(git rev-parse --show-toplevel)"

    # The argument is the *flake attribute* name, which is also the name of the
    # host directory and of the host's directory in nixos-secrets. It is not
    # necessarily the system hostname: every machine in this fleet sets
    # networking.hostName = "nixos", so defaulting to the hostname silently
    # creates a bogus hosts/nixos/ that no flake attribute refers to.
    if [ -n "''${1:-}" ]; then
      host="$1"
    else
      host="$(hostname)"
      echo "note: no host name given, using the system hostname: $host"
      if [ -d "$repo/hosts" ]; then
        echo "      host directories are named after the flake attribute, not the"
        echo "      hostname. Existing ones are:"
        for dir in "$repo"/hosts/*; do
          if [ -d "$dir" ]; then
            printf '        %s\n' "$(basename "$dir")"
          fi
        done
        echo "      Re-run as: enroll <flake-host-name>"
      fi
    fi

    host_dir="$repo/hosts/$host"

    echo "==> Enrolling $host"
    echo "    repository: $repo"
    echo "    host dir:   $host_dir"

    if [ -d "$host_dir" ]; then
      echo "note: $host_dir already exists"
    else
      mkdir -p "$host_dir"
    fi

    hw="$host_dir/hardware-configuration.nix"
    if [ -f "$hw" ]; then
      echo "note: $hw already exists; not regenerating it"
    else
      echo "==> Generating hardware configuration"
      tmp_hw="$(mktemp)"
      if sudo nixos-generate-config --show-hardware-config | tee "$tmp_hw" >/dev/null; then
        cat "$tmp_hw" >"$hw"
        echo "    wrote $hw"
      else
        rm -f "$tmp_hw"
        echo "error: nixos-generate-config failed" >&2
        exit 1
      fi
      rm -f "$tmp_hw"
    fi

    echo
    echo "==> Credentials"
    bootstrap-auth

    echo
    echo "==> Remaining manual steps"
    echo "    1. write $host_dir/configuration.nix"
    echo "    2. add a nixosConfigurations.$host entry to flake.nix"
    echo "    3. sudo nixos-rebuild switch --flake .#$host"
  '';
}
