# Kill the biggest offender early instead of letting memory exhaustion freeze
# the machine. On 2026-10-07 a flake-check evaluation plus a dozen agent
# sessions filled RAM and the RAM-backed zram swap; the kernel OOM killer
# fired only once swap was completely full, and the next evaluation left the
# desktop thrashing until a power cycle.
{
  systemd.oomd = {
    enable = true;
    # Kill the cgroup using the most swap once swap passes SwapUsedLimit.
    enableRootSlice = true;
    # Kill a user unit (an agent's scope, a terminal, an app) whose memory
    # pressure stays above 80% for DefaultMemoryPressureDurationSec.
    enableUserSlices = true;
    settings.OOM = {
      SwapUsedLimit = "80%";
      DefaultMemoryPressureDurationSec = "10s";
    };
  };

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
