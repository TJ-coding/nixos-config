# Single-node compute host for scientific workloads.
# Provides: SSH, NetBird, VS Code remote server (nix-ld), Slurm + Munge.
# Warning: Opens SSH port
{config, pkgs, ...}:
{
  imports =
    [ # Include the results of the hardware scan.
      ../modules/servers.nix
    ];

  # modules/servers.nix imports functions/vscode_remote_server.nix, which sets
  # programs.nix-ld.enable = true. That is what lets the VS Code Remote-SSH
  # server run prebuilt binaries on NixOS.

  # Munge is the authentication plugin Slurm uses; the unit is `munged` and
  # needs an explicit key file path.
  services.munge = {
    enable = true;
    password = "/var/lib/munge-key/munge.key";
  };

  # Single-node Slurm cluster: the scheduler owns long jobs.
  services.slurm = {
    server.enable = true;
    client.enable = true;
    controlMachine = "nixos";
    controlAddr = "127.0.0.1";
    nodeName = [ "nixos CPUs=16 RealMemory=14000 State=UNKNOWN" ];
    partitionName = [ "main Nodes=nixos Default=YES MaxTime=INFINITE State=UP" ];
    extraConfig = ''
      SlurmctldParameters=enable_configless
      ReturnToService=2
    '';
  };

  # Scientific toolchain.
  environment.systemPackages = with pkgs; [
    uv
    python3
    gcc
    gfortran
    openblas
    tmux
    htop
    iotop
  ];

  # Give each job all cores by default.
  environment.variables = {
    OMP_NUM_THREADS = "16";
    OPENBLAS_NUM_THREADS = "16";
  };
}
