# Full ZTS (wayfinder #5): disk-less run as root via the installed suite.
# The gate for now is that the harness composes end-to-end and the run
# completes with a results summary — not that the summary is green; env
# failures (NFS/samba-dependent tests, unimplemented device groups) are
# triaged post-first-contact per the map.
# Build with `nix build .#zfs-tests`, then run ./result/bin/zfs-tests-driver
# (add --interactive for a debug shell).
client.wait_for_unit("multi-user.target")

with subtest("kmod + farm ready"):
    client.succeed("lsmod | grep -qE '^zfs '")
    client.succeed("[ -x /bin/ksh ] && [ -x /sbin/mkfs.ext4 ]")

with subtest("zfs-tests.sh completes the linux-fast run on file vdevs"):
    out = client.succeed(
        "@SUITE@/scripts/zfs-tests.sh -f -d /var/tmp/zts -s 1G "
        "-r linux-fast -v 2>&1 | tail -30")
    print(out)
