{ config, lib, pkgs, ... }:

with lib;

{
  imports =
    [
      ../../functions/netbird.nix
  ];

  config = {
    # Changes color of zsh
environment.variables.EZA_COLORS =
  "di=36:fi=0:ln=35:ex=32";
      programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      shellAliases = {
        ll = "ls -lah";
        la = "ls -A";
      };

      interactiveShellInit = ''
        fastfetch
      '';
    };

programs.starship = {
  enable = true;
  settings = builtins.fromTOML (builtins.readFile ./starship.toml);

};

environment.etc."fastfetch/config.jsonc".text = ''
  {
    "logo": {
      "type": "builtin",
      "source": "NixOS2"
    },
    "display": {
      "separator": "  "
    },
    "modules": [
      "title",
      "separator",
      "os",
      "kernel",
      "uptime",
      "shell",
      "terminal",
      "cpu",
      "memory",
      "disk",
      "localip"
    ]
  }
'';

    programs.tmux = {
      enable = true;
      clock24 = true;
      terminal = "tmux-256color";
      historyLimit = 10000;
    };

    environment.systemPackages = with pkgs; [
      fastfetch    ];

    # Make zsh the default shell for users managed here.
    users.defaultUserShell = pkgs.zsh;
  };
}