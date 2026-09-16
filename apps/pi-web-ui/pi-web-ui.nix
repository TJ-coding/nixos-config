# pi-web-ui — browser cockpit for the pi coding agent.
#
# The pi SDK runs in-process and streams to the browser over WebSocket: chat,
# tool calls, a terminal, a file tree, and the same session history the pi CLI
# writes. Upstream ships this as an npm package (no flake, not in nixpkgs), so
# it is deployed the way upstream documents: npm installs pi-web-ui and the pi
# CLI into a mutable prefix inside the service user's home, and NixOS owns the
# systemd units. PI_WEB_MANAGED=1 tells the UI it was deployed externally,
# which hides its self-update / pi-install / plugin-install buttons.
#
# Provider credentials are deliberately NOT in this repository: pi reads them
# from <workspace>/.pi/agent/{auth,models,provider-keys}.json, which has to be
# copied to the host out of band (they are secrets). Without them the UI starts
# and serves, but no model can answer.
#
# Security: this UI drives a coding agent that can run bash and write files as
# `user`, so it is a root-equivalent-to-that-user endpoint. It binds 0.0.0.0 by
# default but the firewall only opens the port on the interfaces listed in
# `firewallInterfaces` — never on a host's public address — and PI_WEB_TOKEN
# (generated on first start into <prefix>/env, mode 0600) gates every request.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.pi-web-ui;

  # Mutable npm prefix in the service user's home. It cannot live in the store
  # because npm writes into it, so the version stamp makes the install step
  # idempotent and re-runnable whenever a version is bumped.
  prefix = "${cfg.workspace}/.pi-web-ui";

  installScript = pkgs.writeShellScript "pi-web-ui-install" ''
    set -eu

    prefix=${lib.escapeShellArg prefix}
    wanted=${lib.escapeShellArg "${cfg.piWebUiVersion}+pi-${cfg.piVersion}"}

    mkdir -p "$prefix"
    export npm_config_cache="$prefix/.npm"
    export npm_config_fund=false
    export npm_config_audit=false

    if [ "$(cat "$prefix/.stamp" 2>/dev/null || true)" != "$wanted" ]; then
      echo "installing pi-web-ui@${cfg.piWebUiVersion} and pi@${cfg.piVersion} into $prefix"
      ${pkgs.nodejs}/bin/npm install --global --prefix "$prefix" \
        "pi-web-ui@${cfg.piWebUiVersion}" \
        "@earendil-works/pi-coding-agent@${cfg.piVersion}"
      printf '%s\n' "$wanted" > "$prefix/.stamp"
    else
      echo "pi-web-ui $wanted already installed"
    fi

    # Bearer token for the HTTP/WS endpoint; created once, never in the store.
    if [ ! -s "$prefix/env" ]; then
      umask 077
      token="$(${pkgs.coreutils}/bin/head -c 24 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '=+/')"
      printf 'PI_WEB_TOKEN=%s\n' "$token" > "$prefix/env"
      echo "generated $prefix/env (contains PI_WEB_TOKEN)"
    fi
  '';
in
{
  options.services.pi-web-ui = {
    enable = lib.mkEnableOption "pi-web-ui (web cockpit for the pi coding agent)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "tj-coding";
      description = "User the UI, and the agent it drives, run as.";
    };

    workspace = lib.mkOption {
      type = lib.types.str;
      default = "/home/tj-coding";
      description = "Directory the agent may read/write and where its terminal starts.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "TCP port the UI listens on.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to bind; reachability is what the firewall decides.";
    };

    piWebUiVersion = lib.mkOption {
      type = lib.types.str;
      default = "0.85.0";
      description = "pi-web-ui version installed by npm.";
    };

    piVersion = lib.mkOption {
      type = lib.types.str;
      default = "0.85.1";
      description = "@earendil-works/pi-coding-agent version installed alongside it.";
    };

    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Strict Host-header allow-list (PI_WEB_ALLOW_HOSTS), on top of the
        always-on same-authority check. Empty adds no extra restriction.
      '';
    };

    firewallInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Interfaces to open `port` on. Scoped per interface on purpose: opening
        the port globally would also expose this host's public IPv6 address.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # `pi` and `pi-web-ui` land in the mutable prefix, so put it on the PATH of
    # login shells rather than in environment.systemPackages.
    environment.etc."profile.d/pi-web-ui.sh".text = ''
      export PATH="${prefix}/bin''${PATH:+:}$PATH"
    '';

    networking.firewall.interfaces = lib.mkMerge (
      map
        (iface: { ${iface}.allowedTCPPorts = [ cfg.port ]; })
        cfg.firewallInterfaces
    );

    systemd.services.pi-web-ui-install = {
      description = "Install pi-web-ui and the pi CLI into a mutable npm prefix";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # node to run npm; the rest is what node-pty's native build needs.
      path = with pkgs; [
        nodejs
        gcc
        gnumake
        python3
        openssl
        cacert
      ];
      environment = {
        HOME = cfg.workspace;
        npm_config_prefix = prefix;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = "users";
        WorkingDirectory = cfg.workspace;
        ExecStart = installScript;
      };
    };

    systemd.services.pi-web-ui = {
      description = "pi-web-ui — web cockpit for the pi coding agent";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "pi-web-ui-install.service" ];
      requires = [ "pi-web-ui-install.service" ];

      environment = {
        HOME = cfg.workspace;
        PI_WEB_CWD = cfg.workspace;
        PI_WEB_HOST = cfg.host;
        PI_WEB_PORT = toString cfg.port;
        # Declares the instance externally deployed, hiding self-update and
        # pi/plugin installs in the UI.
        PI_WEB_MANAGED = "1";
      } // lib.optionalAttrs (cfg.allowedHosts != [ ]) {
        PI_WEB_ALLOW_HOSTS = lib.concatStringsSep "," cfg.allowedHosts;
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = "users";
        WorkingDirectory = cfg.workspace;
        # Carries PI_WEB_TOKEN; absent until the install unit has run once.
        EnvironmentFile = "-${prefix}/env";
        ExecStart = "${prefix}/bin/pi-web-ui --no-browser --cwd ${cfg.workspace}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
