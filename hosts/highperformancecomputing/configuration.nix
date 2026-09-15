# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../templates/highperformancecomputing.nix
      ../../functions/ssh-uni.nix
    ];

  # SSH access to the university filesystem. The private key is injected from
  # sops at activation time; nothing is copied into ~/.ssh by hand.
  services.university-ssh.enable = true;

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  networking.hostName = "nixos"; # Define your hostname.

  # Proxmox guest integration: clean shutdown + IP reporting from the hypervisor.
  services.qemuGuest.enable = true;

  # Data disk (2T zvol on the hypervisor's ZFS hdd-datasets pool) holding the
  # ACL26 corpus; keeps bulk data off the thin-provisioned root volume.
  fileSystems."/mnt/hdd-data" = {
    device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2";
    fsType = "ext4";
  };
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Asia/Tokyo";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ja_JP.UTF-8";
    LC_IDENTIFICATION = "ja_JP.UTF-8";
    LC_MEASUREMENT = "ja_JP.UTF-8";
    LC_MONETARY = "ja_JP.UTF-8";
    LC_NAME = "ja_JP.UTF-8";
    LC_NUMERIC = "ja_JP.UTF-8";
    LC_PAPER = "ja_JP.UTF-8";
    LC_TELEPHONE = "ja_JP.UTF-8";
    LC_TIME = "ja_JP.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the XFCE Desktop Environment.
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.xfce.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."tj-coding" = {
    isNormalUser = true;
    description = "tj-coding";
    extraGroups = [ "networkmanager" "wheel" ];
    openssh.authorizedKeys.keys = [
      # macbook
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKcFdbR8v+7Bw/czOw6fFewyvdx2gtQzr2iGo5UpDk+a tomoyuki-j@macbook"
      # rtx3090 hypervisor
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC0CvQ9iLfVBHXt4hcv5gv5r2G5q+RCU1DT3hAkK6kgLeO8Wwy5NYLg4yftyteWYzLa+/A6P8nzGNcN/kLrW8h+Btl8WqTXEmdHvCE55lHinNGl0uPska2BFC/c9dozvLPiiVmrgGN9EQaKqi6HZQF+w2ubF7GU5wkO3xwX4Qm7CLMwOx4hV8M9/XHBD4Xxg939ZZjrKXIniT1CMAljSC2OY/i2neQyWr35UedJLR/0xtxm+1MuoKNI+pg5xCelgheEkvAmXqaGvO6OGBfSxjj83UMO0efzfhoVXmqpwMqvuNGxjyuhVsWf+fO9xYXAI85vJNkKwm3OIkuiyBZnBbn1ufswfHO9+vdOyEchET+cM3AGTHmgaJWRhBZM6fcAvPeAGZDtXVeONihKJAdbEsk0hUspAlBHKEMCW2cxNhA95uyLpsYSOiA+t2BbfeVHop1Xt/i1xwnNeXkol78lAsYkjlyzKGQEHHiCSgPtKDaGH6mF0fJoQmKHMuRJC8LKoh1JDc72ZJ7GGuT/D5s0PfFY5r6zHWg/LFVkC7VmLLzLy7Wfx0017crIeNKNmWw+ZVaILWt5qNIt/C/VVAlj0c+nk56kaJTVkkjb8ys+YX0kNk3RRPpbApEj+dOjKXYKYRehWYz3ZKjs/oycCufVOXSnPgFAB+vF+/gQsqjUquQ6nw== root@rtx3090"
      # vm100-acl
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDW2C/rIWJnPRNU4pxEDXoaRrB0RWcJm3N+Xnv8nacCw vm100-acl"
    ];
  };

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable flakes so the host can rebuild itself from this flake.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?
}
