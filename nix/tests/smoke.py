# Smoke config (wayfinder #5): proves the kernel tier composes — kmods from
# this tree load on the pinned kernel, the FHS farm lands, one pool does a
# full lifecycle on a file vdev, ztest runs. Runs inside `nix flake check`.
client.wait_for_unit("multi-user.target")

with subtest("kernel tier: modules from this tree are loaded"):
    client.succeed("lsmod | grep -qE '^zfs '")
    client.succeed("lsmod | grep -qE '^spl '")
    client.succeed("modinfo zfs | grep -q vermagic")

with subtest("FHS farm merged into place"):
    client.succeed(
        "for f in /bin/ksh /sbin/mkfs.ext4 /sbin/fsck.ext4 /usr/bin/awk "
        "/usr/bin/xxh128sum; do [ -x \"$f\" ] || exit 1; done")

with subtest("userspace tools work"):
    client.succeed("zfs version")
    client.succeed("zpool version")

with subtest("pool lifecycle on a file vdev"):
    client.succeed("mkdir -p /var/tmp/zts && truncate -s 1G /var/tmp/zts/vdev1")
    client.succeed(
        "zpool create -o cachefile=none -o altroot=/smoke smoke "
        "/var/tmp/zts/vdev1")
    client.succeed("zfs create smoke/fs")
    client.succeed("echo zfs-dig > /smoke/fs/file")
    client.succeed("zfs snapshot smoke/fs@snap")
    client.succeed("zpool export smoke")
    client.succeed("zpool import -o cachefile=none -d /var/tmp/zts smoke")
    client.succeed("grep -q zfs-dig /smoke/fs/file")
    client.succeed("zpool destroy smoke")

with subtest("ztest smoke"):
    client.succeed("mkdir -p /var/tmp/zts/ztest")
    client.succeed("cd /var/tmp/zts/ztest && ztest -N 5")
