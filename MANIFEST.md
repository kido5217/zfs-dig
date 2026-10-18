# MANIFEST — how the wayfinder map's research maps onto this flake

The `nix/` environment here implements the decisions recorded on the
wayfinder map (GitHub issue #2) and its evidence branches. This file is
the crosswalk so no decision is orphaned.

| Decision (map ticket) | Where it lands here |
| --- | --- |
| Userland tier package set — verified by a live configure→make→check→unit→zloop run | `nix/dev-shell.nix` (interactive set), `nix/packages.nix` (`buildTools`, `userDeps`); evidence: `research/userland-deps` → `docs/wayfinder/userland-deps.md` |
| ZTS FHS gap: symlink farm + aliases, nothing exotic | `nix/packages.nix` (`fhsFarm`), `nix/vm.nix` (`zts-fhs-farm` activation); evidence: `research/zts-env` → `docs/wayfinder/zts-env.md` §6 + review corrections 1–3, 7 |
| VM is the only kernel path; `nix flake check` = smoke only; full ZTS opt-in | `flake.nix` (`checks.zfs-smoke`, `zfs-tests` attr, `zts-debug` app), `nix/tests/{smoke,suite}.py` |
| nixpkgs pin is the single version authority; kmod build mirrors nixpkgs' own zfs recipe | `flake.nix` (input), `nix/packages.nix` (`zfsKmod` flags, hardening trio, strip step, `INSTALL_MOD_PATH`), `nix/vm.nix` (`extraModulePackages`) |
| One nixpkgs input, no autoreconf hooks in the shell, fixed names | `flake.nix` / `nix/dev-shell.nix` |

The `research/*` branches are evidence, not merge candidates: they are
never PR'd; consult them for the file:line reasoning behind any line here.
