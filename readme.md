## Maintinance Guidelines

### Directory Structure
```
📂 nixos-config/
├─ 📂 hosts/      Contains configuration of physical machines
├─ 📂 templates/  Groups of modules and functions reused by different machines
├─ 📂 modules/    Groups of moudles for use by different templates
├─ 📂 functions/  Smallest component, who serves a specific function
├─ 📂 apps/       Custom Nix Packages and Docker Files who serves a function
```
### Choosing Folder

| Folder | Put it here when... | Typical contents |
|---|---|---|
| `hosts/` | It is specific to a physical machine | Hardware configuration, host-specific settings |
| `templates/` | It combines reusable configuration for a class of machines | Desktop template, server template, development template |
| `modules/` | It provides one reusable NixOS feature | SSH, Docker, graphics, users |
| `functions/` | It is a small reusable building block | Nix functions, helpers, generators |
| `apps/` | It represents a custom application or package | Custom Nix packages, Docker Compose applications |

#### Dependency Direction
```
hosts
  ↓
templates
  ↓
modules
  ↓
functions
```
