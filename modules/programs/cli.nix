{
  config,
  lib,
  pkgs,
  ...
}:

let
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  ghostty = config.programs.ghostty;

  # bat reads syntaxes from a cache it builds; build it here so bat needs no
  # config directory or activation step. Ghostty's syntax replaces the
  # Home Manager ghostty module's installBatSyntax.
  batSource = pkgs.linkFarm "bat-source" (
    lib.optional (ghostty.enable && ghostty.package != null) {
      name = "syntaxes/ghostty.sublime-syntax";
      path = "${ghostty.package}/share/bat/syntaxes/ghostty.sublime-syntax";
    }
  );
  batCache = pkgs.runCommandLocal "bat-cache" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out"
    cd ${pkgs.emptyDirectory}
    ${lib.getExe pkgs.bat} cache --build --source ${batSource} --target "$out"
  '';
  batConfig = pkgs.writeText "bat-config" (
    lib.optionalString ghostty.enable ''
      --map-syntax='**/ghostty/config:Ghostty Config'
    ''
  );
  bat = wrapWithConfig {
    package = pkgs.bat;
    env = {
      BAT_CONFIG_PATH = "${batConfig}";
      BAT_CACHE_PATH = "${batCache}";
    };
  };

  pet = wrapWithConfig {
    package = pkgs.pet;
    flags = [
      "--config"
      ((pkgs.formats.toml { }).generate "pet-config.toml" {
        General = {
          selectcmd = lib.getExe pkgs.fzf;
          # Snippets are user data that `pet new` writes.
          snippetfile = "${config.xdg.configHome}/pet/snippet.toml";
        };
      })
    ];
  };

  tealdeer = wrapWithConfig {
    package = pkgs.tealdeer;
    env.TEALDEER_CONFIG_DIR = "${pkgs.linkFarm "tealdeer-config" [
      {
        name = "config.toml";
        path = (pkgs.formats.toml { }).generate "tealdeer-config.toml" {
          updates.auto_update = true;
        };
      }
    ]}";
  };

  newsboatFeeds = [
    {
      title = "adam-nyberg";
      url = "https://adamnyberg.se/rss.xml";
    }
    {
      title = "automerge";
      url = "https://automerge.org/index.xml";
    }
    {
      title = "ink-and-switch";
      url = "https://www.inkandswitch.com/index.xml";
    }
    {
      title = "lea-verou-phd";
      url = "https://lea.verou.me/feed.xml";
    }
    {
      title = "hacker-news";
      url = "https://news.ycombinator.com/rss";
    }
    {
      title = "nix-ci";
      url = "https://blog.nix-ci.com/rss";
    }
    {
      title = "Vicky Boykis";
      url = "https://vickiboykis.com/rss";
    }
    {
      title = "graham-dumpleton";
      url = "https://grahamdumpleton.me/feed.xml";
    }
  ];
  # The cache and read state stay in ~/.local/share/newsboat.
  newsboat = wrapWithConfig {
    package = pkgs.newsboat;
    flags = [
      "--config-file=${pkgs.writeText "newsboat-config" ''
        max-items 0
        browser google-chrome
        reload-threads 5
        auto-reload yes
        reload-time 30
        prepopulate-query-feeds yes
      ''}"
      "--url-file=${
        pkgs.writeText "newsboat-urls" (
          lib.concatMapStrings (feed: ''
            ${feed.url} "~${feed.title}"
          '') newsboatFeeds
        )
      }"
    ];
  };
in

{
  programs.home-manager.enable = true;
  programs.htop.enable = true;
  programs.fd.enable = true;
  programs.gh = {
    enable = true;
    # gh still discovers repositories through Git internally, with the
    # wrapped git's configuration from modules/programs/vcs.nix.
    package = pkgs.symlinkJoin {
      name = "gh-jj-transport";
      paths = [ pkgs.gh ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram "$out/bin/gh" --prefix PATH : ${config.programs.git.package}/bin
      '';
      meta.mainProgram = "gh";
    };
    gitCredentialHelper.enable = false;
    # gh-dash runs with its built-in defaults; Home Manager's gh-dash module
    # would link an empty config.yml.
    extensions = [
      pkgs.gh-stack
      pkgs.gh-dash
    ];
  };
  programs.navi.enable = true;
  programs.password-store.enable = true;
  programs.bun.enable = true;

  programs.nix-search-tv = {
    enable = true;
    enableTelevisionIntegration = true;
  };

  # Keeps the tldr-update timer; the wrapper carries the settings.
  programs.tealdeer = {
    enable = true;
    package = tealdeer;
  };

  home.packages = [
    bat
    pet
    newsboat
  ];

  dotfiles.retiredHomeFiles = [
    ".config/bat/config"
    ".config/bat/syntaxes/ghostty.sublime-syntax"
    ".config/gh-dash/config.yml"
    ".config/pet/config.toml"
    ".config/tealdeer/config.toml"
    ".config/newsboat/config"
    ".config/newsboat/urls"
  ];
}
