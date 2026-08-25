## Maintinance Guidelines

### Directory Structure
```
nixos-config/
├── hosts/      Contains configuration of physical machines
├── templates/  Groups of modules and functions reused by different machines
├── modules/    Groups of moudles for use by different templates
├── functions/  Smallest component, who serves a specific function
├── apps/       Custom Nix Packages and Docker Files who serves a function
```

## Bag of Materials

### Flakes
|Flakes|Hosts|Purpose|
|--|--|--|
|artifacts|[artifacts](hosts/artifacts/configuration.nix)|

### Hosts

### Templates

### Modules

### Functions

### Apps



nixos-config/
├── flake.nix
├── flake.lock
│
├── hosts/
│   ├── desktop/
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   │
│   ├── laptop/
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   │
│   └── server/
│       ├── configuration.nix
│       └── hardware-configuration.nix
│
├── modules/
│   ├── common/
│   │   ├── default.nix
│   │   ├── packages.nix
│   │   ├── shell.nix
│   │   └── users.nix
│   │
│   ├── desktop/
│   │   ├── default.nix
│   │   ├── audio.nix
│   │   ├── graphics.nix
│   │   └── desktop-environment.nix
│   │
│   ├── development/
│   │   ├── default.nix
│   │   ├── git.nix
│   │   ├── python.nix
│   │   └── containers.nix
│   │
│   └── services/
│       ├── ssh.nix
│       ├── docker.nix
│       └── ...
│
├── home/
│   ├── common.nix
│   ├── desktop.nix
│   └── laptop.nix
│
└── README.md