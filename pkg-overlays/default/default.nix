# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.mix-purifier` (`.cli`, the `mix-purifier` command, and
# `.toolchain`), and the builder `pkgs.buildMixProject`
# (nix/lib/build-mix-project.nix) beside them, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `mix-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "mix-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildMixProject = final.callPackage ../../nix/lib/build-mix-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
