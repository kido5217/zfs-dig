# Human build environment (wayfinder #7): the verified userland set from
# #3 plus kernel-tier interactivity from #6. Deliberately NO autoreconf
# hooks — ./autogen.sh is the one entry point for humans; derivations use
# autoreconfHook269 internally.
{ pkgs, lib, zfs }:
let
  inherit (pkgs.linuxPackages) kernel;
in
pkgs.mkShell {
  name = "zfs-dig-dev";

  packages = with pkgs; [
    autoconf automake libtool m4 pkg-config gnumake perl git
    gnutar gawk gnused gnugrep coreutils findutils diffutils gzip
    zlib libuuid libtirpc openssl
    # Interactive kernel-module builds against the pinned VM kernel (#6).
  ] ++ kernel.moduleBuildDependencies
    # checkstyle/lint extras; every one self-skips when absent (#3 §4),
    # so a missing optional tool never breaks the shell.
    ++ map (n: pkgs.${n})
      (lib.filter (n: pkgs ? ${n}) [ "clang-tools" "cppcheck" "shellcheck" ]);

  shellHook = ''
    export KERNEL_BUILD="${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    export KERNEL_SOURCE="${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
    echo "zfs-dig dev shell — nixpkgs-pinned kernel ${kernel.modDirVersion}"
    echo "  userland:  ./autogen.sh && ./configure --with-config=user && make"
    echo "  kmods:     ./autogen.sh && ./configure --with-config=kernel \\
                        --with-linux=\$KERNEL_SOURCE \\
                        --with-linux-obj=\$KERNEL_BUILD && make"
    echo "  tests:     nix flake check (unit + zfs-smoke) · nix build .#zfs-tests"
  '';
}
