# Keeps this host's own NetBird peer out of the account's "Peer Session
# Expiration", so a machine that is supposed to be up 24/7 does not fall off the
# mesh once a day and wait for somebody to run `netbird up` on it.
#
# Why the setup key in functions/netbird.nix is not enough on its own. NetBird
# applies the account's peer login expiration (24h by default) to every peer that
# was added by *a user*. That is literally what the predicate checks:
#
#   management/server/peer/peer.go
#     func (p *Peer) AddedWithSSOLogin() bool { return p.UserID != "" }
#     func (p *Peer) SessionExpiresAt(accountExpirationEnabled bool, expiresIn time.Duration) time.Time {
#       if !accountExpirationEnabled || !p.AddedWithSSOLogin() || !p.LoginExpirationEnabled {
#         return time.Time{}   // no deadline
#       }
#
# Peers added with a *setup key* are created with `LoginExpirationEnabled: false`
# (`AddedByUser && !temporary` is false for them), so they never expire. The
# setup-key login therefore protects a machine that has not enrolled yet -- but
# it cannot repair one that already enrolled through SSO, because a machine holds
# exactly one login method for the lifetime of its config.json. The client
# refuses outright:
#
#   client/internal/auth/auth.go
#     "this peer was originally enrolled via SSO and its session has expired.
#      Setup keys can only enrol new peers -- run `netbird up` (interactive SSO)"
#
# So there were only two ways out, and both of them put a human in the loop:
# delete the peer and re-enrol it (new overlay IP, DNS label reallocation, group
# memberships to reapply), or flip a toggle in the web dashboard and remember to
# do it again for the next machine. This module removes the human instead.
#
# What it does. `login_expiration_enabled` is a field of the peer record, and the
# Management REST API accepts it on `PUT /api/peers/{id}` -- `UpdatePeer` allows
# changing it for SSO peers and refuses for setup-key peers, which need no change
# anyway. Each host therefore reconciles *its own* peer to `false` at boot and
# hourly, authenticating with a NetBird personal access token from sops.
#
# The account-level toggle is deliberately left alone. This NetBird account
# carries dozens of peers belonging to other people's machines, so disabling the
# policy account-wide to fix three servers would silently change the security
# posture of all of them; the per-peer flag is the surgical version.
#
# Why the request body is assembled so carefully. The API's `PeerRequest` has
# non-omitempty `name`, `ssh_enabled` and `inactivity_expiration_enabled`, so a
# PUT carrying only `login_expiration_enabled` decodes as `name: ""`,
# `ssh_enabled: false`, `inactivity_expiration_enabled: false`. An empty name
# makes `UpdatePeer` regenerate the DNS label from the peer's IP (turning
# `aiagents.netbird.cloud` into `nixos-164-233.netbird.cloud`) and `false`
# disables SSH on the peer. The reconciler therefore reads the current record,
# writes it back with exactly one field changed, and refuses to send anything at
# all if those fields are missing or are not the types the API expects.
#
# Needs `api_token` in nixos-secrets/secrets/shared/netbird.yaml. See
# docs/src/Playbooks/Handling_Secrets.md for creating and rotating it.
{ config, lib, pkgs, secrets, ... }:

let
  # The PAT may not exist yet in the secrets file (today it carries only
  # setup_key). Declaring a sops secret whose key is missing makes
  # sops-install-secrets abort the whole activation -- which would brick every
  # host on rebuild. Top-level key names in a sops-encrypted YAML stay
  # plaintext, so the presence check runs at evaluation time; the module
  # becomes active with no further changes once the token is added.
  hasApiToken =
    lib.hasInfix "api_token:" (builtins.readFile "${secrets}/secrets/shared/netbird.yaml");
in

let
  reconcile = pkgs.writeShellApplication {
    name = "netbird-disable-session-expiration";

    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      netbird
    ];

    text = ''
      api_base="https://api.netbird.io/api"

      log() { printf '%s\n' "$*"; }
      warn() { printf 'warning: %s\n' "$*" >&2; }

      # Injected by systemd as a credential, so the token is not in this unit's
      # environment and does not show up in /proc/*/environ.
      credentials_dir="''${CREDENTIALS_DIRECTORY:?systemd did not provide a credentials directory}"
      token_file="$credentials_dir/api-token"
      if [ ! -r "$token_file" ]; then
        warn "no readable NetBird API token at $token_file"
        exit 1
      fi
      token="$(cat "$token_file")"
      if [ -z "$token" ]; then
        warn "the NetBird API token at $token_file is empty"
        exit 1
      fi

      # This host's own overlay address, in the form the daemon reports it:
      # "100.82.164.233/16". Matching on the address is what keeps the peer from
      # being identified by a name an operator may have changed.
      status_json="$(netbird status --json 2>/dev/null || true)"
      if [ -z "$status_json" ] || ! printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
        log "netbird does not report JSON status yet; nothing to reconcile"
        exit 0
      fi
      own_ip="$(printf '%s' "$status_json" | jq -r '.netbirdIp // ""' | cut -d/ -f1)"
      if [ -z "$own_ip" ]; then
        if [ "$(printf '%s' "$status_json" | jq -r '.daemonStatus // ""')" = "NeedsLogin" ]; then
          # The peer has no overlay address because it needs a login, so it cannot
          # be matched against the API at all. Management also keeps a second,
          # sticky login_expired flag that its expiration sweeper sets and only an
          # SSO login clears (Peer.UpdateLastLogin), so this state cannot be
          # repaired from here -- say what does repair it, because nothing else
          # will.
          warn "this host's NetBird peer needs a login, so it has no overlay address to"
          warn "identify itself by. Run 'netbird up' on it once; the reconciliation that"
          warn "follows then clears the account's expiration flag, so it is the last time."
          exit 0
        fi
        log "netbird is not connected yet; nothing to reconcile"
        exit 0
      fi

      # GET /api/peers returns every peer this token's user may see.
      if ! peers_json="$(curl -sS --fail-with-body \
            -H "Authorization: Token $token" \
            "$api_base/peers")"; then
        warn "GET $api_base/peers failed"
        exit 1
      fi

      peer_json="$(printf '%s' "$peers_json" | jq -c --arg ip "$own_ip" 'map(select(.ip == $ip)) | first // empty')"
      if [ -z "$peer_json" ]; then
        warn "no peer with overlay address $own_ip is visible to this API token"
        warn "the token's user has to be allowed to see and update this peer"
        exit 1
      fi

      peer_id="$(printf '%s' "$peer_json" | jq -r '.id')"
      peer_name="$(printf '%s' "$peer_json" | jq -r '.name')"

      if [ "$(printf '%s' "$peer_json" | jq -r '.login_expiration_enabled')" = "false" ]; then
        log "peer $peer_name ($own_ip): login expiration is already disabled"
        exit 0
      fi

      # Read-modify-write: the peer's own name, SSH and inactivity settings go
      # back untouched, because leaving them out of the body changes them.
      if ! body="$(printf '%s' "$peer_json" | jq -ce '
            if (.name | type) == "string" and (.name | length) > 0
               and (.ssh_enabled | type) == "boolean"
               and (.inactivity_expiration_enabled | type) == "boolean"
            then {
              name: .name,
              ssh_enabled: .ssh_enabled,
              login_expiration_enabled: false,
              inactivity_expiration_enabled: .inactivity_expiration_enabled
            }
            else error("peer record is missing name/ssh_enabled/inactivity_expiration_enabled")
            end')"; then
        warn "refusing to update peer $peer_id: its record is not shaped as this module expects"
        exit 1
      fi

      if ! updated_json="$(curl -sS --fail-with-body -X PUT \
            -H "Authorization: Token $token" \
            -H 'Content-Type: application/json' \
            --data "$body" \
            "$api_base/peers/$peer_id")"; then
        warn "PUT $api_base/peers/$peer_id failed"
        exit 1
      fi

      # `.login_expiration_enabled` is read without `//`: jq's alternative
      # operator treats `false` as empty, so `false // "unknown"` is "unknown"
      # and a successful write would look like a failure.
      result="$(printf '%s' "$updated_json" | jq -r '.login_expiration_enabled | tostring')"
      if [ "$result" != "false" ]; then
        warn "peer $peer_name ($own_ip) still reports login_expiration_enabled=$result"
        exit 1
      fi

      log "peer $peer_name ($own_ip): login expiration disabled, this peer no longer expires"
    '';
  };
in
{
  sops.secrets."netbird-api-token" = lib.mkIf hasApiToken {
    sopsFile = "${secrets}/secrets/shared/netbird.yaml";
    key = "api_token";
  };

  systemd.services.netbird-disable-session-expiration = lib.mkIf hasApiToken {
    description = "Take this host's NetBird peer out of the account's session-expiration policy";

    after = [ "netbird.service" ];
    wants = [ "netbird.service" ];
    # No Requires/After on sops-install-secrets.service: that unit only exists
    # when sops.useSystemdActivation is true, and a dependency on a missing
    # unit makes systemd refuse to start this one at all (the same silent
    # failure that disabled netbird-login for weeks). With the default
    # activation-script mode the secrets are installed during system
    # activation, which precedes every boot-time service.

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${reconcile}/bin/netbird-disable-session-expiration";
      LoadCredential = "api-token:${config.sops.secrets."netbird-api-token".path}";
    };
  };

  systemd.timers.netbird-disable-session-expiration = lib.mkIf hasApiToken {
    description = "Re-check this host's NetBird session-expiration flag hourly";

    wantedBy = [ "timers.target" ];

    timerConfig = {
      # The first run happens before the daemon has necessarily logged in; it
      # exits cleanly when there is no overlay address yet, and the hourly run
      # picks the peer up afterwards.
      OnBootSec = "3min";
      # Comfortably inside the 24h expiration window: if the flag is ever set
      # back (a fresh enrolment, or somebody editing the peer in the dashboard)
      # it is cleared again long before a session could actually lapse.
      OnUnitActiveSec = "1h";
      # Three hosts share one account; do not make them race on the same API.
      RandomizedDelaySec = "5min";
    };
  };
}
