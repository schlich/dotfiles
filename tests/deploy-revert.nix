# The staged switch in deploy/switch.nu, end to end in a VM: a candidate
# that breaks a health check is reverted and logged, a healthy one becomes
# the boot default, the dead-man timer reverts a switch whose watch was
# killed, and the boot-time settle reverts one whose dead-man died too. Each
# specialisation stands in for a landed revision.
{ pkgs, ... }:

pkgs.testers.runNixOSTest {
  name = "deploy-revert";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ../modules/nixos/system-switch.nix ];

      services.openssh.enable = true;
      # Committing installs the boot loader; the VM boots its kernel directly.
      boot.loader.grub.enable = false;
      environment.systemPackages = [ pkgs.jq ];

      dotfiles.deploy = {
        healthChecks = [ "ssh" ];
        watch = {
          duration = 20;
          interval = 2;
          failures = 2;
          grace = 10;
        };
      };

      specialisation.healthy.configuration.environment.etc."deploy-revert-test".text = "healthy";
      # Moves sshd off the port the running system's ssh probe checks: the
      # running system judges a candidate, not the candidate itself.
      specialisation.broken.configuration.services.openssh.ports = lib.mkForce [ 2200 ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")


    def current():
        return machine.succeed("readlink -f /run/current-system").strip()


    def reverts(query):
        machine.succeed(f"deploy-reverts --json | jq --exit-status '{query}'")


    base = current()
    healthy = machine.succeed(f"readlink -f {base}/specialisation/healthy").strip()
    broken = machine.succeed(f"readlink -f {base}/specialisation/broken").strip()

    with subtest("repeated local SSH probes do not penalize the health checker"):
        for _ in range(20):
            machine.succeed("ssh-keyscan -T 3 -p 22 127.0.0.1 > /tmp/health-keys 2>/dev/null; test -s /tmp/health-keys")

    with subtest("a candidate that breaks a health check is reverted"):
        machine.fail(f"nixos-switch-main apply {broken}")
        assert current() == base, "the broken candidate is still active"
        machine.wait_for_unit("sshd.service")
        reverts('length == 1 and .[0].phase == "watch" and .[0].activated and .[0].restored')
        reverts('.[0].breached | index("ssh") != null')
        reverts('.[0].report_text | contains("## What breached")')
        machine.fail("systemctl is-active --quiet nixos-switch-main-deadman.timer")
        machine.fail("test -e /var/lib/nixos-switch-main/pending.nuon")

    with subtest("a healthy candidate becomes the boot default"):
        machine.succeed(f"nixos-switch-main apply {healthy}")
        assert current() == healthy, "the healthy candidate is not active"
        machine.succeed(f'test "$(readlink -f /nix/var/nix/profiles/system)" = {healthy}')
        machine.fail("systemctl is-active --quiet nixos-switch-main-deadman.timer")
        reverts("length == 1")
        machine.succeed(f"jq --exit-status '.outcome == \"deployed\" and .toplevel == \"{healthy}\"' /var/lib/nixos-switch-main/generations.jsonl")
        machine.succeed("generation --json --offline | jq --exit-status '.source != null and .system.generation == .system.boot_default'")

    with subtest("the dead-man timer reverts a switch whose watch died"):
        machine.succeed(f'systemd-run --unit=staged-switch --setenv=PATH="$PATH" "$(command -v nixos-switch-main)" apply {base}')
        machine.wait_until_succeeds("grep -q activated /var/lib/nixos-switch-main/pending.nuon")
        assert current() == base, "the staged candidate is not active"
        machine.succeed("systemctl kill --signal=KILL staged-switch.service")
        machine.wait_until_succeeds(f'test "$(readlink -f /run/current-system)" = {healthy}', timeout=120)
        # The symlink changes during activation, before rollback has finished
        # writing its report and clearing the pending switch.
        machine.wait_until_succeeds("test ! -e /var/lib/nixos-switch-main/pending.nuon", timeout=120)
        reverts('length == 2 and .[1].phase == "deadman" and .[1].restored')
        machine.wait_for_unit("sshd.service")

    with subtest("the boot-time settle reverts a stage whose run and dead-man both died"):
        machine.succeed(f'systemd-run --unit=staged-switch-again --setenv=PATH="$PATH" "$(command -v nixos-switch-main)" apply {base}')
        machine.wait_until_succeeds("grep -q activated /var/lib/nixos-switch-main/pending.nuon")
        machine.succeed("systemctl kill --signal=KILL staged-switch-again.service")
        # A reboot drops the transient timer; stop it as one would.
        machine.succeed("systemctl stop nixos-switch-main-deadman.timer")
        assert current() == base, "the staged candidate is not active"
        machine.succeed("nixos-switch-main settle")
        assert current() == healthy, "the settle did not return to the boot default"
        machine.fail("test -e /var/lib/nixos-switch-main/pending.nuon")
        reverts('length == 3 and .[2].phase == "boot" and .[2].restored')
        machine.wait_for_unit("sshd.service")
  '';
}
