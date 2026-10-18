# OpenZFS (zfs-dig) development environment — see docs/wayfinder/ for the
# decisions behind every choice here (wayfinder map #2, tickets #3-#7).
#
# Surface (settled in #7):
#   nix develop            — dev shell: ./autogen.sh is the one entry point
#   nix flake check        — checks.unit + checks.zfs-smoke
#   nix build .#zfs-tests  — full ZTS driver bundle (run ./result/bin/*)
#   nix run .#zts-debug    — same driver, interactive
{
  description = "OpenZFS on Linux fork — Nix development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      zfs = import ./nix/packages.nix { inherit pkgs lib; };

      testing = import (nixpkgs + "/nixos/lib/testing-python.nix") {
        inherit system pkgs;
      };

      # FHS layout + kmods + userspace tools shared by both test configs.
      vmModule = import ./nix/vm.nix { inherit pkgs lib zfs; };
      node = { ... }: { imports = [ vmModule ]; };

      smokePython = builtins.readFile ./nix/tests/smoke.py;

      suitePython = builtins.replaceStrings [ "@SUITE@" ]
        [ "${zfs.zfsUser}/share/zfs/zfs-tests" ]
        (builtins.readFile ./nix/tests/suite.py);

      smoke = testing.runTest {
        name = "zfs-smoke";
        globalTimeout = 60 * 30;
        nodes.client = node;
        testScript = smokePython;
      };

      suite = testing.runTest {
        name = "zfs-tests";
        globalTimeout = 60 * 60 * 6;
        nodes.client = node;
        testScript = suitePython;
      };
    in
    {
      devShells.${system}.default =
        import ./nix/dev-shell.nix { inherit pkgs lib zfs; };

      # unit: userland tier (configure --with-config=user, make, make check)
      # against this working tree; zfs-smoke: kernel tier + FHS farm in the
      # VM (wayfinder #5: modules load, one pool lifecycle, ztest).
      checks.${system} = {
        unit = zfs.zfsUserChecked;
        zfs-smoke = smoke;
      };

      # Driver bundle: building it costs the closure; running it runs the
      # full ZTS (hours). Not part of nix flake check, by decision #5.
      zfs-tests.${system} = suite.driver;

      apps.${system}.zts-debug = {
        type = "app";
        program = "${suite.driver}/bin/zfs-tests-driver";
        meta.description = "Full ZTS driver with --interactive debug shell";
      };
    };
}
