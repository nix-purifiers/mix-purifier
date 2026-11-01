# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set, the
# scope `pkgs.mix-purifier`, which holds the packages of pkgs/:
# `.buildMixProject` (the builder), `.cli` (the `mix-purifier` command) and
# `.toolchain`. A package for callPackage takes the scope by name, as
# `{ mix-purifier }:`, and `mix-purifier.overrideScope` replaces what the
# scope shares, such as `beamPackages`. A consumer that lists this flake in
# `projects` holds the overlay as `mix-purifier/default`, which its package
# sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "mix-purifier";
}
