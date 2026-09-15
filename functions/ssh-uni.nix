# University (NAIST) SSH access.
#
# Declares both the client configuration and the private key, so a rebuilt
# machine gets the same access from the repository alone. The key comes from
# sops-nix (see secrets/ in TJ-coding/nixos-secrets) instead of being copied
# into ~/.ssh by hand.
#
# The private key must be authorised on the university side. For NAIST the
# gateway (sh.naist.jp) and the lab cluster (pine11-pine13) use *different*
# home directories, so the public key has to be appended to the
# authorized_keys of both. See docs/src/Playbooks/University_SSH_Access.md.
{ config, lib, pkgs, secrets, ... }:

let
  cfg = config.services.university-ssh;

  # Compute hosts are reached through the gateway with ProxyJump, so the HPC
  # host never needs a route to them.
  computeBlock = lib.optionalString (cfg.computeHosts != [ ]) ''
    Host ${lib.concatStringsSep " " cfg.computeHosts}
      User ${cfg.remoteUser}
      IdentityFile ${config.sops.secrets.${cfg.secretName}.path}
      IdentitiesOnly yes
      # Cluster nodes are reprovisioned from time to time, so trust them on
      # first use rather than pinning their host keys here.
      StrictHostKeyChecking accept-new
      ProxyJump ${cfg.gatewayAlias}
  '';
in
{
  options.services.university-ssh = {
    enable = lib.mkEnableOption "SSH access to the university (NAIST)";

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "sh.naist.jp";
      description = "University SSH gateway (the public login host).";
    };

    gatewayAlias = lib.mkOption {
      type = lib.types.str;
      default = "naist";
      description = "Short local alias for the gateway.";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      default = "tomoyuki-j";
      description = "User name on the university side.";
    };

    computeHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "pine11" "pine12" "pine13" ];
      description = ''
        Lab/compute hosts reachable through the gateway. Each one is connected
        to with ProxyJump via {option}`gatewayAlias`.
      '';
    };

    keyOwner = lib.mkOption {
      type = lib.types.str;
      default = "tj-coding";
      description = ''
        Local user allowed to read the decrypted private key. This is the
        local account, not the university one.
      '';
    };

    secretName = lib.mkOption {
      type = lib.types.str;
      default = "university-ssh-key";
      description = "Name of the sops secret that holds the private key.";
    };

    sopsFile = lib.mkOption {
      type = lib.types.str;
      default = "${secrets}/secrets/shared/university-ssh-key.yaml";
      description = "Encrypted sops file that holds the private key.";
    };

    keyField = lib.mkOption {
      type = lib.types.str;
      default = "private_key";
      description = "Field inside {option}`sopsFile` containing the key.";
    };

    knownHostKey = lib.mkOption {
      type = lib.types.str;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGvEF9JgjNnNzw5sFHmtPXTbaevP/BarumK/CrvfF5UY";
      defaultText = lib.literalExpression ''"ssh-ed25519 AAAA... "'';
      description = ''
        Public host key of the gateway. Pinning it keeps the first connection
        non-interactive, which is what unattended use (rsync, systemd units)
        needs. Verify with `ssh-keyscan -t ed25519 <gateway>` before trusting.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The only place the key exists is /run/secrets; nothing is copied into
    # the user's home, so the access survives a rebuild and is not forgotten.
    sops.secrets.${cfg.secretName} = {
      sopsFile = cfg.sopsFile;
      key = cfg.keyField;
      owner = cfg.keyOwner;
      mode = "0400";
    };

    programs.ssh.knownHosts."university-gateway" = {
      hostNames = [ cfg.gateway ];
      publicKey = cfg.knownHostKey;
    };

    programs.ssh.extraConfig = ''
      # University (NAIST) access — see functions/ssh-uni.nix.
      Host ${cfg.gatewayAlias}
        HostName ${cfg.gateway}
        User ${cfg.remoteUser}
        IdentityFile ${config.sops.secrets.${cfg.secretName}.path}
        IdentitiesOnly yes

    '' + computeBlock;
  };
}
