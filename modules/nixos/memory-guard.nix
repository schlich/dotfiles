# Kill the biggest offender early instead of letting memory exhaustion freeze
# the machine. On 2026-10-07 a flake-check evaluation plus a dozen agent
# sessions filled RAM and the RAM-backed zram swap; the kernel OOM killer
# fired only once swap was completely full, and the next evaluation left the
# desktop thrashing until a power cycle.
{ config, ... }:
{
  systemd.oomd = {
    enable = true;
    # NixOS makes both of these memory-pressure kills: once pressure on the
    # whole machine, or on a user's units, stays above 80% for
    # DefaultMemoryPressureDurationSec, oomd kills the unit under the most
    # pressure (an agent's scope, a terminal, an app).
    enableRootSlice = true;
    enableUserSlices = true;
    settings.OOM = {
      SwapUsedLimit = "90%";
      DefaultMemoryPressureDurationSec = "10s";
    };
  };

  # Also kill the unit using the most swap once both RAM and swap are more
  # than SwapUsedLimit full, as Fedora does by default; NixOS's options leave
  # this out. zram swap lives in RAM, and on 2026-10-07 it filled to its last
  # 48 kB before the kernel acted. oomd picks one leaf unit, never a whole
  # session.
  systemd.slices."-".sliceConfig.ManagedOOMSwap = "kill";

  # systemd-oomd reads oomd.conf only when it starts.
  systemd.services.systemd-oomd.restartTriggers = [ config.environment.etc."systemd/oomd.conf".text ];

  # When the kernel OOM-kills one process, leave the rest of its unit
  # running. With the default `stop`, killing a single evaluation an agent
  # started tore down the whole Claude desktop app and every session in it.
  systemd.user.settings.Manager.DefaultOOMPolicy = "continue";

  # MGLRU thrashing protection: when the working set of the last second can no
  # longer stay resident, invoke the OOM killer instead of evicting it and
  # livelocking on refaults.
  systemd.tmpfiles.rules = [ "w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000" ];

  # A manual way out when the desktop still freezes: Alt+SysRq+F runs the OOM
  # killer, and R E I S U B reboots cleanly. 244 allows keyboard control (4),
  # sync (16), read-only remount (32), signalling and OOM kill (64), and
  # reboot (128), but not memory dumps or debug output.
  boot.kernel.sysctl."kernel.sysrq" = 244;
}
