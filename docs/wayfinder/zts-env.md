# ZTS-tier environment requirements (wayfinder ticket #4)

Research ticket: what running the ZFS Test Suite (`./scripts/zfs-tests.sh`,
`tests/runfiles/common.run` and their helpers) requires from an OS beyond a
build environment, contrasted with a stock NixOS host. Everything below is
cited to sources in this repository (base `origin/master` = `c18118745`) plus,
for the nixpkgs contrast, package queries against the nixpkgs 26.05 channel
and probes on a live NixOS 26.05pre host (`/proc/config.gz`,
`/run/current-system/activate`, FHS directories). Nothing was executed from
ZTS itself.

## 0. Execution pipeline (what runs what)

1. `scripts/zfs-tests.sh` sources the generated `scripts/common.sh`
   (`scripts/zfs-tests.sh:20-21`). `common.sh` is produced by configure
   (`scripts/Makefile.am:71-83`) and defines the absolute paths of `zdb/zfs/
   zpool/ztest`, `zfs.sh`, the test-runner and the suite directories
   (`scripts/common.sh.in:4-22`). In-tree the paths point at the build tree
   (`INTREE="yes"`, `scripts/Makefile.am:40`); when installed they point at
   `$(datadir)/zfs` (`scripts/Makefile.am:91-97`), i.e. `/usr/share/zfs` —
   the layout CI uses (`TDIR="/usr/share/zfs"`,
   `.github/workflows/scripts/qemu-6-tests.sh:199`).
2. It refuses to run as root and demands passwordless sudo of the invoking
   user (`scripts/zfs-tests.sh:718-724`).
3. `constrain_path()` builds a symlink farm containing *only* the allow-listed
   binaries from `tests/zfs-tests/include/commands.cfg` and then runs the
   Python test-runner with `PATH=$STF_PATH`
   (`scripts/zfs-tests.sh:413-475`, `:915-926`). Anything a helper execs
   must be on that list or the link is missing at runtime (missing entries
   are reported as `Missing util(s)` — `scripts/zfs-tests.sh:879`).
4. It loads the ZFS module stack via `sudo scripts/zfs.sh`
   (`scripts/zfs-tests.sh:744-748`), creates vdev backing (sparse files +
   loopback devices) unless `$DISKS` is set (`:786-830`), then runs
   `test-runner.py` (`tests/test-runner/bin/test-runner.py.in`,
   `#!/usr/bin/env @PYTHON_SHEBANG@` at line 1) which executes each `.ksh`
   test via `sudo -E -u <user>` (`:281-311`) and finally pipes results through
   `zts-report.py` (stdlib-only Python; `scripts/zfs-tests.sh:936`).
5. On failure (and at exit with `-K`/`-O`) the callbacks in
   `tests/zfs-tests/callbacks/` read `dmesg`, `/proc/spl/kstat/zfs/dbgmsg`,
   `/sys/module/zfs/parameters` and pool `multihost` kstats.
6. `default.cfg` (from `tests/zfs-tests/include/default.cfg.in`) defines the
   integration paths: `/etc/zfs/zed.d`, `/etc/zfs/zpool.d`,
   `/usr/share/zfs/compatibility.d` (`:28-31`), Linux device dirs
   `/dev`, `/dev/mapper`, `/dev/zvol`, `/etc/zfs/vdev_id.conf`,
   default foreign fs `ext2` (`:164-186`).

## 1. Binary inventory the helpers may exec

The authoritative list is the `constrain_path` allow-list in
`tests/zfs-tests/include/commands.cfg` — 93 OS-common, 40 Linux-only, 17 ZFS
userland binaries, 68 test-suite command binaries (built from
`tests/zfs-tests/cmd/`) plus `setlease`.

### 1.1 OS-common (commands.cfg:11-105)

`awk basename bc bunzip2 bzcat cat chgrp chmod chown cksum cmp cp cpio cut
date dd df diff dirname dmesg du echo env expr false file find fio getconf
getent getfacl grep gunzip gzip head hostname id iostat jq kill ksh ldd ln ls
mkdir mknod mkfifo mktemp mount mv net od openssl pamtester pax pgrep ping
pkill printf ps python3 readlink rm rmdir rsync scp script sed seq setfacl sh
sleep sort ssh stat strings sudo swapoff swapon sync tail tar timeout touch tr
true truncate umount uname uniq vmstat wc which xargs xxh128sum`

Non-obvious ones (with the consumer that proves the requirement):

| binary | why (file:line) |
|---|---|
| `fio` | io group (`tests/functional/io/*.ksh`), l2arc compression tests; CI installs it |
| `ksh` | every test script is `#!/bin/ksh -p` (2050 files under `tests/functional/`) |
| `jq` | JSON output tests (`cli_root/json`, `zpool_get`) |
| `net` | Samba client: `is_shared` checks `net usershare list` (`include/libtest.shlib:1361`), `zfs_unshare_006_pos.ksh` |
| `pamtester` | `tests/functional/pam/*` (setup.ksh aborts if absent) |
| `xxh128sum` | `xxh128digest` helper (`libtest.shlib:3661-3665`) used by raidz/history/gang/fault tests |
| `swapoff/swapon` | `zvol_swap` (`tests/functional/zvol/zvol_swap/zvol_swap.cfg` calls `swapon -s`; cleanup re-enables via `swapon -a`) |
| `openssl` | crypto tests |
| `getfacl/setfacl` | POSIX ACL tests (acl on/off groups) |
| `iostat/vmstat/mpstat` | scrub/resilver monitoring helpers (`expect_iostat`, `delay_iostat`, used ~21/17×) |
| `pax` | archive tests (cp_files/mv_files use `pax` options from default.cfg.in:166-170) |
| `scp/ssh/rsync/ping` | NFS/remote helpers (`setup_nfs_server`, sanity of NFS env) |
| `script` | `cli_root/zfs_upgrade/setup.ksh` (pseudo-tty) |
| `mknod/mkfifo/hostid` | device nodes, `/etc/hostid` tests (`cli_root/zpool`, `zgenhostid`) |
| `logger` | syslog event tests |
| `getent` | user/group checks in helpers |
| `dmesg` | failure callback (`callbacks/zfs_dmesg.ksh` runs `sudo dmesg -c --time-format=iso`) |
| `bash` | not on the list but needed: runner timeout debug runs `sudo bash -c` (`test-runner.py.in:232`); NixOS has it via /run/current-system/sw/bin but see §4.5 for the sudo PATH nuance |

### 1.2 Linux-only (commands.cfg:128-166)

`attr blkid blkdiscard blockdev capsh chattr cryptsetup exportfs fallocate
flock free getfattr groupadd groupdel groupmod hostid logger losetup lsattr
lsblk lscpu lsmod lsscsi mkfs.xfs mkswap modprobe mountpoint mpstat nsenter
parted perf setfattr setpriv udevadm unshare useradd userdel usermod wipefs`

Proven consumers (representative):

- `losetup` — vdev loopback creation, `scripts/zfs-tests.sh:806-823` (Linux
  default `LOSETUP=/sbin/losetup`, `:56`; overridable via env).
- `dmsetup` — loop/dm cleanup, `scripts/zfs-tests.sh:57,87-103,157-159`
  (default `/sbin/dmsetup`).
- `udevadm trigger/settle` — `block_device_wait()`
  (`include/blkdev.shlib:72-105`); `udevadm info` for persistent names and
  partition UUIDs (`blkdev.shlib:286-304`,
  `tests/functional/fault/auto_replace_001_pos.ksh:63-124`).
- `modprobe/rmmod/lsmod` — `load_scsi_debug()`/`unload_scsi_debug()`
  (`blkdev.shlib:409-460`) used by fault/online_offline/removal/spare tests;
  `zfs.sh` itself loads the module stack with `LDMOD=/sbin/modprobe` default
  (`scripts/zfs.sh:20-21`).
- `lsscsi` — device presence/offline checks (`blkdev.shlib:328-376,466-478`).
- `lsblk` — device-type classification (`blkdev.shlib:140-158,178-184`).
- `useradd/groupadd/usermod/userdel/groupdel/groupmod` — every test that
  creates users/groups (`libtest.shlib:2398-2489`): delegate, userquota,
  projectquota, zoned_uid, pam, cli_user.
- `exportfs` (+ `showmount`, `pgrep mountd`) — NFS sharing tests
  (`libtest.shlib:1222,1458-1514`); tests expect the NFS server already
  running and `/etc/exports.d/zfs.exports` to be the share file
  (`libtest.shlib:1312`).
- `cryptsetup` — `tests/functional/luks/luks_sanity.ksh:52-55` (dm-crypt
  on a file vdev, expects `/dev/mapper/luksdev`).
- `unshare` (`-U` user namespaces) — `tests/functional/user_namespace/user_namespace_001.ksh:41`
  (`unshare -Urm`), zoned_uid group; `setpriv`/`nsenter` in the same areas.
- `perf` — `tests/functional/arc/arcstats_runtime_tuning.ksh` (perf record).
- `parted/wipefs/blkid/blkdiscard/blockdev/fallocate/flock` — partitioning,
  expand, trim, direct-io groups; `chattr/getfattr/setfattr/attr/lsattr` —
  xattr groups; `mkfs.xfs`/`mkswap` — vdev-file and swap tests;
  `mpstat`/`iostat`/`vmstat` — perf-sampling helpers; `mountpoint` — mount
  tests; `lscpu`/`free` — capability probes; `capsh` — privilege tests;
  `logger`, `hostid` as above.

### 1.3 ZFS userland + suite-built binaries

`zdb zfs zhack zinject zpool ztest raidz_test zarcsummary zarcstat zilstat
dbufstat mount.zfs zed zgenhostid zstream zfs_ids_to_path zpool_influxdb`
(commands.cfg:168-184) are linked from the package-installed sbin (`$SBIN_DIR`,
i.e. `/usr/sbin` on FHS distros) or the build tree. ~69 small C helpers from
`tests/zfs-tests/cmd/` (file_check, mmap_libaio, user_ns_exec, xattrtest,
crypto_test, blake3/edonr/skein/sha2 tests, stride_dd, zed_fd_spill-zedlet, …)
are installed under `$STF_SUITE/bin` (commands.cfg:186-257).

Also hard-wired outside the allow-list:

- `/sbin/fsck.ext4` → `fsck` and `/sbin/mkfs.ext4` → `newfs`, unconditionally
  on Linux (`scripts/zfs-tests.sh:468-469`) — `NEWFS_DEFAULT_FS=ext2`
  (default.cfg.in:184) makes e2fsprogs mandatory for foreign-fs vdev tests.
- `gzip`→`compress`, `gunzip`→`uncompress` aliases (`scripts/zfs-tests.sh:470-471`).
- `setenforce` if present (`scripts/zfs-tests.sh:844-846`).
- Python modules: `libzfs_core` + `nvlist` (`ctypes`) for
  `tests/functional/pyzfs/pyzfs_unittest.ksh.in:40-43` (built by the tree,
  needs the configured `@PYTHON@` and `ldd`, line 21).

## 2. OS/kernel interface requirements

| interface | used by |
|---|---|
| ZFS module stack loaded (provides `/proc/spl/kstat`, `/sys/module/zfs`, `/dev/zfs`) | everything; stack load via `scripts/zfs.sh` (`zfs-tests.sh:744-748`); `zfs.sh:169` checks `/sys/module/<name>` |
| `/proc/spl/kstat/zfs/{dbgmsg,arcstats,dbufs,*}` + `/proc/spl/kstat` generally | `callbacks/zfs_dbgmsg.ksh`, `zfs-tests.sh:851-854`, arc/dbufstat/zarcstat tests, `include/kstat.shlib` |
| `/proc/spl/kstat/zfs/<pool>/multihost`, `/sys/module/zfs/parameters/zfs_multihost_history` | `callbacks/zfs_mmp.ksh` |
| `/sys/module/zfs/parameters/*` (incl. `zfs_dbgmsg_enable`, `zfs_txg_history`, `zfs_fletcher_4_impl`), `/sys/module/zfs/properties.*`, `features.*` | `zfs-tests.sh:851`, tunables.cfg, `features`/`tunables` tests (13+ hits) |
| `/sys/block/<disk>/{device/state,device/delete,device,slaves}` and `/sys/class/scsi_host/host*/scan` | disk offline/online + rescan (`blkdev.shlib:43-53,322-356`) |
| `scsi_debug` module (`modprobe scsi_debug`, `lsscsi`) | fault/auto_replace_*, online_offline, removal — upstream CI had to switch Alpine to a kernel with `CONFIG_SCSI_DEBUG` because "-virt lacks it, several ZTS tests need it" (`qemu-3-deps-vm.sh:39-45`) |
| loop block device + `/sys/module/loop/parameters/max_part` | loop vdevs (`losetup`), and `is_physical_device()` on Linux *requires that sysfs file to exist* (`blkdev.shlib:115-118`) → loop module must be loaded before partitioning tests |
| `/dev/loop-control` auto-creation of `/dev/loopN` | losetup `--show -f` (`zfs-tests.sh:818`) |
| udev/udevadm (settle, trigger, `info`) | `block_device_wait`, persistent-disk-name, auto_replace tests; also `udevadm settle` timeout expectations (`blkdev.shlib:69-80`) |
| ZFS udev rules installed and helpers executable: `/dev/zvol/...` symlinks via `60-zvol.rules` (`PROGRAM=="@udevdir@/zvol_id"`, `udev/rules.d/60-zvol.rules.in:11`), `69-vdev.rules` (vdev_id), `90-zfs.rules` (`RUN+="/sbin/modprobe zfs"`, line 4-5) | zvol groups (`ZVOL_DEVDIR=/dev/zvol`, default.cfg.in:172-173), fault/auto_replace (`/etc/zfs/vdev_id.conf`, `VDEVID_CONF_ETC` default.cfg.in:182), import tests |
| `/dev/disk/by-id` (systemd-udev default symlinks) | vdev_disk:Linux group, `get_persistent_disk_name` (`blkdev.shlib:292`), /dev/disk/by-id usage in 12 sites |
| `/dev/mapper` dm-crypt | luks group |
| `/proc/self/uid_map`, user namespaces (`unshare -U`) | user_namespace, zoned_uid:Linux groups (`zoned_uid/setup.ksh:27-29`) |
| `/dev/kmsg` writable | `-K` (log test names, `test-runner.py.in:359-365`) and `-O` timeout debug (`:204,236-244`) |
| `/proc/sysrq-trigger` | timeout debug stack dump (`test-runner.py.in:243-244`) |
| `/proc/slabinfo` (kmemleak presence check), `/sys/kernel/debug/kmemleak` + `CONFIG_DEBUG_KMEMLEAK` | `-m` option (`libtest.shlib:166-176`, `test-runner.py.in:45,381-404`) |
| debugfs `/sys/kernel/debug/tracing/stack_max_size`, `/proc/sys/kernel/stack_tracer_enabled` | `-S` stack tracer (`scripts/zfs.sh:178-189`) |
| `/proc/sys/vm/dirty_*`, `/proc/sys/kernel/core_pattern`, `/proc/mounts`, `/proc/filesystems`, `/proc/cpuinfo`, `/proc/cmdline` (mitigations check) | cache/scrub tuning, crash-dump helpers, exec/lease tests (`libtest.shlib:176,4077-4103`, misc) |
| `/boot/config-$(uname -r)` containing `CONFIG_IO_URING=y` | `tests/functional/io/io_uring.ksh:34`, `tests/functional/direct/dio_async_fio_ioengines.ksh` (skip path: grep failure → log_unsupported) |
| NFS server running (mountd/reexport), `/etc/exports.d/zfs.exports` | `setup_nfs_server` (`libtest.shlib:1491-1514`): "NFS server must be started prior to running ZTS" |
| Samba usershares (`/var/lib/samba/usershares`, `net`) | `zfs_unshare_006_pos.ksh:35` (skips if dir absent), `is_shared` (libtest.shlib:1361) |
| `/etc/pam.d` writable + PAM module path `@pammoduledir@/pam_zfs_key.so` | pam group (`tests/functional/pam/utilities.kshlib.in:17-36`) |
| `/etc/zfs/{zed.d,zpool.d,vdev_id.conf}` + zed daemon binary | zed_setup (`libtest.shlib:3274-3357`), events/linux groups; zpool.d scripts + `zfs_prepare_disk` (installed `/usr/libexec/zfs`, `$LIBEXEC_DIR` on the search path, `zfs-tests.sh:419-420`) |
| mount/umount of zfs + foreign fs (ext2 via `newfs`, xfs via `mkfs.xfs`) as root | cache/l2arc/log tests format file-vdevs |
| `/var/run` (ZED pid file default `/var/run/zed.pid`, `scripts/zfs.sh:19`), runstatedir for pam tests | zed/kill_zed, pam |
| `sudo` | see §3 |
| SELinux present or absent; `setenforce permissive` when present | `zfs-tests.sh:844-846` |

Device/mount expectations (default no-`$DISKS` path):

- 3 sparse vdev files `$FILEDIR/file-vdev{0,1,2}`, default size 4 GiB each
  (`zfs-tests.sh:33,36,623,797-800`); at least 3 block devices (or files) for
  functional tags (`:836-838`).
- Loopback devices layered on the files unless `-f`
  (`:806-829`; `-f` runs purely on files).
- `$FILEDIR` default `/var/tmp`, world-writable-capable, and `TMPDIR`
  redirected there (`:36,860`); hard requirement for `/var/tmp/test_results`
  as runner output dir (`test-runner.py.in:43`).
- Pools named `testpool*` are destroyed; pre-existing pools are kept and
  excluded via `__ZFS_POOL_EXCLUDE` (`:760-778`) — any host pool (including a
  host root pool!) is tolerated but hidden from iteration.
- CI reference layout: a *dedicated* 64 GiB virtio disk, mkfs.xfs, mounted
  `noatime` at `/var/tmp` mode 1777 per test VM, 2 VMs × 2 vCPU × 8 GiB RAM,
  `-s 3GB` vdev files, tags split `NUM/DEN` across the two VMs
  (`qemu-5-setup.sh:47-100`, `qemu-6-tests.sh:184-257`).

## 3. Privilege model

- The launcher must run as a **non-root user with passwordless sudo**
  (`zfs-tests.sh:718-724`: refuses uid 0; requires `sudo id -un` = root).
- Every `Cmd` runs through `sudo -E -u <user> [env TMPDIR=...] <cmd>`
  (`test-runner.py.in:302-311`); `<user>` comes from the runfile. common.run's
  `[DEFAULT]` sets `pre_user = user = post_user = failsafe_user = root`
  (`tests/runfiles/common.run:22-30`) — i.e. the suite is designed for a root
  test environment. `cli_user` groups set `user =` (empty) and thus run
  unprivileged as the launching user (`:650-694`). `verify_user()` checks
  passwordless `sudo -n -u <user> true` per runfile user before running
  (`test-runner.py.in:1070-1096`).
- Tests themselves create/delete users and groups at run time
  (`useradd`, `libtest.shlib:2398-2489`) and manage swap, mounts, loop/dm
  devices, udev triggers — all root-only operations issued via `sudo` (which
  is on the allow-list, commands.cfg:87).
- `-E` matters: the constrained `PATH=$STF_PATH` and `TMPDIR` must survive
  sudo (the runner explicitly rebuilds TMPDIR because glibc drops it across
  setuid, `test-runner.py.in:302-308`). On hosts whose sudoers forces
  `secure_path`, the constrained PATH is replaced — must be checked on
  NixOS targets (nixpkgs 26.05's `nixos/modules/security/sudo.nix` generates
  the file itself; verify the resulting defaults on the test VM).
- The runner kills timed-out tests with `sudo kill` (`:254-262`).

## 4. NixOS gap list

Probe host facts (NixOS 26.05pre, stock FHS treatment): the activation script
only materializes `/bin/sh` and `/usr/bin/env`
(`/run/current-system/activate` lines 23-28, 144-147); `/sbin`, `/usr/sbin`,
`/usr/local/bin` do not exist (`ls -ld` — this host). All system binaries live
in `/run/current-system/sw/bin` (1800 entries here). Kernel config via
`/proc/config.gz`: `CONFIG_SCSI_DEBUG=m`, `CONFIG_IO_URING=y`,
`CONFIG_BLK_DEV_LOOP=m` (MIN_COUNT=8), ZLIB in/out `=y`,
`# CONFIG_DEBUG_KMEMLEAK is not set`. The ZFS module stack itself is
comfortably at home: `/proc/spl/kstat/zfs/*` and 368 `/sys/module/zfs/parameters`
are present on the running host, and the package inventory below shows every
needed binary exists in nixpkgs. The gap is *layout/discoverability*, not
availability.

| # | ZTS expectation | NixOS reality | severity / mitigation |
|---|---|---|---|
| 4.1 | `constrain_path` scans only `/usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin` (+ `$LIBEXEC_DIR`) (`zfs-tests.sh:419-420`) to build the allow-list | stock NixOS: `/bin` holds only `sh`, `/usr/bin` only `env`, others absent → **every** allow-listed system tool is reported missing; tests would run with an empty PATH | **blocker.** Mitigation: symlink-farm (e.g. systemd tmpfiles/activation) that populates `/usr/bin`+`/sbin` from `systemPackages`, or run ZTS inside an FHS container (`nixos-container`, `buildFHSUserEnv` variant with the §1 list) on the NixOS kernel |
| 4.2 | every test script is `#!/bin/ksh` — the kernel resolves shebangs by absolute path, PATH is irrelevant (`tests/functional/**` 2050 hits); FreeBSD explicitly symlinks `/bin/ksh` but the Linux path does not (`zfs-tests.sh:734-737`) | no `/bin/ksh` in stock NixOS (ksh is at `/run/current-system/sw/bin/ksh`) | **blocker.** One-time `ln -s` of ksh into `/bin` (tmpfiles rule) after 4.1 anyway |
| 4.3 | hard-coded `/sbin/fsck.ext4`, `/sbin/mkfs.ext4` (`zfs-tests.sh:468-469`) | e2fsprogs provides them but at `…/bin` (verified: nixpkgs e2fsprogs output has bin/+sbin/ trees, binaries in `bin`); `/sbin` absent | **high.** Same farm as 4.1; only overridable by patching |
| 4.4 | `/sbin/losetup`, `/sbin/dmsetup`, `/sbin/modprobe` (`zfs.sh:20-21`) defaults | `/sbin` missing; binaries in sw/bin | **medium:** `LOSETUP`/`DMSETUP`/`LDMOD` env overrides exist (`zfs-tests.sh:56-57`) |
| 4.5 | `xxh128sum` binary name (`commands.cfg:105`, `libtest.shlib:3656-3660`) | nixpkgs `xxhash` ships only `xxhsum` (verified `$out/bin`: single entry); Debian/RHEL ship the `xxh128sum` alias | **medium.** Add a wrapper symlink; without it raidz/history/gang/fault tests fail |
| 4.6 | udev rules with `PROGRAM=="@udevdir@/zvol_id"` and `RUN+="/sbin/modprobe zfs"` (`udev/rules.d/*.in`) | NixOS installs the zfs rules (probe host has `/etc/udev/rules.d/60-zvol.rules`) — zvol symlinks work today; systemd-udevd is running. But `90-zfs.rules` modprobe path and rule helper paths need NixOS's store paths (done by the nixpkgs zfs package) | **low** when using the distro-packaged rules; **high** when rules from `make install` are dropped unpatched |
| 4.7 | NFS server + `exportfs`/`showmount` + `/etc/exports.d/zfs.exports`; samba with usershares enabled (`libtest.shlib:1222,1312,1361`; `qemu-6-tests` enables both services) | available (nfs-utils 3.1.1, samba 4.23.10 verified); `services.nfs-server.enable` + `services.samba` config needed; `/etc` is generated — tests write runtime files there (`/etc/pam.d`, vdev_id.conf), which works because NixOS `/etc` is writable | **medium** (config work, not availability) |
| 4.8 | `/boot/config-$(uname -r)` readable for io_uring checks (`io/io_uring.ksh:34`, `direct/dio_async_fio_ioengines.ksh`) | NixOS has no `/boot/config-*` (config in the store; this host exposed `zcat /proc/config.gz` only) → those tests *skip* (`log_unsupported`) | **low** — skip, not fail; can be satisfied with an /etc-style symlink |
| 4.9 | `sudo -E` preserving the constrained PATH (`test-runner.py.in:302-311`); non-root passwordless sudoer | NixOS sudo is package-managed; env/secure_path handling depends on the generated sudoers — must be validated | **medium** — validate on target; add `SETENV`/`env_keep` |
| 4.10 | `kmemleak` (`-m`) | nixpkgs kernels: `# CONFIG_DEBUG_KMEMLEAK is not set` (verified via /proc/config.gz) | **low** — optional feature unavailable |
| 4.11 | SELinux/`setenforce`, `sysctl kernel.io_uring_disabled` | not present/enabled on NixOS kernels; guarded (`command -v setenforce`) or mainline default (io_uring on) | **none** |
| 4.12 | FHS install layout: `$datadir/zfs` (`test-runner.py.in:44`), zed dirs under `/etc/zfs` (default.cfg.in:28-31), `/usr/libexec/zfs`, `--prefix=/usr` in CI | `make install` into a live `/usr` conflicts with NixOS (usr=store tree; only `/usr/{bin,local}` scratch dirs exist); the sane route is packaging (nixpkgs zfs already builds the same sources; module matches the NixOS kernel) | **medium** — packaging decision, not an OS gap |
| 4.13 | ksh quality: CI builds ksh 1.0 from source on Alpine because packaged ksh was unsuitable (`qemu-3-deps-vm.sh:47-54`); nixpkgs `ksh` is ast/att 2020.0.0 (ksh93u+ lineage) | old-ish ksh93; ZTS targets modern ksh93u+vm/mksh-era features (`typeset -A` is used, e.g. `zfs-tests.sh:210+` bash and associative arrays in helpers) | **medium** — validate ksh93u+m vs ast ksh with the suite on the VM route |
| 4.14 | `perf` outside `/usr` (`commands.cfg:158`) | nixpkgs has `perf` (verified, and installed on the probe host at sw/bin) — covered by 4.1 farm | folded into 4.1 |
| 4.15 | package availability | every allow-listed tool maps to a nixpkgs 26.05 package (verified via search.nixos.org for: ksh fio pamtester xxhash pax bc parted sysstat e2fsprogs xfsprogs samba lsscsi nfs-utils cryptsetup shadow acl attr libaio util-linux(→hostid, verified on host) perf iputils) | **none** — availability itself is not the problem |

Kernel-side summary: the nixpkgs x86_64 kernel as shipped in 26.05 satisfies
the scsi_debug, loop (≥8 units, `loop-control`), io_uring, zlib, and
xxhash needs (verified from `/proc/config.gz` on the probe host); the
partitioning-related `is_physical_device` gate clears once loop is loaded.
The ZFS kmod itself is already proven on this kernel (running here).

## 5. Upstream CI as the reference environment

`.github/workflows/zfs-qemu.yml`: matrix over 13 Linux distros (AlmaLinux 8-10,
CentOS Stream 9/10, Debian 12-13, Fedora 43/44, Ubuntu 22/24/26, Alpine 3.24,
archlinux, tumbleweed) + FreeBSD 14-16, in QEMU/KVM VMs on `ubuntu-24.04`
runners; PR CI splits tags across 2 VMs (`-T N/M`, `zfs-tests.sh:269-380`
`split_tags`). Quick CI type runs `sanity.run` only (`zfs-qemu.yml:59-61`,
`qemu-6-tests.sh:181-183`).

- Dependencies per distro (`qemu-3-deps-vm.sh`): e.g. RHEL family installs
  `acl attr bc cryptsetup fio jq ksh lsscsi nfs-utils pamtester parted perf
  python3(+cffi,setuptools,packaging) rsync samba strace sysstat systemd
  util-linux xxhash xfsprogs` (`:131-146`); Debian list `:84-96`; Alpine list
  `:23-32` incl. explicit kernel switch for `CONFIG_SCSI_DEBUG` (`:39-45`)
  and ksh-from-source (`:47-54`).
- Services: NFS server and Samba enabled, usershares unlocked on Ubuntu 26
  (`:276-326`).
- Kernel cmdline: `selinux=0`, serial console, `random.trust_cpu=on`;
  Alpine additionally `kmemleak=on mitigations=off` (`:329-381`).
- Test machines: cloud-init users `root` + `zfs`, both
  `ALL=(ALL) NOPASSWD:ALL` (`qemu-5-setup.sh:55-81`); 8 GiB RAM, 2 vCPU;
  each VM gets a second 64 GiB ZFS **zvol** presented as `/dev/vdb`,
  `mkfs.xfs`'d, mounted `noatime` on `/var/tmp` (1777) — i.e. the whole
  suite runs its file vdevs and `test_results` on a real XFS-backed disk
  (`qemu-6-tests.sh:197-218`). EL9/10 additionally get
  `kernel.io_uring_disabled=0` (`:221-225`).
- Invocation: as user `zfs`, `cd /var/tmp && /usr/share/zfs/zfs-tests.sh -vKO
  [$KMEMLEAK] -s 3GB -T N/DEN` (`:248-257`); ZTS loads the freshly installed
  module stack itself via `sudo zfs.sh` / `modprobe zfs`.
- PATH nuance worth copying: the CI script manually re-adds
  `/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/{s,}bin` before sudo strips it
  (`:185`) — further evidence that ZTS hard-assumes an FHS bin layout.

## 6. Conclusion (viability)

The nixpkgs-VM route is credible: kernel requirements are met by the stock
nixpkgs kernel, and every required binary is packaged. The work is
FHS-shimming: (1) an activation-time symlink farm for the §1 allow-list under
`/usr/bin` + `/sbin` (including `/bin/ksh` and the two `mkfs.ext4` aliases —
this single step clears 4.1, 4.2, 4.3, 4.14), (2) the `xxh128sum` alias
(4.5), (3) enabling nfs-server + samba usershares and the zfs rules already
shipped by nixpkgs (4.6, 4.7), (4) validating `sudo -E`/PATH semantics in the
generated sudoers (4.9). Expected skips: kmemleak (`-m`), `/boot/config-*`
io_uring probes (4.8, 4.10). Everything else is parity with the distros CI
already tests; note CI itself *only ever runs ZTS on FHS distros*, so this
would be genuinely new territory for the project.
