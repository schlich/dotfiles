# What survives a reboot on asus once impermanence wipes @root and @home.
# Everything else on / and /home is recreated from the NixOS and Home Manager
# configurations at boot. `fs-diff` lists files that no entry here covers.
{
  system = {
    directories = [
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/NetworkManager"
      "/etc/NetworkManager/system-connections"
      "/var/lib/bluetooth"
      "/var/lib/tailscale"
      "/var/lib/docker"
      "/var/lib/AccountsService"
      "/var/lib/upower"
      "/var/lib/power-profiles-daemon"
      "/var/lib/udisks2"
      "/var/lib/machines"
      "/var/lib/portables"
      "/var/lib/misc"
      "/var/lib/boot-postmortem"
      "/var/lib/nixos-switch-main"
      "/var/lib/noctalia-greeter"
      "/var/lib/lastlog"
      "/var/db/sudo"
      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      {
        directory = "/root";
        mode = "0700";
      }
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/etc/wpa_supplicant/imperative.conf"
      "/var/lib/logrotate.status"
    ];
  };

  users.schlich = {
    directories = [
      # Projects, flat; the knowledge base tags each with its workspaces. A new
      # project created at the top of ~ is wiped at reboot; create it here.
      "Projects"
      # Zotero's data directory (its profile is .zotero below).
      "Zotero"

      # XDG user directories; the unused ones point at Downloads.
      "Documents"
      "Downloads"
      "Pictures"
      "Videos"

      # Repositories that stay at the top of ~: configuration and tools
      # reference dotfiles and kb by absolute path, and the kb workspaces
      # find their repository by a relative path.
      "dotfiles"
      "kb"
      "kb-profile"
      "kb-public-split"
      "newsletter-agent"
      "go"

      # Tool and agent state at the top of ~.
      ".agents"
      ".atuin"
      ".bend"
      ".bun"
      ".cache"
      ".cargo"
      ".claude"
      ".codex"
      ".copilot"
      ".dagster"
      ".docker"
      ".gemini"
      {
        directory = ".gnupg";
        mode = "0700";
      }
      # Luvus's session, task ledger, leases, and the task worktrees.
      {
        directory = ".luvus";
        mode = "0700";
      }
      ".metavr"
      ".mozilla"
      ".newsletter-agent"
      ".nix-defexpr"
      ".npm"
      ".paseo"
      ".pixi"
      ".pki"
      ".prefect"
      {
        directory = ".ssh";
        mode = "0700";
      }
      ".t3"
      ".zotero"

      # ~/.config entries that applications write. Entries Home Manager links
      # from the store are recreated at activation and are not listed.
      ".config/.wrangler"
      ".config/Antigravity"
      ".config/Bitwarden CLI"
      ".config/BraveSoftware"
      ".config/Claude"
      ".config/Codex"
      ".config/Paseo"
      ".config/T3 Code (Alpha)"
      ".config/acreom"
      ".config/ai.opencode.desktop"
      ".config/atuin"
      ".config/autostart"
      ".config/bat"
      ".config/bottom"
      ".config/btop"
      ".config/cachix"
      ".config/carapace"
      ".config/chromium"
      ".config/dconf"
      ".config/direnv"
      ".config/discord"
      ".config/environment.d"
      ".config/flakehub"
      ".config/fontconfig"
      ".config/gh"
      ".config/gh-dash"
      ".config/ghostty"
      ".config/git"
      ".config/go"
      ".config/google-chrome"
      ".config/google-chrome-beta"
      ".config/google-chrome-for-testing"
      ".config/google-chrome-headless"
      ".config/google-chrome-unstable"
      ".config/gphoto"
      ".config/gtk-3.0"
      ".config/gtk-4.0"
      ".config/harbor"
      ".config/helix"
      ".config/herdr"
      ".config/htop"
      ".config/intelli-shell"
      ".config/jj"
      ".config/marimo"
      ".config/matplotlib"
      ".config/mcp"
      ".config/meta"
      ".config/metavr"
      ".config/microsoft-edge"
      ".config/nautilus"
      ".config/newsboat"
      ".config/ngrok"
      ".config/niri"
      ".config/nix"
      ".config/nix-inspect"
      ".config/noctalia"
      ".config/nom"
      ".config/nushell"
      ".config/opencode"
      ".config/openvr"
      ".config/openxr"
      ".config/opera"
      ".config/pet"
      ".config/process-compose"
      ".config/pulse"
      ".config/rclone"
      ".config/rio"
      ".config/secretspec"
      ".config/stb"
      ".config/superProductivity"
      ".config/systemd"
      ".config/t3code"
      ".config/tailscale"
      ".config/tealdeer"
      ".config/udiskie"
      ".config/vivaldi"
      ".config/wayvr"
      ".config/wivrn"
      ".config/yazelix"
      ".config/yazi"

      # ~/.local
      ".local/bin"
      ".local/delta.app"
      ".local/lib"
      ".local/share/Trash"
      ".local/share/agenttycoon"
      ".local/share/applications"
      ".local/share/atuin"
      ".local/share/chrome-devtools-mcp"
      ".local/share/com.github.githubapp"
      ".local/share/cross.stream"
      ".local/share/cursor-agent"
      ".local/share/dbus-1"
      ".local/share/delta"
      ".local/share/devenv"
      ".local/share/direnv"
      ".local/share/fastmcp"
      ".local/share/flatpak"
      ".local/share/gh"
      ".local/share/helix"
      ".local/share/home-manager"
      ".local/share/icons"
      ".local/share/intelli-shell"
      {
        directory = ".local/share/keyrings";
        mode = "0700";
      }
      ".local/share/nautilus"
      ".local/share/nix"
      ".local/share/nix-inspect"
      ".local/share/nushell"
      ".local/share/opencode"
      ".local/share/opentui"
      ".local/share/pki"
      ".local/share/pnpm"
      ".local/share/qalculate"
      ".local/share/sddm"
      ".local/share/starfish-workbench"
      ".local/share/steel"
      ".local/share/systemctl-tui"
      ".local/share/systemd"
      ".local/share/uv"
      # HEX's settings, models, dictation history, and IPC socket.
      {
        directory = ".local/share/voice-control";
        mode = "0700";
      }
      ".local/share/wallpapers"
      ".local/share/yazelix"
      ".local/share/zellij"
      ".local/share/zoxide"
      ".local/state/boot-postmortem"
      ".local/state/ci-mcp"
      ".local/state/claude-code"
      ".local/state/codex"
      ".local/state/codex-desktop"
      ".local/state/codex-jj-sessions"
      ".local/state/comma"
      ".local/state/deploy-reverts"
      ".local/state/fieldnotes"
      ".local/state/gh"
      ".local/state/herdr"
      ".local/state/home-manager"
      ".local/state/jev"
      ".local/state/jj-ci"
      ".local/state/marimo"
      ".local/state/niri"
      ".local/state/nix"
      ".local/state/nix-output-monitor"
      ".local/state/nixpkgs-watch"
      ".local/state/noctalia"
      ".local/state/openai-codex"
      ".local/state/opencode"
      ".local/state/pnpm"
      ".local/state/secretspec"
      ".local/state/usage-reset-alert"
      ".local/state/wireplumber"
      ".local/state/yazi"
    ];
    files = [
      ".claude.json"
      ".config/claude-oauth-token"
      ".config/mimeapps.list"
      ".config/pavucontrol.ini"
      ".local/share/recently-used.xbel"
      ".local/state/lesshst"
      # Symlinks are recreated as links into /persist, not bind-mounted.
      {
        file = ".nix-profile";
        method = "symlink";
      }
      {
        file = ".env.example";
        method = "symlink";
      }
    ];
  };
}
