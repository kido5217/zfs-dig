# Shared NixOS test node (wayfinder #5): this tree's kmods + userspace +
# the FHS farm, plus the services ZTS sharing tests expect. Both the smoke
# check and the full-suite driver boot this same configuration.
{ pkgs, lib, zfs }:
{
  boot.extraModulePackages = [ zfs.zfsKmod ];
  boot.kernelModules = [ "spl" "zfs" ];

  environment.systemPackages = [ zfs.zfsUser ] ++ (with pkgs; [
    # Everything the runner resolves via PATH inside the FHS dirs
    # (create_links scans them; commands.cfg allow-list).
    ksh e2fsprogs util-linux lvm2 parted sysstat procps psmisc iputils
    xfsprogs samba pamtester acl attr pax bc which gzip bzip2
    findutils diffutils gawk gnugrep gnused coreutils python3 perl
    strace gnutar gnumake
  ]);

  # Merge the farm pre-ZTS (#4); no-clobber keeps /bin/sh and /usr/bin/env.
  system.activationScripts.zts-fhs-farm = ''
    for d in bin sbin usr/bin usr/sbin; do mkdir -p "/$d"; done
    cp -rsn "${zfs.fhsFarm}/." /
  '';

  users.users.tester = { isNormalUser = true; };
  security.sudo.extraRules = [
    {
      users = [ "tester" ];
      commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
    }
  ];

  services.nfs.server.enable = true;
  services.samba = {
    enable = true;
    settings.global = {
      "usershare max shares" = 100;
      "usershare owner only" = false;
      "usershare allow guests" = true;
    };
  };

  virtualisation = { memorySize = 4096; diskSize = 20; };
  networking.hostName = "zfs-zts";
}
