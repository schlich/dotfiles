{ pkgs, ... }:

{
  programs.home-manager.enable = true;
  programs.htop.enable = true;
  programs.bat.enable = true;
  programs.fd.enable = true;
  programs.gh = {
    enable = true;
    # gh still discovers repositories through Git internally.
    package = pkgs.symlinkJoin {
      name = "gh-jj-transport";
      paths = [ pkgs.gh ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram "$out/bin/gh" --prefix PATH : ${pkgs.git}/bin
      '';
      meta.mainProgram = "gh";
    };
    gitCredentialHelper.enable = false;
    extensions = [ pkgs.gh-stack ];
  };
  programs.gh-dash.enable = true;
  programs.navi.enable = true;
  programs.password-store.enable = true;
  programs.pet.enable = true;
  programs.bun.enable = true;

  programs.nix-search-tv = {
    enable = true;
    enableTelevisionIntegration = true;
  };

  programs.tealdeer = {
    enable = true;
    settings.updates.auto_update = true;
  };

  programs.nom = {
    enable = true;
    settings.feeds = [
      {
        name = "adam-nyberg";
        url = "https://adamnyberg.se/rss.xml";
      }
      {
        name = "automerge";
        url = "https://automerge.org/index.xml";
      }
      {
        name = "ink-and-switch";
        url = "https://www.inkandswitch.com/index.xml";
      }
      {
        name = "lea-verou-phd";
        url = "https://lea.verou.me/feed.xml";
      }
      {
        name = "hacker-news";
        url = "https://news.ycombinator.com/rss";
      }
      {
        name = "nix-ci";
        url = "https://blog.nix-ci.com/rss";
      }
      {
        name = "Vicky Boykis";
        url = "https://vickiboykis.com/rss";
      }
      {
        name = "graham-dumpleton";
        url = "https://grahamdumpleton.me/feed.xml";
      }
    ];
  };
}
