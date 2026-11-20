// The programs the workflow-status plugin runs. modules/tooling/ai/shared/plugins.nix
// replaces this file with one naming them by store path; these bare names
// fall back to PATH when the plugin runs from a checkout.
export default {
  git: "git",
  jj: "jj",
  gh: "gh",
  xs: "xs",
  luvus: "luvus",
  xdgOpen: "xdg-open",
  wlCopy: "wl-copy",
};

/** The GitHub repository nixos-switch-main applies, for links to the commit a generation came from. */
export const switchRepository: string | undefined = undefined;
