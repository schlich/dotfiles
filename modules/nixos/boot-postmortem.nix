{ pkgs, ... }:

let
  # Servers lack the nushellWith overlay behind writeNuScriptBin.
  bootPostmortem = pkgs.writers.writeNuBin "boot-postmortem" (
    builtins.readFile ../../postmortem/boot-postmortem.nu
  );
in

{
  # When the previous boot ended without a clean shutdown, write a report
  # from its journal to /var/lib/boot-postmortem. The desktop session's
  # boot-postmortem-notify unit announces it.
  systemd.services.boot-postmortem = {
    description = "Report on a previous boot that ended without a clean shutdown";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-journal-flush.service" ];
    path = [ pkgs.systemd ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${bootPostmortem}/bin/boot-postmortem collect";
      StateDirectory = "boot-postmortem";
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };

  environment.systemPackages = [ bootPostmortem ];
}
