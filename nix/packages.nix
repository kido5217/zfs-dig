# Everything built from this source tree, pinned to the flake's nixpkgs
# input (wayfinder #6: the lockfile is the single version authority; the VM
# kernel below is the kernel-tier target).
{ pkgs
, lib
, src ? ../.
}:
let
  inherit (pkgs.linuxPackages) kernel;
  moddir = kernel.modDirVersion;
  kernelDir = "${kernel.dev}/lib/modules/${moddir}";

  # Version straight from META so flake and tree cannot drift.
  metaField = key:
    let
      line = lib.findFirst (l: lib.hasPrefix "${key}:" l)
        (throw "META: key ${key} not found")
        (lib.splitString "\n" (builtins.readFile ../META));
    in
    lib.last (lib.filter (w: w != "") (lib.splitString " " line));
  version = metaField "Version";

  # Keep in-tree build products out of the source so each derivation runs
  # a pristine ./autogen.sh; module/Makefile.in is tracked upstream, keep.
  generatedNames = [
    "configure" "config.h" "config.log" "config.status" "aclocal.m4"
    "Makefile" "libtool" "stamp-h1" "zfs_config.h" "VERSION"
    ".git" ".nix-result" "result"
  ];
  source = lib.cleanSourceWith {
    src = lib.cleanSource src;
    filter = path: type:
      let b = baseNameOf (toString path);
      in type == "directory" || (
        !lib.elem b generatedNames
        && !lib.hasSuffix ".o" b
        && !lib.hasSuffix ".ko" b
        && !lib.hasSuffix ".ko.zst" b
        && !(b == "Makefile.in" && !lib.hasSuffix "/module" (dirOf (toString path)))
      );
  };

  buildTools = with pkgs; [
    gnumake pkg-config perl gawk gnused gnugrep coreutils findutils
    diffutils gnutar gzip
  ];
  userDeps = with pkgs; [ zlib libuuid libtirpc openssl ];

  commonConfigureFlags = [ "--with-tirpc=1" ];

  # Userspace tier. doCheck=false by default; `checks.unit` overrides to
  # true (configure -> make -> make check, incl. the always-on ztest
  # self-tests). `make unit`/zloop stay interactive: run them via the dev
  # shell against a `./configure --with-config=user` tree.
  zfsUser = pkgs.stdenv.mkDerivation {
    pname = "zfs-user";
    inherit version;
    src = source;
    nativeBuildInputs = buildTools ++ [ pkgs.autoreconfHook269 ];
    buildInputs = userDeps;
    configureFlags = commonConfigureFlags ++ [ "--with-config=user" ];
    # nixpkgs' own zfs recipe (#6): these three conflict with kernel and
    # PIC-sensitive asm in this tree.
    hardeningDisable = [ "fortify" "stackprotector" "pic" ];
    env.NIX_CFLAGS_LINK = "-lgcc_s";
    installFlags = [ "DEFAULT_INITCONF_DIR=\${out}/default" ];
    doCheck = false;
    meta.mainProgram = "zfs";
  };

  zfsUserChecked = zfsUser.overrideAttrs { doCheck = true; };

  # Kernel tier: same tree, --with-config=kernel against the pinned VM
  # kernel; drops into boot.extraModulePackages (#5, #6).
  zfsKmod = pkgs.stdenv.mkDerivation {
    pname = "zfs-kmod";
    version = "${version}-${moddir}";
    src = source;
    nativeBuildInputs = buildTools
      ++ kernel.moduleBuildDependencies
      ++ [ pkgs.autoreconfHook269 ];
    buildInputs = [ pkgs.libelf ];
    configureFlags = commonConfigureFlags ++ [
      "--with-config=kernel"
      "--with-linux=${kernelDir}/source"
      "--with-linux-obj=${kernelDir}/build"
    ];
    hardeningDisable = [ "fortify" "stackprotector" "pic" ];
    postBuild = ''
      # Strip before kernel compression so strip hooks see the .ko files
      # (nixpkgs zfs does the same).
      find . -name '*.ko' -print0 | xargs -0 -r ${pkgs.stdenv.cc.targetPrefix}strip --strip-debug
    '';
    installFlags = [ "INSTALL_MOD_PATH=\${out}" ];
  };

  # ZTS wants the FHS layout hardcoded by the scripts (zts-env.md §6 plus
  # review corrections 1-3, 7): only entries no PATH can satisfy — kernel-
  # resolved shebangs, absolute-path execs, and create_links' fixed scan
  # of the six FHS dirs (zfs-tests.sh:419-420) — the rest rides on
  # systemPackages. Aliases (fsck.ext4, xxh128sum) carry fixed names.
  # Each entry lists candidates; the builder fails the build if none is
  # executable, so a package layout change cannot pass silently.
  fhsFarm = pkgs.runCommand "zts-fhs-farm" { }
    (let
      spec = [
        { dir = "bin";      name = "ksh";        cs = [ "${pkgs.ksh}/bin/ksh" ]; }
        { dir = "bin";      name = "true";       cs = [ "${pkgs.coreutils}/bin/true" ]; }
        { dir = "sbin";     name = "mkfs.ext4";  cs = [ "${pkgs.e2fsprogs}/sbin/mkfs.ext4" "${pkgs.e2fsprogs}/bin/mkfs.ext4" ]; }
        { dir = "sbin";     name = "fsck.ext4";  cs = [ "${pkgs.e2fsprogs}/sbin/e2fsck" "${pkgs.e2fsprogs}/bin/e2fsck" ]; }
        { dir = "sbin";     name = "losetup";    cs = [ "${pkgs.util-linux}/sbin/losetup" "${pkgs.util-linux}/bin/losetup" ]; }
        { dir = "sbin";     name = "dmsetup";    cs = [ "${pkgs.lvm2}/sbin/dmsetup" ]; }
        { dir = "sbin";     name = "cryptsetup"; cs = [ "${pkgs.cryptsetup}/sbin/cryptsetup" "${pkgs.cryptsetup}/bin/cryptsetup" ]; }
        { dir = "usr/bin";  name = "awk";        cs = [ "${pkgs.gawk}/bin/awk" ]; }
        { dir = "usr/bin";  name = "strace";     cs = [ "${pkgs.strace}/bin/strace" ]; }
        { dir = "usr/bin";  name = "killall";    cs = [ "${pkgs.psmisc}/bin/killall" ]; }
        # argv[0] dispatch in xxhsum: a symlink named xxh128sum produces
        # the 128-bit digest (verified in wayfinder #4 review).
        { dir = "usr/bin";  name = "xxh128sum";  cs = [ "${pkgs.xxhash}/bin/xxhsum" ]; }
        { dir = "usr/bin";  name = "top";        cs = [ "${pkgs.procps}/bin/top" ]; }
        { dir = "usr/bin";  name = "pgrep";      cs = [ "${pkgs.procps}/bin/pgrep" ]; }
        # zloop's tail calls uptime unconditionally (zloop.sh:388); without
        # procps a broken run still exits 0.
        { dir = "usr/bin";  name = "uptime";     cs = [ "${pkgs.procps}/bin/uptime" ]; }
        { dir = "usr/bin";  name = "perf";       cs = [ "${pkgs.perf}/bin/perf" ]; }
        { dir = "usr/bin";  name = "mkfs.xfs";   cs = [ "${pkgs.xfsprogs}/bin/mkfs.xfs" "${pkgs.xfsprogs}/sbin/mkfs.xfs" ]; }
        { dir = "usr/bin";  name = "net";        cs = [ "${pkgs.samba}/bin/net" ]; }
        { dir = "usr/bin";  name = "smbstatus";  cs = [ "${pkgs.samba}/bin/smbstatus" ]; }
        { dir = "usr/sbin"; name = "nologin";    cs = [ "${pkgs.shadow}/sbin/nologin" "${pkgs.shadow}/bin/nologin" ]; }
        { dir = "usr/sbin"; name = "wipefs";     cs = [ "${pkgs.util-linux}/sbin/wipefs" "${pkgs.util-linux}/bin/wipefs" ]; }
        { dir = "usr/sbin"; name = "parted";     cs = [ "${pkgs.parted}/sbin/parted" ]; }
      ];
      linkBlock = e:
        ''
          done_=0
        '' + (lib.concatStringsSep "" (map (c: ''
          if [ "$done_" = 0 ] && [ -x "${c}" ]; then ln -s "${c}" "$out/${e.dir}/${e.name}"; done_=1; fi
        '') e.cs)) + ''
          [ "$done_" = 1 ] || { echo "fhs farm: ${e.name} (${e.dir}): no candidate executable found" >&2; exit 1; }
        '';
    in ''
      mkdir -p $out/bin $out/sbin $out/usr/bin $out/usr/sbin
      ${lib.concatStringsSep "\n" (map linkBlock spec)}
    '');

in
{
  inherit version source zfsUser zfsUserChecked zfsKmod fhsFarm;
  inherit kernel moddir kernelDir;
}
