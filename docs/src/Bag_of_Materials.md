# Bag of Materials


### Flakes
|Flakes|Hosts|Purpose|
|--|--|--|
|artifacts|[artifacts](hosts/artifacts/configuration.nix)|Storage host: RustFS, lakeFS, KohakuHub|
|highperformancecomputing|[highperformancecomputing](hosts/highperformancecomputing/configuration.nix)|Compute host: Slurm, scientific toolchain, VS Code remote server|

### Hosts

### Templates
|Template|Used by|Purpose|
|--|--|--|
|artifacts.nix|artifacts|Storage workloads (RustFS, KohakuHub, terminal)|
|highperformancecomputing.nix|highperformancecomputing|Slurm single-node cluster, uv/Python toolchain|

### Modules

### Functions

### Apps



## Playbooks

### Adding Docker Compose
1. Adding Compose File and Repository
/var/lib/kohakuhub
2. Handling Volume Paths
3. Handling Networking 
4. Handling Secrets
