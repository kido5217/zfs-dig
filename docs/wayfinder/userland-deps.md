# Wayfinder #3 — Userland-tier dev-shell dependencies (nixpkgs 26.05)

Tree: this checkout, OpenZFS `2.4.99` (`META:4`, branch off `master`).
Scope: `autogen.sh` + `configure` + `make`, `make check` / `make unit`,
`ztest`, `zloop.sh` on Linux. Cross-checked against the nixpkgs 26.05
expression `pkgs/os-specific/linux/zfs/generic.nix` (v2.4.4, rendered from
`nixos-26.05` on 2026-10-18); every nixpkgs attribute name below was
verified against the live 26.05 search index (search.nixos.org via the
nixos MCP). All file:line references point into this tree.

There is no kernel-module content in this tier: with
`--with-config=user` (`config/zfs-build.m4:343-354`) the `module/`
build, kernel headers and their deps are skipped entirely.

## 1. Hard requirements (autogen → configure → make → make unit must pass)

nixpkgs attributes:

    autoconf automake libtool gnumake m4 pkg-config
    perl git gnutar gawk gnused gnugrep coreutils findutils diffutils
    zlib libuuid libtirpc openssl
    stdenv.cc   # gcc + binutils (as/ld; libtool also probes objdump — see §4.2)

`libuuid` in 26.05 resolves to `util-linux-minimal`, which also ships the
libblkid development files — that is why the nixpkgs expression lists only
`libuuid` and no separate blkid input (no top-level `blkid` attr exists in
the 26.05 index; verified via `nix info`). nixpkgs builds this set with
`autoreconfHook269` + `pkg-config`; `nukeReferences` and `udevCheckHook`
are Nix-harness plumbing, not dev-shell needs. `attr`, `pam`, `curl`,
`python3`, `systemd` appear in nixpkgs' userspace `buildInputs`
(`generic.nix` "Userspace dependencies" arg set) but every one of them is
optional for this tree's configure — see §2/§3.

## 2. Tier-optional: configure silently enables/disables on presence

| nixpkgs attr | effect when present / absent |
|---|---|
| `curl` | `curl-config` gates libcurl libfetch (`config/user-libfetch.m4:42-59`); absent ⇒ no HTTPS key URLs, **no error** |
| `pam` | `security/pam_modules.h` gates `pam_zfs_key` (`config/user-pam.m4:20-31`); `--enable-pam` makes it hard |
| `systemd` | `systemctl` probe (`config/user-systemd.m4:29-33`) auto-toggles all unit/preset/generator install + `zfs-mount-generator`; libudev probe (`config/user-libudev.m4:6`) toggles `WANT_DEVNAME2DEVID` |
| `libaio` | builds `mmap_libaio` ZTS helper (`config/user-libaio.m4:6`, `config/zfs-build.m4:369`) |
| `libunwind` | better ASSERT backtraces (`config/user-libunwind.m4:15-59`) |
| `attr` | not linked anywhere in the build (no `-lattr`); its `getfattr`/`setfacl` binaries are ZTS *runtime* needs (§4) |
| `python3` | soft (`config/always-python.m4:16`, falls back to `:`); without it pyzfs and `zarcstat`/`dbufstat`/`zilstat`/`zarcsummary` are silently dropped (`cmd/Makefile.am:98`, `config/always-pyzfs.m4:41-46`); the ZTS runner is *installed unconditionally* (`tests/Makefile.am:14-17`, `PYTHON_SHEBANG` hardcoded `python3` at `config/always-python.m4:42`) and fails at runtime instead (§4.9) |
| pyzfs extras | `packaging` or `distlib`, `setuptools`, `cffi`, python dev headers (`config/always-pyzfs.m4:63-118`) ⇒ `python3`, `python3Packages.setuptools`, `python3Packages.cffi`, `python3Packages.packaging` |
| `linux-headers` | `user-libblkid.m4:7-9`/`user-statx.m4` etc. read glibc/kernel headers — satisfied by stdenv, listed for completeness |

## 3. Justification table — who invokes what

| Tool | Invoked by (file:line) | When |
|---|---|---|
| `autoreconf`,`autoconf`,`automake`,`libtool`,`m4` | `autogen.sh:4`; `configure.ac:33` (`AM_INIT_AUTOMAKE`), `:39` (`LT_INIT`) | autogen. `-i` is required and works because no aux scripts are committed under `config/` (dir listing) |
| `awk` | `configure.ac:23-24` (`AC_INIT` `m4_esyscmd(awk … META)`); `config/zfs-meta.m4:46` | autoreconf **and** configure — hard at both |
| `gnutar` (pax) | `configure.ac:33` (`tar-pax`), `:48` (`_AM_PROG_TAR(pax)`) | configure check; dist |
| `pkg-config` | `configure.ac:43` (`PKG_PROG_PKG_CONFIG`); `config/find_system_library.m4:17` | configure — every `ZFS_AC_FIND_SYSTEM_LIBRARY` prefers `.pc` lookup |
| `gnused` | `config/always-sed.m4:6-14` (must support `--in-place`, else **configure error**); `config/Substfiles.am:35`; `scripts/Makefile.am:74-79`; `man/Makefile.am:164` | configure + every `.in` subst during `make` |
| `gnugrep` | `config/Substfiles.am:36` (`grep -E` guard on undefined `@substitutions@`); root `Makefile.am:73` `$(GREP)` | `make` |
| `coreutils`, `findutils`, `diffutils` | `config/Substfiles.am` (`mkdir/rm/mv/chmod`); `scripts/make_gitrev.sh:72` (`cmp`); root `Makefile.am:134,150` (`find`) | `make` |
| `zlib` | `config/user-zlib.m4:6-8` — `AC_MSG_FAILURE` | configure, required |
| `libuuid` + libblkid | `config/user-libuuid.m4:6-8`, `config/user-libblkid.m4:7-9` — both `AC_MSG_FAILURE` on Linux (`config/user.m4:15-23`) | configure, required |
| `libtirpc` | `config/user-libtirpc.m4:22-30` — required unless libc supplies XDR; modern glibc does not, and nixpkgs forces `--with-tirpc=1` (`generic.nix` configureFlags) | configure, required |
| `openssl` | `config/user-libcrypto.m4:6-8` — `AC_MSG_FAILURE` (PBKDF2 for userspace `zfs load-key`) | configure, required |
| `gcc`/clang + binutils | `configure.ac:41` `AC_PROG_CC`, `:46` `AX_PTHREAD`, `:44` `AM_PROG_AS`; SIMD/CFI link probes (`config/always-compiler-options.m4`, `toolchain-*.m4`) | configure + make |
| `perl` | root `Makefile.am:130,125` → `scripts/cstyle.pl`, `scripts/spdxcheck.pl`; `tests/unit/Makefile.am:178` → `scripts/coverage_report.pl` | `make checkstyle`, `unit-coverage` — **not probed by configure** |
| `git` | root `Makefile.am:119,159`; `scripts/commitcheck.sh`; `scripts/make_gitrev.sh:49-50`; `config/zfs-meta.m4:74-89` | build + checkstyle; degrades silently when missing (§4.3) |
| `objdump` | probed by libtool under `LT_INIT` (`AC_CHECK_TOOL`); `zstdcheck` (`module/Makefile.in:189-190`) is vacuous in a user-only build — the `module/zstd` objects it inspects are never built and the pipeline status comes from awk | not load-bearing for this tier |
| `gdb` | `scripts/zloop.sh:31,115,157-169` | zloop crash path only |
| lcov/genhtml | `tests/unit/Makefile.am:165-186`; probe `config/ax_code_coverage.m4:115-116` | `make unit-coverage` (+ `--enable-code-coverage`) |
| `shellcheck`/`checkbashisms` | `config/always-shellcheck.m4:6-7`; `config/Shellcheck.am:26,44` | codecheck; **skipped when absent** |
| `cppcheck` | `config/always-cppcheck.m4:6-9`; `config/CppCheck.am:20` | `make lint` only; prints a skip line when absent |
| `mandoc` | `scripts/mancheck.sh:23-26` | `mancheck` (in `CHECKS`); skips itself |
| `pax-utils` (`scanelf`) | `scripts/paxcheck.sh:3-6` | `make lint`; exits 3 with a message |
| `parallel` | root `Makefile.am:127-131`; `config/always-parallel.m4:6` | speeds cstyle; optional |
| `python3Packages.flake8` | root `Makefile.am:179-185` | codecheck; skipped when absent |
| `python3` | `tests/test-runner/bin/test-runner.py.in:23-41` (stdlib only, `ctypes`+`subprocess`+`sudo`), `zts-report.py.in:23-26`; shebangs `cmd/*.in` | ZTS runtime, not this tier's `make` |
| ztest itself | `cmd/Makefile.am:42-56`: plain C against `libzpool/libzfs_core/libnvpair -lm`; no extra system tool | build + run |

## 4. Runtime-only surprises (configure never checks these)

1. **perl** — `make checkstyle`/`unit-coverage` run `cstyle.pl`,
   `spdxcheck.pl`, `coverage_report.pl`; no macro checks for perl in the
   user path (`perl` is only injected for kernel configs,
   `generic.nix` `optionals buildKernel`). Breakage lands at check time.
2. **objdump — non-issue after review** — `zstdcheck` is unconditionally
   in `CHECKS` (root `Makefile.am:164-166` → `module/Makefile.in:189`),
   and libtool does probe objdump (`AC_CHECK_TOOL` under `LT_INIT`).
   But in a user-only build the `module/zstd/lib/**/*.o` files it inspects
   never exist and the pipeline's status comes from awk, so zstdcheck
   passes vacuously even with `OBJDUMP=false` (verified directly). Not
   load-bearing for this tier.
3. **git silent degradation** — no git ⇒ `make_gitrev.sh:67` yields
   `"unknown"` (the silenced `git describe` is at `:50`), `commitcheck`/
   `vcscheck` skip themselves (`Makefile.am:119,159`),
   `config/zfs-meta.m4:74` leaves the release string at the META value.
   Everything "passes" with wrong build metadata; only `vcscheck` silently
   stops catching untracked files.
4. **gdb + libtool at test time** — zloop only invokes gdb on a crash
   (`zloop.sh:31`), and in-tree the generated `scripts/common.sh` overrides
   it to `libtool --mode=execute gdb` (`scripts/Makefile.am:41`), so
   libtool must stay on PATH when zloop reports a core.
5. **procps `uptime`** — `zloop.sh:388` runs unconditionally at exit, but
   the following `if` (false when no crashes) swallows its failure: without
   procps zloop exits **0** and only leaves a broken `ztest.out` tail —
   silent success, not a hard death (verified by simulating the tail).
6. **writable `/proc/sys/kernel/core_pattern`** — `zloop.sh:80-97` sets
   and restores it; unprivileged runs only warn and skip core capture
   (AGENTS.md documents the side effect).
7. **Self-skipping linters** — shellcheck, checkbashisms, mandoc, flake8,
   scanelf, cppcheck, parallel each *print a skip line and pass* when
   missing; a green `make checkstyle` is not evidence those checks ran.
8. **`systemctl` probe changes the build** — `config/user-systemd.m4:29-33`
   auto-disables systemd units and the `zfs-mount-generator` program in a
   container without systemd (`etc/Makefile.am:46-87`), silently producing
   a different package set; pass `--enable-systemd`/`--disable-systemd`
   explicitly. Likewise `curl-config` presence flips HTTPS-key support
   (`config/user-libfetch.m4:43`), and because the choice is a *dlopen* of
   `libcurl.so.4` (`lib/libzfs/libzfs_crypto.c:521-537`), curl must also
   exist at runtime for `zfs load-key` over https URLs.
9. **ksh** — the ZTS scripts are `ksh(1)`; only `scripts/zfs-tests.sh:737`
   checks (`[ -e "$STF_PATH/ksh" ]`), configure never does. `python3` is
   the same story for the test runner (`test-runner.py` shebang,
   `zfs-tests.sh:916`).
10. **ZTS device/admin tools** — `zfs-tests.sh:722` (sudo), `:807`
    (`/sbin/losetup`, util-linux), `:57` (`dmsetup`, lvm2), `:468-469`
    (`/sbin/{fsck,mkfs}.ext4`, e2fsprogs), `:844` (`setenforce`, optional):
    all runtime-checked, none configure-checked.
11. **ZTS constrained-PATH allow-list** — `tests/zfs-tests/include/commands.cfg:11-166`
    symlinks a fixed tool set into `$STF_PATH`; missing entries become a
    `STF_MISSING_BIN` warning at `make all` time (`scripts/Makefile.am:82-84`
    runs `zfs-tests.sh -c` **during the build**, under bash!) and test
    failures later: `bc jq fio cpio pax rsync scp ssh openssl attr
    pamtester cryptsetup parted perf udevadm useradd/groupadd (shadow)
    hostid blkid/disk-related util-linux tools`; the Linux-only set
    (§1.2 of the ZTS inventory, #4) additionally needs `mkfs.xfs`
    (xfsprogs), `modprobe`/`lsmod` (kmod), `lsscsi`, `pamtester`, `perf`.
    `smartmontools` is *not* on the allow-list — it belongs to the
    zpool.d/zedlet PATH that nixpkgs patches with `coreutils gawk gnused
    gnugrep util-linux smartmontools sysstat` in `generic.nix` postFixup
    (sysstat *is* allow-listed; `nfs-utils` provides `exportfs`).
12. **bash** — zloop/zfs-tests are `#!/usr/bin/env bash`
    (`scripts/zloop.sh:1`), but no configure check for bash exists in the
    user path; during `make`, `scripts/Makefile.am:84` prints
    `/usr/bin/env: 'bash'…` and continues (the recipe line is `-`-prefixed,
    so the error is ignored — the breakage surfaces later at ZTS runtime).

## 5. Dev-shell summary for this tier

The list below is a **devShell `buildInputs` set**, not a runnable
one-liner: `nix shell` executes no setup hooks, so with bare outputs
`autogen.sh` fails (autoreconf can't see libtool's macros → "not using
Libtool" → `LIBTOOL undefined`) and `configure` dies at
`*** zlib-devel package required` — split-output packages need their
`.dev`/`.lib` variants plus exported `PKG_CONFIG_PATH`/`C_INCLUDE_PATH`/
`LIBRARY_PATH`, and a compiler (`stdenv.cc`) is not in the list. In a
flake `devShell` these come from `autoreconfHook`-style setup hooks (as
nixpkgs itself uses); ad-hoc, prefer `nix shell nixpkgs#stdenv.cc … -c
bash` **with** the dev outputs and exported paths.

```
autoconf automake libtool gnumake m4 pkg-config
perl git gnutar gawk gnused gnugrep coreutils findutils diffutils
zlib libuuid libtirpc openssl stdenv.cc
# + curl systemd pam attr to mirror nixpkgs' own feature set
# + shellcheck checkbashisms cppcheck mandoc pax-utils python3Packages.flake8 parallel lcov for checkstyle/lint/unit-coverage
# + gdb procps for zloop.sh
# + ksh python3 python3Packages.{setuptools,cffi,packaging} util-linux lvm2 e2fsprogs xfsprogs kmod lsscsi sudo bc jq fio cpio pax shadow attr pamtester cryptsetup parted perf libcap openssh nfs-utils sysstat libaio for full ZTS
```
