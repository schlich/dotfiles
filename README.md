# Dotfiles

Personal configuration files managed with GNU stow and Nix home-manager.

## Structure

```
.
├── dot-bashrc              # Bash configuration
├── dot-gitconfig           # Git configuration
├── justfile                # Just command runner recipes
├── dot-config/             # XDG config directory
│   ├── atuin/             # Shell history sync
│   ├── ghostty/           # Terminal emulator
│   └── git/               # Git ignore patterns
└── home-manager/           # Nix home-manager configuration
    ├── flake.nix          # Flake with multiple configurations
    ├── home.nix           # Base home-manager config
    ├── niri.nix           # Niri wayland compositor module
    ├── helix/             # Helix editor config
    └── jj/                # Jujutsu VCS config
```

## Installation with GNU Stow

1. Clone this repository:
   ```bash
   git clone https://github.com/schlich/dotfiles.git ~/dotfiles
   cd ~/dotfiles
   ```

2. Use stow to symlink configs (stow automatically converts `dot-*` to `.`):
   ```bash
   stow .
   ```

## Home Manager Setup

### WSL (no window manager)

```bash
cd ~/dotfiles/home-manager
nix run home-manager/master -- switch --flake .#nixos
```

### Native Linux with Niri

```bash
cd ~/dotfiles/home-manager
nix run home-manager/master -- switch --flake .#nixos-niri
```

This will install niri and related wayland tools (waybar, fuzzel, mako, etc.).

## Updating

### Update flake inputs:
```bash
cd ~/dotfiles/home-manager
nix flake update
home-manager switch --flake .#nixos  # or .#nixos-niri
```

### Sync dotfiles changes:
```bash
cd ~/dotfiles
git pull
stow --restow .
```

## Notes

- The `dot-*` prefix is automatically converted to `.` by GNU stow
- `home-manager/niri.nix` contains niri-specific configuration
- WSL configuration (`nixos`) excludes window manager packages
- Native Linux configuration (`nixos-niri`) includes full desktop setup
